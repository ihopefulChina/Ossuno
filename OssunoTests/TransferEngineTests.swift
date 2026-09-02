import Foundation
import Testing
@testable import Ossuno

@MainActor
struct TransferEngineTests {
    @Test func oldJournalRecordDecodesWithoutCheckpoint() throws {
        let record = PersistedTransfer(job: Self.persistedJob(status: .failed), retry: nil)
        let encoded = try JSONEncoder().encode(record)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "checkpoint")

        let decoded = try JSONDecoder().decode(
            PersistedTransfer.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.checkpoint == nil)
    }

    @Test func multipartCheckpointRoundTripsThroughJournalRecord() throws {
        let checkpoint = TransferCheckpoint.upload(
            MultipartUploadCheckpoint(
                bucketName: "design-assets",
                objectKey: "art/hero.psd",
                sourceSize: 18_000_000,
                sourceModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                partSize: 8 * 1_024 * 1_024,
                uploadID: "upload-1",
                completedParts: [
                    MultipartCompletedPart(number: 1, etag: "etag-1"),
                    MultipartCompletedPart(number: 2, etag: "etag-2")
                ]
            )
        )
        let record = PersistedTransfer(
            job: Self.persistedJob(status: .paused),
            retry: nil,
            checkpoint: checkpoint
        )

        let decoded = try JSONDecoder().decode(
            PersistedTransfer.self,
            from: JSONEncoder().encode(record)
        )

        #expect(decoded == record)
        #expect(!decoded.job.isActive)
        #expect(decoded.job.isResumable)
    }

    @Test func transferPreferencesPersistWithSafeDefaults() {
        let suite = "OssunoTests.TransferPreferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let first = AppSettings(defaults: defaults)

        #expect(first.concurrentDownloads == 3)
        #expect(first.transferConflictPolicy == .ask)
        #expect(first.uploadSpeedLimit == .unlimited)
        #expect(first.downloadLocation == .ask)
        #expect(first.signedLinkLifetime == .oneHour)
        #expect(first.appearance == .system)

        first.concurrentDownloads = 5
        first.transferConflictPolicy = .keepBoth
        first.uploadSpeedLimit = .megabytesPerSecond(10)
        first.downloadLocation = .downloads
        first.signedLinkLifetime = .sevenDays
        first.appearance = .dark
        defer { first.appearance = .system }

        let restored = AppSettings(defaults: defaults)
        #expect(restored.concurrentDownloads == 5)
        #expect(restored.transferConflictPolicy == .keepBoth)
        #expect(restored.uploadSpeedLimit == .megabytesPerSecond(10))
        #expect(restored.downloadLocation == .downloads)
        #expect(restored.signedLinkLifetime == .sevenDays)
        #expect(restored.appearance == .dark)
    }

    @Test func transferThrottleAccountsForTimeAlreadySpentOnTheNetwork() {
        let limit = TransferSpeedLimit.megabytesPerSecond(1)

        #expect(
            TransferThrottle.delayNanoseconds(
                bytes: 1_024 * 1_024,
                elapsed: 0.25,
                limit: limit
            ) == 750_000_000
        )
        #expect(
            TransferThrottle.delayNanoseconds(
                bytes: 1_024 * 1_024,
                elapsed: 1.25,
                limit: limit
            ) == 0
        )
        #expect(
            TransferThrottle.delayNanoseconds(
                bytes: 1_024 * 1_024,
                elapsed: 0,
                limit: .unlimited
            ) == 0
        )
    }

    @Test func pauseAllPausesRunningAndQueuedJobs() {
        let engine = TransferEngine()
        var running = Self.persistedJob(status: .running)
        running.id = UUID()
        var queued = Self.persistedJob(status: .queued)
        queued.id = UUID()
        engine.jobs = [running, queued]

        engine.pauseAll()

        #expect(engine.jobs.map(\.status) == [.paused, .paused])
    }

    @Test func resumedQueuedUploadReportsItsRealFailureInsteadOfReturningToPaused() async throws {
        let urls = try (1...2).map { try Self.temporaryFile(named: "pause-queued-\($0).txt") }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let transport = ControllableUploadTransport()
        let engine = TransferEngine()
        engine.enqueue(
            plan: TransferEngine.UploadPlan(
                items: urls.enumerated().map { index, url in
                    Self.item(
                        url: url,
                        key: "pause-queued-\(index + 1).txt",
                        resource: TransferResource()
                    )
                },
                skipped: 0
            ),
            client: Self.client(transport: transport),
            account: Self.account(),
            bucket: nil,
            settings: Self.settings(concurrency: 1)
        )
        try await Self.waitUntil { await transport.requestCount == 1 }
        let queuedID = try #require(engine.jobs.last?.id)

        engine.pause(queuedID)
        engine.resume(queuedID)
        #expect(engine.jobs.last?.status == .queued)

        let firstPath = try #require(await transport.requestPaths.first)
        await transport.resume(path: firstPath)
        try await Self.waitUntil { await transport.requestCount == 2 }
        let secondPath = try #require(await transport.requestPaths.last)
        await transport.fail(path: secondPath)
        try await Self.waitUntil { engine.jobs.last?.isActive == false }

        #expect(engine.jobs.last?.status == .failed)
        #expect(engine.jobs.last?.errorMessage != nil)
    }

    @Test func rootUploadWithFilenameTemplateDoesNotNestTheName() async throws {
        let source = try Self.temporaryFile(named: "hero.png")
        defer { try? FileManager.default.removeItem(at: source) }

        let plan = await TransferEngine.planUploads(
            urls: [source],
            prefix: "",
            template: "assets/{filename}",
            applyTemplate: true,
            options: TransferEngine.UploadPreparationOptions(imagesOnly: false, convertHEIC: false)
        )

        #expect(plan.items.count == 1)
        #expect(plan.items.first?.failure == nil)
        let key = try #require(plan.items.first?.objectKey)
        #expect(key.hasPrefix("assets/"))
        #expect(key.hasSuffix("hero.png"))
        #expect(!key.contains("hero.png/"))
        #expect(key.split(separator: "/").count == 2)
    }

    @Test func explicitUploadIsNotFilteredByTheBrowserImagesOnlyPreference() async throws {
        let source = try Self.temporaryFile(named: "archive.bin")
        defer { try? FileManager.default.removeItem(at: source) }

        let plan = await TransferEngine.planUploads(
            urls: [source],
            prefix: "uploads/",
            template: "",
            applyTemplate: false,
            options: TransferEngine.UploadPreparationOptions(imagesOnly: true, convertHEIC: false)
        )

        #expect(plan.items.count == 1)
        #expect(plan.items.first?.failure == nil)
        #expect(plan.items.first?.objectKey.hasSuffix("archive.bin") == true)
    }

    @Test func folderUploadKeepsMacPackagesAsSingleFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-package-upload-\(UUID().uuidString)", directoryHint: .isDirectory)
        let nested = root.appending(path: "Album", directoryHint: .isDirectory)
        let pages = nested.appending(path: "Cover.pages", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        try Data("inner".utf8).write(to: pages.appending(path: "Index.xml"))
        try Data("plain".utf8).write(to: nested.appending(path: "notes.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = await TransferEngine.planUploads(
            urls: [nested],
            prefix: "uploads/",
            template: "",
            applyTemplate: false,
            options: TransferEngine.UploadPreparationOptions(imagesOnly: false, convertHEIC: false)
        )

        let packageItem = try #require(plan.items.first { $0.filename == "Cover.pages" })
        #expect(packageItem.failure?.contains("程序包") == true)
        #expect(packageItem.objectKey.isEmpty)

        let notes = try #require(plan.items.first { $0.filename == "notes.txt" })
        #expect(notes.failure == nil)
        #expect(notes.objectKey == "uploads/Album/notes.txt")

        #expect(plan.items.count == 2)
        #expect(!plan.items.contains(where: { $0.filename == "Index.xml" || $0.objectKey.contains("Index.xml") }))
    }

    @Test func journalLoadFailureIsReported() {
        let engine = TransferEngine(journal: FailingTransferJournal(failLoad: true))

        engine.restore(accounts: [])

        #expect(engine.journalErrorMessage?.contains("无法恢复传输记录") == true)
    }

    @Test func journalSaveFailureIsReported() {
        let engine = TransferEngine(journal: FailingTransferJournal(failSave: true))
        engine.jobs = [Self.persistedJob(status: .completed)]

        engine.clearFinished()

        #expect(engine.journalErrorMessage?.contains("无法保存传输记录") == true)
    }

    @Test func pausingPreservesCheckpointAndMakesJobResumable() throws {
        let journal = MemoryTransferJournal()
        let engine = TransferEngine(journal: journal)
        let job = Self.persistedJob(status: .running)
        let checkpoint = TransferCheckpoint.upload(
            MultipartUploadCheckpoint(
                bucketName: "bucket",
                objectKey: job.objectKey,
                sourceSize: job.total,
                sourceModifiedAt: .distantPast,
                partSize: OSSClient.partSize,
                uploadID: "u-1",
                completedParts: []
            )
        )
        engine.jobs = [job]
        engine.recordCheckpoint(job.id, checkpoint: checkpoint)

        engine.pause(job.id)

        #expect(engine.jobs.first?.status == .paused)
        #expect(engine.checkpoint(for: job.id) == checkpoint)
        #expect(journal.records.first?.checkpoint == checkpoint)
    }

    @Test func interruptedCheckpointRestoresAsPausedInsteadOfFailed() throws {
        let source = try Self.temporaryFile(named: "paused-upload.txt")
        defer { try? FileManager.default.removeItem(at: source) }
        let bookmark = Data([2, 4, 6, 8])
        let checkpoint = TransferCheckpoint.upload(
            MultipartUploadCheckpoint(
                bucketName: "bucket",
                objectKey: "exact/object.txt",
                sourceSize: 9,
                sourceModifiedAt: .distantPast,
                partSize: OSSClient.partSize,
                uploadID: "u-1",
                completedParts: []
            )
        )
        let record = PersistedTransfer(
            job: Self.persistedJob(status: .running),
            retry: .upload(
                PersistedUploadRetry(
                    accountID: Self.fixedAccount.id,
                    bucket: nil,
                    sourceBookmark: bookmark,
                    objectKey: "exact/object.txt",
                    imagesOnly: false,
                    convertHEIC: false,
                    playSound: false
                )
            ),
            checkpoint: checkpoint
        )
        let engine = TransferEngine(
            journal: MemoryTransferJournal(records: [record]),
            bookmarks: FixedTransferBookmarks(bookmark: bookmark, resolvedURL: source),
            clientProvider: { _, _ in Self.client(transport: RetryTransport()) }
        )

        engine.restore(accounts: [Self.fixedAccount])

        #expect(engine.jobs.first?.status == .paused)
        #expect(engine.checkpoint(for: record.job.id) == checkpoint)
        #expect(engine.canResume(record.job.id))
    }

    @Test func moveToTopOnlyReordersQueuedJobs() {
        let engine = TransferEngine()
        var running = Self.persistedJob(status: .running)
        running.id = UUID()
        var first = Self.persistedJob(status: .queued)
        first.id = UUID()
        var second = Self.persistedJob(status: .queued)
        second.id = UUID()
        engine.jobs = [running, first, second]

        engine.moveToTop(second.id)

        #expect(engine.jobs.map(\.id) == [running.id, second.id, first.id])
        engine.moveToTop(running.id)
        #expect(engine.jobs.map(\.id) == [running.id, second.id, first.id])
    }

    @Test func transferRateUsesRecentProgressSamples() {
        let engine = TransferEngine()
        var job = Self.persistedJob(status: .running)
        job.transferred = 0
        job.total = 1_000
        engine.jobs = [job]
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        engine.recordProgress(job.id, transferred: 100, total: 1_000, at: start)
        engine.recordProgress(job.id, transferred: 300, total: 1_000, at: start.addingTimeInterval(2))
        engine.recordProgress(job.id, transferred: 500, total: 1_000, at: start.addingTimeInterval(4))

        #expect(engine.currentBytesPerSecond(job.id) == 100)
        #expect(engine.estimatedRemaining(job.id) == 5)
    }

    @Test func keepBothUsesFinderStyleNumberingForFilesAndFolders() {
        let existing: Set<String> = [
            "art/hero.png",
            "art/hero 2.png",
            "art/Notes/",
            "README",
        ]

        #expect(TransferConflictPlanner.availableKey(for: "art/hero.png", existing: existing) == "art/hero 3.png")
        #expect(TransferConflictPlanner.availableKey(for: "art/Notes/", existing: existing) == "art/Notes 2/")
        #expect(TransferConflictPlanner.availableKey(for: "README", existing: existing) == "README 2")
    }

    @Test func conflictPolicyPlansTheWholeBatchDeterministically() {
        let keys = ["hero.png", "hero.png", "notes.txt"]
        let existing: Set<String> = ["hero.png"]

        let kept = TransferConflictPlanner.plan(keys: keys, existing: existing, policy: .keepBoth)
        let skipped = TransferConflictPlanner.plan(keys: keys, existing: existing, policy: .skip)
        let replaced = TransferConflictPlanner.plan(keys: keys, existing: existing, policy: .replace)

        #expect(kept == [.renamed("hero 2.png"), .renamed("hero 3.png"), .useOriginal])
        #expect(skipped == [.skip, .skip, .useOriginal])
        // .replace may overwrite the remote object once, but a duplicate key
        // inside the same batch must not silently overwrite its own earlier
        // item, so the second occurrence is renamed instead.
        #expect(replaced == [.useOriginal, .renamed("hero 2.png"), .useOriginal])
    }

    @Test func transferCenterFiltersJobsBySemanticState() {
        var queued = Self.persistedJob(status: .queued)
        queued.id = UUID()
        var paused = Self.persistedJob(status: .paused)
        paused.id = UUID()
        var completed = Self.persistedJob(status: .completed)
        completed.id = UUID()
        var failed = Self.persistedJob(status: .failed)
        failed.id = UUID()
        let jobs = [queued, paused, completed, failed]

        #expect(TransferFilter.all.filter(jobs).map(\.id) == jobs.map(\.id))
        #expect(TransferFilter.active.filter(jobs).map(\.id) == [queued.id])
        #expect(TransferFilter.paused.filter(jobs).map(\.id) == [paused.id])
        #expect(TransferFilter.completed.filter(jobs).map(\.id) == [completed.id])
        #expect(TransferFilter.failed.filter(jobs).map(\.id) == [failed.id])
    }

    @Test func revealIsAvailableOnlyForACompletedDownloadWithALocalFile() throws {
        let file = try Self.temporaryFile(named: "reveal.txt")
        defer { try? FileManager.default.removeItem(at: file) }
        var download = Self.persistedJob(status: .completed)
        download.kind = .download
        download.localURL = file
        var upload = download
        upload.kind = .upload
        var missing = download
        missing.localURL = file.appendingPathExtension("missing")

        #expect(download.canRevealInFinder)
        #expect(!upload.canRevealInFinder)
        #expect(!missing.canRevealInFinder)
    }

    @Test func clearingHistoryKeepsActiveTransfers() {
        let engine = TransferEngine()
        let running = Self.persistedJob(status: .running)
        let completed = Self.persistedJob(status: .completed)
        let failed = Self.persistedJob(status: .failed)
        engine.jobs = [running, completed, failed]

        engine.clearFinished()

        #expect(engine.jobs == [running])
    }

    @Test func journalRoundTripRemovesLocalPathsAndSignedURLs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-transfer-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "transfers.json")
        let journal = FileTransferJournal(url: url)
        var job = Self.persistedJob(status: .failed)
        job.localURL = URL(filePath: "/Users/private/Documents/source.txt")
        job.publicURL = URL(string: "https://example.test/file?Signature=signed-secret")
        let record = PersistedTransfer(
            job: job,
            retry: .upload(
                PersistedUploadRetry(
                    accountID: Self.fixedAccount.id,
                    bucket: nil,
                    sourceBookmark: Data([1, 2, 3]),
                    objectKey: "exact/object.txt",
                    imagesOnly: false,
                    convertHEIC: false,
                    playSound: false
                )
            )
        )

        try journal.save([record])

        let storedText = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(!storedText.contains("/Users/private"))
        #expect(!storedText.contains("signed-secret"))
        #expect(!storedText.contains("Authorization"))
        let loaded = try journal.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].job.localURL == nil)
        #expect(loaded[0].job.publicURL == nil)
        #expect(loaded[0].job.objectKey == "exact/object.txt")
    }

    @Test func runningJobRestoresAsRetryableInterruptedFailure() throws {
        let source = try Self.temporaryFile(named: "restored-upload.txt")
        defer { try? FileManager.default.removeItem(at: source) }
        let bookmark = Data([7, 0, 0, 7])
        let record = PersistedTransfer(
            job: Self.persistedJob(status: .running),
            retry: .upload(
                PersistedUploadRetry(
                    accountID: Self.fixedAccount.id,
                    bucket: nil,
                    sourceBookmark: bookmark,
                    objectKey: "chosen/exact.txt",
                    imagesOnly: false,
                    convertHEIC: false,
                    playSound: false
                )
            )
        )
        let journal = MemoryTransferJournal(records: [record])
        let engine = TransferEngine(
            journal: journal,
            bookmarks: FixedTransferBookmarks(bookmark: bookmark, resolvedURL: source),
            clientProvider: { _, _ in Self.client(transport: RetryTransport()) }
        )

        engine.restore(accounts: [Self.fixedAccount])

        let restored = try #require(engine.jobs.first)
        #expect(restored.status == .failed)
        #expect(restored.errorMessage == "上次退出时传输中断，可重试")
        #expect(engine.canRetry(restored.id))
        #expect(journal.records.first?.job.status == .failed)
    }

    @Test func staleBookmarkKeepsHistoryAndExplainsWhyRetryIsUnavailable() throws {
        let record = PersistedTransfer(
            job: Self.persistedJob(status: .queued),
            retry: .upload(
                PersistedUploadRetry(
                    accountID: Self.fixedAccount.id,
                    bucket: nil,
                    sourceBookmark: Data([9]),
                    objectKey: "chosen/exact.txt",
                    imagesOnly: false,
                    convertHEIC: false,
                    playSound: false
                )
            )
        )
        let engine = TransferEngine(
            journal: MemoryTransferJournal(records: [record]),
            bookmarks: FailingTransferBookmarks(),
            clientProvider: { _, _ in Self.client(transport: RetryTransport()) }
        )

        engine.restore(accounts: [Self.fixedAccount])

        let restored = try #require(engine.jobs.first)
        #expect(restored.status == .failed)
        #expect(!engine.canRetry(restored.id))
        #expect(engine.unavailableRetryReason(restored.id) == "原文件或文件夹权限已失效，请重新选择后再上传。")
    }

    @Test func progressJournalWritesAreThrottled() {
        let journal = CountingTransferJournal()
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let engine = TransferEngine(journal: journal)
        let job = Self.persistedJob(status: .running)
        engine.jobs = [job]

        engine.recordProgress(job.id, transferred: 4, total: 10, at: fixedNow)
        engine.recordProgress(job.id, transferred: 5, total: 10, at: fixedNow)

        #expect(engine.jobs.first?.transferred == 5)
        #expect(journal.saveCount == 1)
        #expect(journal.records.first?.job.transferred == 4)
    }

    @Test func transferResourceFinishesOnlyOnceAndDeletesOwnedTemporaryFile() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-transfer-resource-\(UUID().uuidString)")
        try Data("temporary".utf8).write(to: temporary)
        let counter = LockedCounter()
        let resource = TransferResource(cleanupURLs: [temporary]) {
            counter.increment()
        }

        resource.finish()
        resource.finish()

        #expect(counter.value == 1)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
    }

    @Test func cancellingAQueuedUploadImmediatelyFinishesItsResource() async throws {
        let firstURL = try Self.temporaryFile(named: "first.txt")
        let secondURL = try Self.temporaryFile(named: "second.txt")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        let firstCounter = LockedCounter()
        let secondCounter = LockedCounter()
        let transport = BlockingUploadTransport()
        let client = OSSClient(
            credentials: OSSCredentials(accessKeyId: "test", accessKeySecret: "secret", securityToken: nil),
            region: "cn-hangzhou",
            endpointHost: "oss-cn-hangzhou.aliyuncs.com",
            bucket: "bucket",
            transport: transport,
            testingVersioningStatusOverride: .disabled
        )
        let account = OSSAccount(
            id: UUID(),
            name: "Test",
            accessKeyId: "test",
            regionID: "cn-hangzhou",
            endpointOverride: "",
            cdnDomain: "",
            defaultACL: .private,
            prefixTemplate: "",
            useTransferAccelerate: false,
            createdAt: .now
        )
        let settings = Self.settings(concurrency: 1)
        let engine = TransferEngine()
        let plan = TransferEngine.UploadPlan(
            items: [
                Self.item(url: firstURL, key: "first.txt", resource: TransferResource { firstCounter.increment() }),
                Self.item(url: secondURL, key: "second.txt", resource: TransferResource { secondCounter.increment() })
            ],
            skipped: 0
        )

        engine.enqueue(plan: plan, client: client, account: account, bucket: nil, settings: settings)
        try await Self.waitUntil { engine.jobs.first?.status == .running }
        try await Self.waitForRequest(transport)
        let queuedID = try #require(engine.jobs.last?.id)
        engine.cancel(queuedID)

        #expect(engine.jobs.last?.status == .cancelled)
        #expect(secondCounter.value == 1)
        #expect(firstCounter.value == 0)

        await transport.resumeFirst()
        try await Self.waitUntil { engine.jobs.first?.status == .completed }
        #expect(firstCounter.value == 1)
    }

    @Test func abandoningAPlanDeletesExplicitlyOwnedSourceFiles() async throws {
        let source = try Self.temporaryFile(named: "clipboard.jpg")
        let plan = await TransferEngine.planUploads(
            urls: [source],
            prefix: "folder/",
            template: "",
            applyTemplate: false,
            options: .init(
                imagesOnly: false,
                convertHEIC: false,
                ownedTemporaryURLs: [source]
            )
        )
        let engine = TransferEngine()

        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(plan.items.count == 1)
        engine.abandon(plan: plan)

        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test func restoreRehydratesDownloadPathAndUploadLink() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-rehydrate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "file.txt")
        try Data("ok".utf8).write(to: destination)
        let rootBookmark = Data([11, 22, 33])
        let source = try Self.temporaryFile(named: "source.txt")
        defer { try? FileManager.default.removeItem(at: source) }
        let sourceBookmark = Data([44, 55, 66])
        var downloadJob = Self.persistedJob(status: .completed)
        downloadJob.id = UUID()
        downloadJob.kind = .download
        downloadJob.objectKey = "file.txt"
        downloadJob.localURL = nil
        var uploadJob = Self.persistedJob(status: .completed)
        uploadJob.id = UUID()
        uploadJob.objectKey = "exact/object.txt"
        uploadJob.publicURL = nil
        let bucket = OSSBucket(
            name: "bucket",
            regionID: "cn-hangzhou",
            location: "oss-cn-hangzhou",
            extranetEndpoint: "oss-cn-hangzhou.aliyuncs.com",
            createdAt: nil
        )
        let records = [
            PersistedTransfer(
                job: downloadJob,
                retry: .download(
                    PersistedDownloadRetry(
                        accountID: Self.fixedAccount.id,
                        bucket: bucket,
                        rootBookmark: rootBookmark,
                        object: OSSObject(
                            key: "file.txt",
                            size: 2,
                            etag: "e",
                            lastModified: nil,
                            storageClass: "Standard"
                        ),
                        relativeDestination: "file.txt"
                    )
                )
            ),
            PersistedTransfer(
                job: uploadJob,
                retry: .upload(
                    PersistedUploadRetry(
                        accountID: Self.fixedAccount.id,
                        bucket: bucket,
                        sourceBookmark: sourceBookmark,
                        objectKey: "exact/object.txt",
                        imagesOnly: false,
                        convertHEIC: false,
                        playSound: false
                    )
                )
            )
        ]
        let engine = TransferEngine(
            journal: MemoryTransferJournal(records: records),
            bookmarks: MappingTransferBookmarks(map: [
                rootBookmark: directory,
                sourceBookmark: source
            ]),
            clientProvider: { _, _ in Self.client(transport: RetryTransport()) }
        )

        engine.restore(accounts: [Self.fixedAccount])

        let download = try #require(engine.jobs.first(where: { $0.kind == .download }))
        let upload = try #require(engine.jobs.first(where: { $0.kind == .upload }))
        #expect(download.localURL == destination)
        #expect(download.canRevealInFinder)
        #expect(upload.publicURL?.absoluteString.contains("exact/object.txt") == true)
    }

    @Test func restoredHEICUploadReconvertsInsteadOfUploadingTheOriginal() async throws {
        let source = try Self.temporaryFile(named: "photo.heic")
        defer { try? FileManager.default.removeItem(at: source) }
        let bookmark = Data([9, 9, 9, 9])
        var job = Self.persistedJob(status: .running)
        job.objectKey = "photo.jpg"
        job.title = "photo.jpg"
        let record = PersistedTransfer(
            job: job,
            retry: .upload(
                PersistedUploadRetry(
                    accountID: Self.fixedAccount.id,
                    bucket: OSSBucket(
                        name: "bucket",
                        regionID: "cn-hangzhou",
                        location: "oss-cn-hangzhou",
                        extranetEndpoint: "oss-cn-hangzhou.aliyuncs.com",
                        createdAt: nil
                    ),
                    sourceBookmark: bookmark,
                    objectKey: "photo.jpg",
                    imagesOnly: false,
                    convertHEIC: true,
                    playSound: false
                )
            ),
            checkpoint: TransferCheckpoint.upload(
                MultipartUploadCheckpoint(
                    bucketName: "bucket",
                    objectKey: "photo.jpg",
                    sourceSize: 1_000,
                    sourceModifiedAt: .distantPast,
                    partSize: OSSClient.partSize,
                    uploadID: "u-heic",
                    completedParts: []
                )
            )
        )
        let transport = RetryTransport()
        let engine = TransferEngine(
            journal: MemoryTransferJournal(records: [record]),
            bookmarks: FixedTransferBookmarks(bookmark: bookmark, resolvedURL: source),
            clientProvider: { _, _ in Self.client(transport: transport) }
        )

        engine.restore(accounts: [Self.fixedAccount])
        let id = try #require(engine.jobs.first?.id)
        #expect(engine.jobs.first?.status == .paused)
        engine.resume(id)
        try await Self.waitUntil { engine.jobs.first?.status == .failed }

        #expect(engine.jobs.first?.errorMessage?.contains("HEIC") == true)
        #expect(await transport.requestPaths.isEmpty)
    }

    @Test func retryingAnUploadKeepsTheExactOriginalObjectKey() async throws {
        let source = try Self.temporaryFile(named: "local-name.txt")
        defer { try? FileManager.default.removeItem(at: source) }
        let transport = RetryTransport()
        let client = Self.client(transport: transport)
        let engine = TransferEngine()
        let account = Self.account(prefixTemplate: "generated/{yyyy}/")
        let settings = Self.settings(concurrency: 1)
        let exactKey = "chosen/final-name.txt"
        let plan = TransferEngine.UploadPlan(
            items: [Self.item(url: source, key: exactKey, resource: TransferResource())],
            skipped: 0
        )

        engine.enqueue(plan: plan, client: client, account: account, bucket: nil, settings: settings)
        try await Self.waitUntil { engine.jobs.first?.status == .failed }
        let failedID = try #require(engine.jobs.first?.id)
        engine.retry(failedID)
        try await Self.waitUntil { engine.jobs.count == 2 && engine.jobs.last?.status == .completed }

        let paths = await transport.uploadRequestPaths
        #expect(paths == ["/chosen/final-name.txt", "/chosen/final-name.txt"])
        #expect(await transport.forbidOverwrite == ["true", "true"])
    }

    @Test func uploadOverwriteApprovalIsScopedToExactKeys() async throws {
        let first = try Self.temporaryFile(named: "approved.txt")
        let second = try Self.temporaryFile(named: "unapproved.txt")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let transport = ScopedOverwriteTransport()
        let client = Self.client(transport: transport, versioningStatus: .enabled)
        let engine = TransferEngine()
        let plan = TransferEngine.UploadPlan(
            items: [
                Self.item(url: first, key: "approved.txt", resource: TransferResource()),
                Self.item(url: second, key: "unapproved.txt", resource: TransferResource())
            ],
            skipped: 0
        )

        engine.enqueue(
            plan: plan,
            client: client,
            account: Self.fixedAccount,
            bucket: nil,
            settings: Self.settings(concurrency: 2),
            overwriteDestinations: [
                "approved.txt": OSSObjectIdentity(
                    etag: "approved-etag",
                    versionID: "approved-v1",
                    size: 7
                )
            ]
        )
        try await Self.waitUntil {
            engine.jobs.count == 2 && engine.jobs.allSatisfy { !$0.isActive }
        }

        let headers = await transport.putForbidOverwriteByPath
        #expect(headers["/approved.txt"] == "")
        #expect(headers["/unapproved.txt"] == "true")
        #expect(engine.jobs.allSatisfy { $0.status == .completed })
    }

    @Test func retryNeverReusesASingleUseUploadOverwriteApproval() async throws {
        let source = try Self.temporaryFile(named: "single-use-overwrite.txt")
        defer { try? FileManager.default.removeItem(at: source) }
        let transport = SingleUseOverwriteTransport(failFirstPut: true)
        let engine = TransferEngine()
        let plan = TransferEngine.UploadPlan(
            items: [Self.item(url: source, key: "existing.txt", resource: TransferResource())],
            skipped: 0
        )

        engine.enqueue(
            plan: plan,
            client: Self.client(transport: transport, versioningStatus: .enabled),
            account: Self.fixedAccount,
            bucket: nil,
            settings: Self.settings(concurrency: 1),
            overwriteDestinations: ["existing.txt": SingleUseOverwriteTransport.identity]
        )
        try await Self.waitUntil { engine.jobs.first?.status == .failed }
        let failedID = try #require(engine.jobs.first?.id)

        engine.retry(failedID)
        try await Self.waitUntil {
            engine.jobs.count == 2 && engine.jobs.last?.isActive == false
        }

        #expect(await transport.putCount == 1)
        #expect(await transport.putForbidOverwriteHeaders == [nil])
        #expect(engine.jobs.last?.status == .failed)
        #expect(engine.jobs.last?.errorMessage?.contains("目标已有同名对象") == true)
    }

    @Test func restoredLegacyOverwriteFlagNeverRevivesUploadApproval() async throws {
        let source = try Self.temporaryFile(named: "restored-overwrite.txt")
        defer { try? FileManager.default.removeItem(at: source) }
        let bookmark = Data([5, 4, 3, 2, 1])
        let record = PersistedTransfer(
            job: Self.persistedJob(status: .failed),
            retry: .upload(
                PersistedUploadRetry(
                    accountID: Self.fixedAccount.id,
                    bucket: nil,
                    sourceBookmark: bookmark,
                    objectKey: "exact/object.txt",
                    imagesOnly: false,
                    convertHEIC: false,
                    playSound: false,
                    allowOverwrite: true
                )
            )
        )
        let transport = SingleUseOverwriteTransport(failFirstPut: false)
        let engine = TransferEngine(
            journal: MemoryTransferJournal(records: [record]),
            bookmarks: FixedTransferBookmarks(bookmark: bookmark, resolvedURL: source),
            clientProvider: { _, _ in Self.client(transport: transport) }
        )

        engine.restore(accounts: [Self.fixedAccount])
        let restoredID = try #require(engine.jobs.first?.id)
        engine.retry(restoredID)
        try await Self.waitUntil {
            engine.jobs.count == 2 && engine.jobs.last?.isActive == false
        }

        #expect(await transport.putCount == 0)
        #expect(engine.jobs.last?.status == .failed)
        #expect(engine.jobs.last?.errorMessage?.contains("目标已有同名对象") == true)
    }

    @Test func enabledVersioningCreateRequiresACommittedVersionID() async throws {
        let source = try Self.temporaryFile(named: "versioned-create.txt")
        defer { try? FileManager.default.removeItem(at: source) }

        let successfulTransport = VersionedCreateTransport(versionID: "committed-version")
        let successfulEngine = TransferEngine()
        successfulEngine.enqueue(
            plan: TransferEngine.UploadPlan(
                items: [Self.item(url: source, key: "new-success.txt", resource: TransferResource())],
                skipped: 0
            ),
            client: Self.client(transport: successfulTransport, versioningStatus: .enabled),
            account: Self.fixedAccount,
            bucket: nil,
            settings: Self.settings(concurrency: 1)
        )
        try await Self.waitUntil { successfulEngine.jobs.first?.isActive == false }

        #expect(successfulEngine.jobs.first?.status == .completed)
        #expect(await successfulTransport.putCount == 1)
        #expect(await successfulTransport.putForbidOverwriteHeaders == ["true"])

        let missingVersionTransport = VersionedCreateTransport(versionID: nil)
        let missingVersionEngine = TransferEngine()
        missingVersionEngine.enqueue(
            plan: TransferEngine.UploadPlan(
                items: [Self.item(url: source, key: "new-uncertain.txt", resource: TransferResource())],
                skipped: 0
            ),
            client: Self.client(transport: missingVersionTransport, versioningStatus: .enabled),
            account: Self.fixedAccount,
            bucket: nil,
            settings: Self.settings(concurrency: 1)
        )
        try await Self.waitUntil { missingVersionEngine.jobs.first?.isActive == false }

        #expect(missingVersionEngine.jobs.first?.status == .failed)
        #expect(missingVersionEngine.jobs.first?.errorMessage?.contains("无法确认对象是否已提交") == true)
        #expect(await missingVersionTransport.putCount == 1)
    }

    @Test func suspendedVersioningRejectsNewUploadBeforeAnyRequest() async throws {
        let source = try Self.temporaryFile(named: "suspended-create.txt")
        defer { try? FileManager.default.removeItem(at: source) }
        let transport = VersionedCreateTransport(versionID: "must-not-be-used")
        let engine = TransferEngine()

        engine.enqueue(
            plan: TransferEngine.UploadPlan(
                items: [Self.item(url: source, key: "blocked.txt", resource: TransferResource())],
                skipped: 0
            ),
            client: Self.client(transport: transport, versioningStatus: .suspended),
            account: Self.fixedAccount,
            bucket: nil,
            settings: Self.settings(concurrency: 1)
        )
        try await Self.waitUntil { engine.jobs.first?.isActive == false }

        #expect(engine.jobs.first?.status == .failed)
        #expect(engine.jobs.first?.errorMessage?.contains("Suspended") == true)
        #expect(await transport.headCount == 0)
        #expect(await transport.putCount == 0)
    }

    @Test func failedDownloadCanRetryToTheSameDestination() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-download-retry-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "download.txt")
        let downloadedTemporary = directory.appending(path: "transport.tmp")
        try Data("downloaded".utf8).write(to: downloadedTemporary)
        let transport = RetryTransport(downloadURL: downloadedTemporary)
        let client = Self.client(transport: transport)
        let engine = TransferEngine()
        let object = OSSObject(
            key: "remote/download.txt",
            size: 10,
            etag: "stable-etag",
            lastModified: nil,
            storageClass: "Standard"
        )

        engine.enqueueDownloadJobs(
            items: [(object, destination)],
            client: client,
            scopedRoot: directory
        )
        try await Self.waitUntil { engine.jobs.first?.status == .failed }
        let failedID = try #require(engine.jobs.first?.id)
        engine.retry(failedID)
        try await Self.waitUntil { engine.jobs.count == 2 && engine.jobs.last?.status == .completed }

        #expect(try Data(contentsOf: destination) == Data("downloaded".utf8))
        let paths = await transport.requestPaths
        #expect(paths == Array(repeating: "/remote/download.txt", count: 4))
    }

    @Test func unapprovedDownloadDestinationAppearingAfterPlanningIsPreserved() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-download-scope-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let approved = directory.appending(path: "approved.txt")
        let unapproved = directory.appending(path: "unapproved.txt")
        try Data("old-approved".utf8).write(to: approved)
        let approvedIdentity = try TransferEngine.LocalFileIdentity.capture(approved)
        // This file represents another process creating the second destination
        // after conflict planning but before its queued download starts.
        try Data("must-survive".utf8).write(to: unapproved)
        let downloaded = directory.appending(path: "remote.tmp")
        try Data("remote-data".utf8).write(to: downloaded)
        let transport = RetryTransport(downloadURL: downloaded, failFirstDownloadRange: false)
        let client = Self.client(transport: transport)
        let engine = TransferEngine()
        engine.downloadConcurrency = 1
        let objects = [
            OSSObject(key: "remote/approved.txt", size: 11, etag: "stable-etag", lastModified: nil, storageClass: "Standard"),
            OSSObject(key: "remote/unapproved.txt", size: 11, etag: "stable-etag", lastModified: nil, storageClass: "Standard")
        ]

        engine.enqueueDownloadJobs(
            items: [(objects[0], approved), (objects[1], unapproved)],
            client: client,
            scopedRoot: directory,
            overwriteDestinations: [approved.standardizedFileURL: approvedIdentity]
        )
        try await Self.waitUntil {
            engine.jobs.count == 2 && engine.jobs.allSatisfy { !$0.isActive }
        }

        #expect(try Data(contentsOf: unapproved) == Data("must-survive".utf8))
        #expect(engine.jobs.first(where: { $0.objectKey == "remote/unapproved.txt" })?.status == .failed)
    }

    @Test func localFileIdentityChangesWhenTheSamePathIsRewritten() throws {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-local-identity-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: destination) }
        try Data("old".utf8).write(to: destination)
        let before = try TransferEngine.LocalFileIdentity.capture(destination)

        try Data("changed-after-prompt".utf8).write(to: destination)
        let after = try TransferEngine.LocalFileIdentity.capture(destination)

        #expect(after != before)
        #expect(after.size == 20)
    }

    @Test func approvedLocalFileChangingBeforeCommitIsPreserved() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-download-identity-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "changed.txt")
        try Data("old".utf8).write(to: destination)
        let approvedIdentity = try TransferEngine.LocalFileIdentity.capture(destination)
        try Data("changed-after-prompt".utf8).write(to: destination)
        #expect(try TransferEngine.LocalFileIdentity.capture(destination) != approvedIdentity)
        let downloaded = directory.appending(path: "remote.tmp")
        try Data("remote-data".utf8).write(to: downloaded)
        let transport = RetryTransport(downloadURL: downloaded, failFirstDownloadRange: false)
        let engine = TransferEngine()

        engine.enqueueDownloadJobs(
            items: [(
                OSSObject(
                    key: "remote/changed.txt",
                    size: 11,
                    etag: "stable-etag",
                    lastModified: nil,
                    storageClass: "Standard"
                ),
                destination
            )],
            client: Self.client(transport: transport),
            scopedRoot: directory,
            overwriteDestinations: [destination.standardizedFileURL: approvedIdentity]
        )
        try await Self.waitUntil { engine.jobs.first?.isActive == false }

        #expect(engine.jobs.first?.status == .failed)
        #expect(try Data(contentsOf: destination) == Data("changed-after-prompt".utf8))
        #expect(engine.jobs.first?.errorMessage?.contains("发生了变化") == true)
    }

    @Test func finishingOneUploadNeverExceedsConfiguredConcurrency() async throws {
        let urls = try (1...4).map { try Self.temporaryFile(named: "concurrency-\($0).txt") }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let transport = ControllableUploadTransport()
        let client = Self.client(transport: transport)
        let engine = TransferEngine()
        let plan = TransferEngine.UploadPlan(
            items: urls.enumerated().map { index, url in
                Self.item(
                    url: url,
                    key: "item-\(index + 1).txt",
                    resource: TransferResource()
                )
            },
            skipped: 0
        )

        engine.enqueue(
            plan: plan,
            client: client,
            account: Self.account(),
            bucket: nil,
            settings: Self.settings(concurrency: 2)
        )
        try await Self.waitUntil { await transport.requestCount == 2 }
        let firstPath = try #require(await transport.requestPaths.first)
        await transport.resume(path: firstPath)
        try await Self.waitUntil { await transport.requestCount >= 3 }
        try await Task.sleep(for: .milliseconds(250))

        #expect(await transport.requestCount == 3)

        await transport.resumeAll()
        try await Self.waitUntil { await transport.requestCount == 4 }
        await transport.resumeAll()
        try await Self.waitUntil { engine.jobs.allSatisfy { $0.status == .completed } }
    }

    private static func item(
        url: URL,
        key: String,
        resource: TransferResource
    ) -> TransferEngine.PlannedUpload {
        TransferEngine.PlannedUpload(
            sourceURL: url,
            fileURL: url,
            filename: url.lastPathComponent,
            contentType: "text/plain",
            size: 9,
            objectKey: key,
            resource: resource,
            failure: nil
        )
    }

    private static func settings(concurrency: Int) -> AppSettings {
        let suite = "OssunoTests.TransferEngine.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(concurrency, forKey: "settings.concurrentUploads")
        return AppSettings(defaults: defaults)
    }

    private static func client(transport: some OSSHTTPTransport) -> OSSClient {
        OSSClient(
            credentials: OSSCredentials(accessKeyId: "test", accessKeySecret: "secret", securityToken: nil),
            region: "cn-hangzhou",
            endpointHost: "oss-cn-hangzhou.aliyuncs.com",
            bucket: "bucket",
            transport: transport,
            retryPolicy: OSSRetryPolicy(maxAttempts: 1, jitter: { 0 }),
            testingVersioningStatusOverride: .disabled
        )
    }

    private static func client(
        transport: some OSSHTTPTransport,
        versioningStatus: OSSBucketVersioningStatus
    ) -> OSSClient {
        OSSClient(
            credentials: OSSCredentials(accessKeyId: "test", accessKeySecret: "secret", securityToken: nil),
            region: "cn-hangzhou",
            endpointHost: "oss-cn-hangzhou.aliyuncs.com",
            bucket: "bucket",
            transport: transport,
            retryPolicy: OSSRetryPolicy(maxAttempts: 1, jitter: { 0 }),
            testingVersioningStatusOverride: versioningStatus
        )
    }

    private static func account(prefixTemplate: String = "") -> OSSAccount {
        OSSAccount(
            id: UUID(),
            name: "Test",
            accessKeyId: "test",
            regionID: "cn-hangzhou",
            endpointOverride: "",
            cdnDomain: "",
            defaultACL: .private,
            prefixTemplate: prefixTemplate,
            useTransferAccelerate: false,
            createdAt: .now
        )
    }

    private static let fixedAccount = OSSAccount(
        id: UUID(uuidString: "F79B4573-CB60-43BC-8C3C-5D4BF98F8180")!,
        name: "Test",
        accessKeyId: "test",
        regionID: "cn-hangzhou",
        endpointOverride: "",
        cdnDomain: "",
        defaultACL: .private,
        prefixTemplate: "",
        useTransferAccelerate: false,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    private static func persistedJob(status: TransferStatus) -> TransferJob {
        TransferJob(
            id: UUID(uuidString: "1B248760-1DE8-483C-9C02-00D5455898D0")!,
            kind: .upload,
            status: status,
            title: "source.txt",
            objectKey: "exact/object.txt",
            localURL: nil,
            transferred: 3,
            total: 10,
            errorMessage: nil,
            publicURL: nil,
            finishedAt: nil
        )
    }

    private static func temporaryFile(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString)-\(name)")
        try Data("test data".utf8).write(to: url)
        return url
    }

    private static func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for transfer state")
    }

    private static func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for asynchronous transfer state")
    }

    private static func waitForRequest(_ transport: BlockingUploadTransport) async throws {
        for _ in 0..<200 {
            if await transport.hasPendingRequest { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for upload request")
    }
}

private final class MemoryTransferJournal: TransferJournaling, @unchecked Sendable {
    var records: [PersistedTransfer]

    init(records: [PersistedTransfer] = []) {
        self.records = records
    }

    func load() throws -> [PersistedTransfer] {
        records
    }

    func save(_ records: [PersistedTransfer]) throws {
        self.records = records
    }
}

private struct FailingTransferJournal: TransferJournaling {
    var failLoad = false
    var failSave = false

    func load() throws -> [PersistedTransfer] {
        if failLoad { throw CocoaError(.fileReadCorruptFile) }
        return []
    }

    func save(_ records: [PersistedTransfer]) throws {
        if failSave { throw CocoaError(.fileWriteNoPermission) }
    }
}

private final class CountingTransferJournal: TransferJournaling, @unchecked Sendable {
    private(set) var records: [PersistedTransfer] = []
    private(set) var saveCount = 0

    func load() throws -> [PersistedTransfer] { records }

    func save(_ records: [PersistedTransfer]) throws {
        self.records = records
        saveCount += 1
    }
}

private struct MappingTransferBookmarks: TransferBookmarking {
    var map: [Data: URL]

    func makeBookmark(for url: URL) throws -> Data {
        if let existing = map.first(where: { $0.value.standardizedFileURL == url.standardizedFileURL })?.key {
            return existing
        }
        throw TransferBookmarkError.stale
    }

    func resolve(_ bookmark: Data) throws -> URL {
        guard let url = map[bookmark] else { throw TransferBookmarkError.stale }
        return url
    }
}

private struct FixedTransferBookmarks: TransferBookmarking {
    var bookmark: Data
    var resolvedURL: URL

    func makeBookmark(for url: URL) throws -> Data {
        bookmark
    }

    func resolve(_ bookmark: Data) throws -> URL {
        guard bookmark == self.bookmark else { throw TransferBookmarkError.stale }
        return resolvedURL
    }
}

private struct FailingTransferBookmarks: TransferBookmarking {
    func makeBookmark(for url: URL) throws -> Data {
        throw TransferBookmarkError.stale
    }

    func resolve(_ bookmark: Data) throws -> URL {
        throw TransferBookmarkError.stale
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private actor BlockingUploadTransport: OSSHTTPTransport {
    private var continuation: CheckedContinuation<OSSHTTPResult, Never>?

    var hasPendingRequest: Bool { continuation != nil }

    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        if request.url?.query?.contains("versioning") == true {
            return OSSHTTPResult(
                status: 200,
                headers: [:],
                data: Data("<VersioningConfiguration/>".utf8),
                temporaryDownloadURL: nil
            )
        }
        if request.httpMethod == "HEAD" {
            if request.url?.path == "/approved.txt" {
                return OSSHTTPResult(
                    status: 200,
                    headers: [
                        "ETag": "\"approved-etag\"",
                        "Content-Length": "7"
                    ],
                    data: Data(),
                    temporaryDownloadURL: nil
                )
            }
            return OSSHTTPResult(
                status: 404,
                headers: [:],
                data: Data("<Error><Code>NoSuchKey</Code></Error>".utf8),
                temporaryDownloadURL: nil
            )
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resumeFirst() {
        continuation?.resume(
            returning: OSSHTTPResult(
                status: 200,
                headers: [:],
                data: Data(),
                temporaryDownloadURL: nil
            )
        )
        continuation = nil
    }
}

private actor ScopedOverwriteTransport: OSSHTTPTransport {
    private(set) var putForbidOverwriteByPath: [String: String] = [:]

    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        if request.url?.query?.contains("versioning") == true {
            return OSSHTTPResult(
                status: 200,
                headers: [:],
                data: Data(
                    "<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>".utf8
                ),
                temporaryDownloadURL: nil
            )
        }
        if request.httpMethod == "HEAD" {
            if request.url?.path == "/approved.txt" {
                return OSSHTTPResult(
                    status: 200,
                    headers: [
                        "Content-Length": "7",
                        "ETag": "\"approved-etag\"",
                        "x-oss-version-id": "approved-v1"
                    ],
                    data: Data(),
                    temporaryDownloadURL: nil
                )
            }
            return OSSHTTPResult(
                status: 404,
                headers: [:],
                data: Data("<Error><Code>NoSuchKey</Code></Error>".utf8),
                temporaryDownloadURL: nil
            )
        }
        if request.httpMethod == "PUT", request.url?.query == nil {
            putForbidOverwriteByPath[request.url?.path ?? ""] =
                request.value(forHTTPHeaderField: "x-oss-forbid-overwrite") ?? ""
        }
        return OSSHTTPResult(
            status: 200,
            headers: ["x-oss-version-id": "committed-v1"],
            data: Data(),
            temporaryDownloadURL: nil
        )
    }
}

private actor SingleUseOverwriteTransport: OSSHTTPTransport {
    static let identity = OSSObjectIdentity(
        etag: "existing-etag",
        versionID: "existing-v1",
        size: 9
    )

    private let failFirstPut: Bool
    private(set) var putCount = 0
    private(set) var putForbidOverwriteHeaders: [String?] = []

    init(failFirstPut: Bool) {
        self.failFirstPut = failFirstPut
    }

    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        if request.url?.query?.contains("versioning") == true {
            return OSSHTTPResult(
                status: 200,
                headers: [:],
                data: Data(
                    "<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>".utf8
                ),
                temporaryDownloadURL: nil
            )
        }
        if request.httpMethod == "HEAD" {
            return OSSHTTPResult(
                status: 200,
                headers: [
                    "Content-Length": String(Self.identity.size),
                    "ETag": "\"\(Self.identity.etag)\"",
                    "x-oss-version-id": "existing-v1"
                ],
                data: Data(),
                temporaryDownloadURL: nil
            )
        }
        if request.httpMethod == "PUT" {
            putCount += 1
            putForbidOverwriteHeaders.append(
                request.value(forHTTPHeaderField: "x-oss-forbid-overwrite")
            )
            if failFirstPut, putCount == 1 {
                return OSSHTTPResult(
                    status: 500,
                    headers: [:],
                    data: Data(
                        "<Error><Code>InternalError</Code><Message>uncertain</Message></Error>".utf8
                    ),
                    temporaryDownloadURL: nil
                )
            }
        }
        return OSSHTTPResult(
            status: 200,
            headers: ["x-oss-version-id": "committed-v1"],
            data: Data(),
            temporaryDownloadURL: nil
        )
    }
}

private actor VersionedCreateTransport: OSSHTTPTransport {
    private let versionID: String?
    private(set) var headCount = 0
    private(set) var putCount = 0
    private(set) var putForbidOverwriteHeaders: [String?] = []

    init(versionID: String?) {
        self.versionID = versionID
    }

    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        if request.httpMethod == "HEAD" {
            headCount += 1
            return OSSHTTPResult(
                status: 404,
                headers: [:],
                data: Data("<Error><Code>NoSuchKey</Code></Error>".utf8),
                temporaryDownloadURL: nil
            )
        }
        if request.httpMethod == "PUT" {
            putCount += 1
            putForbidOverwriteHeaders.append(
                request.value(forHTTPHeaderField: "x-oss-forbid-overwrite")
            )
            let headers = versionID.map { ["x-oss-version-id": $0] } ?? [:]
            return OSSHTTPResult(
                status: 200,
                headers: headers,
                data: Data(),
                temporaryDownloadURL: nil
            )
        }
        return OSSHTTPResult(
            status: 200,
            headers: [:],
            data: Data(),
            temporaryDownloadURL: nil
        )
    }
}

private actor RetryTransport: OSSHTTPTransport {
    private(set) var requestPaths: [String] = []
    private(set) var uploadRequestPaths: [String] = []
    private(set) var forbidOverwrite: [String?] = []
    private let downloadURL: URL?
    private let failFirstDownloadRange: Bool
    private var didFailDownloadRange = false
    private var didFailUpload = false

    init(downloadURL: URL? = nil, failFirstDownloadRange: Bool = true) {
        self.downloadURL = downloadURL
        self.failFirstDownloadRange = failFirstDownloadRange
    }

    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        if request.url?.query?.contains("versioning") == true {
            return OSSHTTPResult(
                status: 200,
                headers: [:],
                data: Data("<VersioningConfiguration/>".utf8),
                temporaryDownloadURL: nil
            )
        }
        requestPaths.append(request.url?.path ?? "")
        if let downloadURL {
            if request.httpMethod == "HEAD" {
                let count = (try? downloadURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let checksum = ((try? Data(contentsOf: downloadURL)).map(CRC64XZ.checksum)).map(String.init)
                var headers = [
                    "Content-Length": "\(count)",
                    "ETag": "\"stable-etag\""
                ]
                if let checksum {
                    headers["x-oss-hash-crc64ecma"] = checksum
                }
                return OSSHTTPResult(
                    status: 200,
                    headers: headers,
                    data: Data(),
                    temporaryDownloadURL: nil
                )
            }
            if request.value(forHTTPHeaderField: "Range") != nil {
                if failFirstDownloadRange, !didFailDownloadRange {
                    didFailDownloadRange = true
                    return OSSHTTPResult(
                        status: 500,
                        headers: [:],
                        data: Data("<Error><Code>InternalError</Code><Message>retry</Message></Error>".utf8),
                        temporaryDownloadURL: nil
                    )
                }
                return OSSHTTPResult(
                    status: 206,
                    headers: [
                        "ETag": "\"stable-etag\"",
                        "Content-Range": request.value(forHTTPHeaderField: "Range")?
                            .replacingOccurrences(of: "=", with: " ")
                            .appending("/\((try? downloadURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)")
                            ?? ""
                    ],
                    data: (try? Data(contentsOf: downloadURL)) ?? Data(),
                    temporaryDownloadURL: nil
                )
            }
        }
        if request.httpMethod == "HEAD" {
            return OSSHTTPResult(
                status: 404,
                headers: [:],
                data: Data("<Error><Code>NoSuchKey</Code></Error>".utf8),
                temporaryDownloadURL: nil
            )
        }
        uploadRequestPaths.append(request.url?.path ?? "")
        forbidOverwrite.append(request.value(forHTTPHeaderField: "x-oss-forbid-overwrite"))
        if !didFailUpload {
            didFailUpload = true
            return OSSHTTPResult(
                status: 500,
                headers: [:],
                data: Data("<Error><Code>InternalError</Code><Message>retry</Message></Error>".utf8),
                temporaryDownloadURL: nil
            )
        }
        return OSSHTTPResult(
            status: 200,
            headers: [:],
            data: Data(),
            temporaryDownloadURL: download ? downloadURL : nil
        )
    }
}

private actor ControllableUploadTransport: OSSHTTPTransport {
    private(set) var requestPaths: [String] = []
    private var continuations: [String: CheckedContinuation<OSSHTTPResult, Error>] = [:]

    var requestCount: Int { requestPaths.count }

    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        if request.url?.query?.contains("versioning") == true {
            return OSSHTTPResult(
                status: 200,
                headers: [:],
                data: Data("<VersioningConfiguration/>".utf8),
                temporaryDownloadURL: nil
            )
        }
        if request.httpMethod == "HEAD" {
            return OSSHTTPResult(
                status: 404,
                headers: [:],
                data: Data("<Error><Code>NoSuchKey</Code></Error>".utf8),
                temporaryDownloadURL: nil
            )
        }
        let path = request.url?.path ?? UUID().uuidString
        requestPaths.append(path)
        return try await withCheckedThrowingContinuation { continuation in
            continuations[path] = continuation
        }
    }

    func resume(path: String) {
        continuations.removeValue(forKey: path)?.resume(returning: Self.success)
    }

    func fail(path: String) {
        continuations.removeValue(forKey: path)?.resume(
            throwing: URLError(.cannotConnectToHost)
        )
    }

    func resumeAll() {
        let pending = Array(continuations.values)
        continuations.removeAll()
        pending.forEach { $0.resume(returning: Self.success) }
    }

    private static var success: OSSHTTPResult {
        OSSHTTPResult(status: 200, headers: [:], data: Data(), temporaryDownloadURL: nil)
    }
}
