import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

enum LocalFileReplacementError: LocalizedError, Sendable, Equatable {
    case unavailable(String)
    case changed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let name):
            "无法确认本地文件“\(name)”的当前状态，未执行替换"
        case .changed(let name):
            "本地文件“\(name)”在确认替换后发生了变化，请重新确认"
        }
    }
}

@MainActor
@Observable
final class TransferEngine {
    var jobs: [TransferJob] = []
    var concurrency = 3
    var downloadConcurrency = 3
    var uploadSpeedLimit = TransferSpeedLimit.unlimited
    var downloadSpeedLimit = TransferSpeedLimit.unlimited
    var onUploadFinished: (@MainActor () -> Void)?
    var onAllFinished: (@MainActor () -> Void)?
    var onJournalError: (@MainActor (String) -> Void)?
    private(set) var journalErrorMessage: String?

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var taskGenerations: [UUID: UInt64] = [:]
    private var resources: [UUID: TransferResource] = [:]
    private var retryDescriptors: [UUID: RetryDescriptor] = [:]
    private var persistedRetries: [UUID: PersistedTransferRetry] = [:]
    private var unavailableRetryReasons: [UUID: String] = [:]
    private var checkpoints: [UUID: TransferCheckpoint] = [:]
    private var userIntents: [UUID: UserIntent] = [:]
    private var progressSamples: [UUID: [(date: Date, bytes: Int64)]] = [:]
    private var runningUploads = 0
    private var runningDownloads = 0
    private let journal: any TransferJournaling
    private let bookmarks: any TransferBookmarking
    private var lastProgressPersistenceAt: Date?
    private var lastCheckpointWrite: [UUID: TimeInterval] = [:]
    private let clientProvider: @MainActor @Sendable (OSSAccount, OSSBucket?) throws -> OSSClient

    init(
        journal: any TransferJournaling = NoopTransferJournal(),
        bookmarks: any TransferBookmarking = SecurityScopedTransferBookmarks()
    ) {
        self.journal = journal
        self.bookmarks = bookmarks
        self.clientProvider = Self.defaultClient
    }

    init(
        journal: any TransferJournaling,
        bookmarks: any TransferBookmarking,
        clientProvider: @escaping @MainActor @Sendable (OSSAccount, OSSBucket?) throws -> OSSClient
    ) {
        self.journal = journal
        self.bookmarks = bookmarks
        self.clientProvider = clientProvider
    }

    private static func defaultClient(account: OSSAccount, bucket: OSSBucket?) throws -> OSSClient {
        OSSClient(
            credentials: try AccountStore.credentials(for: account),
            region: account.signingRegion(for: bucket),
            endpointHost: account.apiHost(for: bucket),
            bucket: bucket?.name
        )
    }

    var activeCount: Int { jobs.filter(\.isActive).count }
    var hasJobs: Bool { !jobs.isEmpty }

    struct PlannedUpload {
        var sourceURL: URL
        var fileURL: URL
        var filename: String
        var contentType: String
        var size: Int64
        var objectKey: String
        var resource: TransferResource
        var failure: String?
    }

    struct UploadPlan {
        var items: [PlannedUpload]
        var skipped: Int
        var options = UploadPreparationOptions(imagesOnly: false, convertHEIC: false)
    }

    struct UploadPreparationOptions: Sendable {
        var imagesOnly: Bool
        var convertHEIC: Bool
        var ownedTemporaryURLs: Set<URL> = []
    }

    struct LocalFileIdentity: Equatable, Sendable {
        var size: Int64
        var modifiedAt: Date?
        var resourceIdentifier: String?

        static func capture(_ url: URL) throws -> LocalFileIdentity {
            // URLResourceValues is cached by Foundation for a URL instance. A
            // destination can therefore change after the overwrite prompt while
            // a second read still returns the old size/date. FileManager asks the
            // filesystem for a fresh stat snapshot every time.
            let path = URL(fileURLWithPath: url.path).standardizedFileURL.path
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.int64Value
            else {
                throw LocalFileReplacementError.unavailable(url.lastPathComponent)
            }
            let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            let identifier = device.flatMap { device in
                inode.map { inode in "\(device):\(inode)" }
            }
            return LocalFileIdentity(
                size: size,
                modifiedAt: attributes[.modificationDate] as? Date,
                resourceIdentifier: identifier
            )
        }
    }

    @discardableResult
    func enqueueUploads(
        urls: [URL],
        client: OSSClient,
        account: OSSAccount,
        bucket: OSSBucket?,
        prefix: String,
        settings: AppSettings,
        applyTemplate: Bool = true
    ) async -> Int {
        let options = UploadPreparationOptions(
            // imagesOnly is a browser display preference. It must never filter
            // files the user explicitly selected for upload.
            imagesOnly: false,
            convertHEIC: settings.convertHEIC
        )
        let plan = await Self.planUploads(
            urls: urls,
            prefix: prefix,
            template: account.prefixTemplate,
            applyTemplate: applyTemplate,
            options: options
        )
        enqueue(plan: plan, client: client, account: account, bucket: bucket, settings: settings)
        return plan.skipped
    }

    nonisolated static func planUploads(
        urls: [URL],
        prefix: String,
        template: String,
        applyTemplate: Bool,
        options: UploadPreparationOptions
    ) async -> UploadPlan {
        let rootLeases = urls.compactMap(SecurityScopeLease.init(url:))
        let expansion = expand(urls)
        var items: [PlannedUpload] = []
        for failure in expansion.failures {
            items.append(
                PlannedUpload(
                    sourceURL: failure.url,
                    fileURL: failure.url,
                    filename: failure.url.lastPathComponent,
                    contentType: "",
                    size: 0,
                    objectKey: "",
                    resource: TransferResource(retainedResources: rootLeases),
                    failure: failure.message
                )
            )
        }
        for entry in expansion.files {
            let url = entry.url
            let sourceLease = SecurityScopeLease(url: url)
            do {
                let prepared = try await prepare(url: url, convertHEIC: options.convertHEIC)
                var cleanupURLs = prepared.fileURL == url ? [] : [prepared.fileURL]
                if options.ownedTemporaryURLs.contains(url) {
                    cleanupURLs.append(url)
                }
                let retained: [AnyObject] = rootLeases + [sourceLease].compactMap { $0 }
                let resource = TransferResource(
                    cleanupURLs: cleanupURLs,
                    retainedResources: retained
                )
                var relative = entry.relativePath
                if prepared.filename != url.lastPathComponent {
                    relative = PathTemplate.replacingLastComponent(relative, with: prepared.filename)
                }
                let key = PathTemplate.destinationKey(
                    prefix: prefix,
                    filename: relative,
                    applyTemplate: applyTemplate,
                    template: template
                )
                items.append(
                    PlannedUpload(
                        sourceURL: url,
                        fileURL: prepared.fileURL,
                        filename: prepared.filename,
                        contentType: prepared.contentType,
                        size: prepared.size,
                        objectKey: key,
                        resource: resource,
                        failure: nil
                    )
                )
            } catch {
                let retained: [AnyObject] = rootLeases + [sourceLease].compactMap { $0 }
                let cleanupURLs = options.ownedTemporaryURLs.contains(url) ? [url] : []
                items.append(
                    PlannedUpload(
                        sourceURL: url,
                        fileURL: url,
                        filename: url.lastPathComponent,
                        contentType: "",
                        size: 0,
                        objectKey: "",
                        resource: TransferResource(
                            cleanupURLs: cleanupURLs,
                            retainedResources: retained
                        ),
                        failure: error.localizedDescription
                    )
                )
            }
        }
        return UploadPlan(items: items, skipped: expansion.skipped, options: options)
    }

    func enqueue(
        plan: UploadPlan,
        client: OSSClient,
        account: OSSAccount,
        bucket: OSSBucket?,
        settings: AppSettings,
        excludingSources: Set<URL> = [],
        overwriteDestinations: [String: OSSObjectIdentity] = [:]
    ) {
        enqueue(
            plan: plan,
            client: client,
            account: account,
            bucket: bucket,
            concurrentUploads: settings.concurrentUploads,
            speedLimit: settings.uploadSpeedLimit,
            playCompleteSound: settings.playCompleteSound,
            excludingSources: excludingSources,
            overwriteDestinations: overwriteDestinations
        )
    }

    func abandon(plan: UploadPlan) {
        plan.items.forEach { $0.resource.finish() }
    }

    func enqueueDownloadJobs(
        items: [(object: OSSObject, destination: URL)],
        client: OSSClient,
        account: OSSAccount? = nil,
        bucket: OSSBucket? = nil,
        scopedRoot: URL,
        speedLimit: TransferSpeedLimit? = nil,
        overwriteDestinations: [URL: LocalFileIdentity] = [:]
    ) {
        guard !items.isEmpty else { return }
        let rootLease = SecurityScopeLease(url: scopedRoot)
        for item in items {
            let dest = item.destination
            let job = TransferJob(
                id: UUID(),
                kind: .download,
                status: .queued,
                title: item.object.name,
                objectKey: item.object.key,
                localURL: dest,
                transferred: 0,
                total: item.object.size,
                errorMessage: nil,
                publicURL: nil,
                finishedAt: nil
            )
            jobs.append(job)
            let jobID = job.id
            retryDescriptors[jobID] = .download(
                DownloadRetryDescriptor(
                    client: client,
                    account: account,
                    bucket: bucket,
                    object: item.object,
                    destination: dest,
                    scopedRoot: scopedRoot,
                    speedLimit: speedLimit ?? downloadSpeedLimit,
                    overwriteIdentity: overwriteDestinations[dest.standardizedFileURL]
                )
            )
            if let account,
               let relativeDestination = Self.relativePath(from: scopedRoot, to: dest),
               let rootBookmark = try? bookmarks.makeBookmark(for: scopedRoot) {
                persistedRetries[jobID] = .download(
                    PersistedDownloadRetry(
                        accountID: account.id,
                        bucket: bucket,
                        rootBookmark: rootBookmark,
                        object: item.object,
                        relativeDestination: relativeDestination
                    )
                )
            }
            resources[jobID] = TransferResource(
                retainedResources: [rootLease].compactMap { $0 }
            )
            startTask(for: jobID)
        }
        persistJournal()
        updateDockBadge()
    }

    func pause(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.isActive else { return }
        userIntents[id] = .pause
        tasks[id]?.cancel()
        mutate(id) { current in
            current.status = .paused
            current.finishedAt = nil
            current.errorMessage = nil
        }
        pumpFinished()
    }

    func resume(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }),
              job.status == .paused,
              retryDescriptors[id] != nil
        else { return }
        mutate(id) { current in
            current.status = .queued
            current.finishedAt = nil
            current.errorMessage = nil
        }
        // A cancelled runUpload/runDownload may still be unwinding. Starting
        // another task for the same job would share the checkpoint and steal
        // the pause/cancel intent. Wait for that task to finish.
        if tasks[id] == nil {
            startTask(for: id)
        }
    }

    func pauseAll() {
        jobs.filter(\.isActive).forEach { pause($0.id) }
    }

    func resumeAll() {
        jobs.filter { $0.status == .paused }.forEach { resume($0.id) }
    }

    func cancel(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }),
              job.isActive || job.status == .paused
        else { return }
        userIntents[id] = .cancel
        tasks[id]?.cancel()
        mutate(id) { current in
            current.status = .cancelled
            current.finishedAt = .now
        }
        if job.status != .running {
            tasks[id] = nil
            let descriptor = retryDescriptors[id]
            let checkpoint = checkpoints[id]
            Task { [weak self] in
                await self?.discardCheckpoint(checkpoint, descriptor: descriptor)
            }
            checkpoints[id] = nil
            finishResource(id)
        }
        pumpFinished()
        if activeCount == 0, !jobs.contains(where: { $0.status == .paused }) {
            onAllFinished?()
        }
    }

    func cancelAll() {
        jobs.filter { $0.isActive || $0.status == .paused }.forEach { cancel($0.id) }
    }

    func clearFinished() {
        let removedIDs = Set(jobs.filter(\.isFinished).map(\.id))
        jobs.removeAll(where: \.isFinished)
        for id in removedIDs {
            let checkpoint = checkpoints[id]
            let descriptor = retryDescriptors[id]
            Task { [weak self] in
                await self?.discardCheckpoint(checkpoint, descriptor: descriptor)
            }
            retryDescriptors[id] = nil
            persistedRetries[id] = nil
            unavailableRetryReasons[id] = nil
            checkpoints[id] = nil
            progressSamples[id] = nil
        }
        persistJournal()
    }

    func canRetry(_ id: UUID) -> Bool {
        guard let descriptor = retryDescriptors[id] else { return false }
        switch descriptor {
        case .upload(let upload):
            return FileManager.default.fileExists(atPath: upload.sourceURL.path)
        case .download:
            return true
        }
    }

    func canResume(_ id: UUID) -> Bool {
        jobs.first(where: { $0.id == id })?.status == .paused && retryDescriptors[id] != nil
    }

    func checkpoint(for id: UUID) -> TransferCheckpoint? {
        checkpoints[id]
    }

    func recordCheckpoint(_ id: UUID, checkpoint: TransferCheckpoint?) {
        checkpoints[id] = checkpoint
        // Checkpoint callbacks fire per chunk; persist at most every ~0.5 s
        // per job instead of rewriting the whole journal per chunk. The final
        // state is always flushed by the status-change persistJournal calls.
        let now = ProcessInfo.processInfo.systemUptime
        if checkpoint == nil || now - (lastCheckpointWrite[id] ?? -.infinity) >= 0.5 {
            lastCheckpointWrite[id] = now
            persistJournal()
        }
    }

    func moveToTop(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].status == .queued
        else { return }
        let job = jobs.remove(at: index)
        let destination = jobs.firstIndex(where: { $0.status == .queued }) ?? jobs.endIndex
        jobs.insert(job, at: destination)
        persistJournal()
    }

    func unavailableRetryReason(_ id: UUID) -> String? {
        unavailableRetryReasons[id]
    }

    func retry(_ id: UUID) {
        guard let descriptor = retryDescriptors[id] else { return }
        switch descriptor {
        case .upload(let upload):
            guard FileManager.default.fileExists(atPath: upload.sourceURL.path) else { return }
            Task {
                let plan = await Self.planUploads(
                    urls: [upload.sourceURL],
                    prefix: "",
                    template: "",
                    applyTemplate: false,
                    options: upload.options
                )
                var exactPlan = plan
                if !exactPlan.items.isEmpty {
                    exactPlan.items[0].objectKey = upload.objectKey
                }
                enqueue(
                    plan: exactPlan,
                    client: upload.client,
                    account: upload.account,
                    bucket: upload.bucket,
                    concurrentUploads: concurrency,
                    speedLimit: upload.speedLimit,
                    playCompleteSound: upload.playSound,
                    // An overwrite approval is single-use. A retry occurs after
                    // time and remote state may have changed, so it must return
                    // to create-only behavior and ask again through a new plan.
                    overwriteDestinations: [:]
                )
            }
        case .download(let download):
            enqueueDownloadJobs(
                items: [(download.object, download.destination)],
                client: download.client,
                account: download.account,
                bucket: download.bucket,
                scopedRoot: download.scopedRoot,
                speedLimit: download.speedLimit
            )
        }
    }

    func restore(accounts: [OSSAccount]) {
        let records: [PersistedTransfer]
        do {
            records = try journal.load()
            journalErrorMessage = nil
        } catch {
            reportJournalError("无法恢复传输记录：\(error.localizedDescription)")
            return
        }
        jobs = records.map(\.job)
        retryDescriptors.removeAll()
        persistedRetries.removeAll()
        unavailableRetryReasons.removeAll()
        var restored: [UUID: TransferCheckpoint] = [:]
        for record in records {
            if let checkpoint = record.checkpoint {
                restored[record.job.id] = checkpoint
            }
        }
        checkpoints = restored

        for record in records {
            let id = record.job.id
            if jobs.first(where: { $0.id == id })?.isActive == true,
               record.checkpoint != nil {
                mutate(id, persist: false) { job in
                    job.status = .paused
                    job.errorMessage = nil
                    job.finishedAt = nil
                }
            } else if jobs.first(where: { $0.id == id })?.isActive == true {
                mutate(id, persist: false) { job in
                    job.status = .failed
                    job.errorMessage = "上次退出时传输中断，可重试"
                    job.finishedAt = .now
                }
            }
            guard let retry = record.retry else { continue }
            persistedRetries[id] = retry
            restore(retry: retry, for: id, accounts: accounts)
            rehydrateJobURLs(id)
        }
        persistJournal()
        updateDockBadge()
    }

    private func enqueue(
        plan: UploadPlan,
        client: OSSClient,
        account: OSSAccount,
        bucket: OSSBucket?,
        concurrentUploads: Int,
        speedLimit: TransferSpeedLimit,
        playCompleteSound: Bool,
        excludingSources: Set<URL> = [],
        overwriteDestinations: [String: OSSObjectIdentity] = [:]
    ) {
        concurrency = concurrentUploads
        uploadSpeedLimit = speedLimit
        for item in plan.items {
            if let failure = item.failure {
                jobs.append(
                    TransferJob(
                        id: UUID(),
                        kind: .upload,
                        status: .failed,
                        title: item.filename,
                        objectKey: item.objectKey,
                        localURL: item.sourceURL,
                        transferred: 0,
                        total: 0,
                        errorMessage: failure,
                        publicURL: nil,
                        finishedAt: .now
                    )
                )
                item.resource.finish()
                continue
            }
            if excludingSources.contains(item.sourceURL) {
                item.resource.finish()
                continue
            }
            let job = TransferJob(
                id: UUID(),
                kind: .upload,
                status: .queued,
                title: item.filename,
                objectKey: item.objectKey,
                localURL: item.fileURL,
                transferred: 0,
                total: item.size,
                errorMessage: nil,
                publicURL: account.publicURL(
                    bucketName: client.bucket ?? bucket?.name ?? "",
                    bucket: bucket,
                    key: item.objectKey
                ),
                finishedAt: nil
            )
            jobs.append(job)
            retryDescriptors[job.id] = .upload(
                UploadRetryDescriptor(
                    client: client,
                    account: account,
                    bucket: bucket,
                    sourceURL: item.sourceURL,
                    preparedFileURL: item.fileURL,
                    objectKey: item.objectKey,
                    contentType: item.contentType,
                    acl: account.defaultACL,
                    options: plan.options,
                    speedLimit: speedLimit,
                    playSound: playCompleteSound,
                    expectedDestination: overwriteDestinations[item.objectKey]
                )
            )
            if let sourceBookmark = try? bookmarks.makeBookmark(for: item.sourceURL) {
                let preparedBookmark: Data?
                if item.fileURL.standardizedFileURL != item.sourceURL.standardizedFileURL {
                    preparedBookmark = try? bookmarks.makeBookmark(for: item.fileURL)
                } else {
                    preparedBookmark = nil
                }
                persistedRetries[job.id] = .upload(
                    PersistedUploadRetry(
                        accountID: account.id,
                        bucket: bucket,
                        sourceBookmark: sourceBookmark,
                        objectKey: item.objectKey,
                        imagesOnly: plan.options.imagesOnly,
                        convertHEIC: plan.options.convertHEIC,
                        playSound: playCompleteSound,
                        preparedBookmark: preparedBookmark
                    )
                )
            }
            resources[job.id] = item.resource
            startTask(for: job.id)
        }
        persistJournal()
        updateDockBadge()
    }

    private func runUpload(
        id: UUID,
        client: OSSClient,
        key: String,
        fileURL: URL,
        contentType: String,
        acl: ObjectACL,
        speedLimit: TransferSpeedLimit,
        playSound: Bool,
        expectedDestination: OSSObjectIdentity?
    ) async {
        guard await waitForSlot(id: id, kind: .upload) else {
            if Task.isCancelled {
                await finishCancellation(id: id)
            } else if jobs.first(where: { $0.id == id })?.status == .cancelled {
                finishResource(id)
            }
            return
        }
        defer {
            finishSlot(kind: .upload)
        }
        mutate(id) { $0.status = .running }
        do {
            let suppliedCheckpoint: MultipartUploadCheckpoint?
            if case .upload(let checkpoint) = checkpoints[id] {
                suppliedCheckpoint = checkpoint
            } else {
                suppliedCheckpoint = nil
            }
            let integrityVerified = try await client.putObject(
                key: key,
                fileURL: fileURL,
                contentType: contentType,
                acl: acl,
                expectedDestination: expectedDestination,
                // A version-enabled Bucket can safely retain a concurrently
                // created value as an older version. Suspended/unknown states
                // remain blocked by OSSClient.
                allowVersionedCreate: expectedDestination == nil,
                overwrite: expectedDestination != nil,
                speedLimit: speedLimit,
                checkpoint: suppliedCheckpoint,
                onCheckpoint: { [weak self] checkpoint in
                    Task { @MainActor in
                        self?.recordCheckpoint(
                            id,
                            checkpoint: checkpoint.map(TransferCheckpoint.upload)
                        )
                    }
                },
                onProgress: { [weak self] sent, total in
                Task { @MainActor in
                    self?.recordProgress(id, transferred: sent, total: total)
                }
            })
            mutate(id) { job in
                job.status = .completed
                job.transferred = job.total
                job.finishedAt = .now
                job.integrityVerified = integrityVerified
            }
            checkpoints[id] = nil
            finishResource(id)
            Haptics.commit()
            if playSound {
                NSSound(named: "Glass")?.play()
            }
            onUploadFinished?()
        } catch is CancellationError {
            await finishCancellation(id: id)
        } catch {
            if userIntents[id] == .pause {
                await finishCancellation(id: id)
                return
            }
            // Failed jobs are only retried from scratch (never resumed), so
            // discard the checkpoint now: otherwise a failed multipart upload
            // keeps its uploadID (and billed parts) on OSS forever, and a
            // failed download leaves its .partial file behind.
            let checkpoint = checkpoints[id]
            let descriptor = retryDescriptors[id]
            Task { [weak self] in
                await self?.discardCheckpoint(checkpoint, descriptor: descriptor)
            }
            checkpoints[id] = nil
            mutate(id) { job in
                job.status = .failed
                job.errorMessage = error.localizedDescription
                job.finishedAt = .now
            }
            finishResource(id)
        }
    }

    private func startTask(for id: UUID) {
        guard let descriptor = retryDescriptors[id] else { return }
        let generation = (taskGenerations[id] ?? 0) &+ 1
        taskGenerations[id] = generation
        switch descriptor {
        case .upload(let upload):
            tasks[id] = Task { [weak self] in
                await self?.runPreparedUpload(id: id, upload: upload)
                self?.taskDidFinish(id, generation: generation)
            }
        case .download(let download):
            tasks[id] = Task { [weak self] in
                await self?.runDownload(
                    id: id,
                    client: download.client,
                    key: download.object.key,
                    expectedETag: download.object.etag,
                    destination: download.destination,
                    root: download.scopedRoot,
                    speedLimit: download.speedLimit,
                    overwriteIdentity: download.overwriteIdentity
                )
                self?.taskDidFinish(id, generation: generation)
            }
        }
    }

    private func taskDidFinish(_ id: UUID, generation: UInt64) {
        guard taskGenerations[id] == generation else { return }
        tasks[id] = nil
        if jobs.first(where: { $0.id == id })?.status == .queued {
            startTask(for: id)
        }
        pumpFinished()
    }

    private func runPreparedUpload(id: UUID, upload: UploadRetryDescriptor) async {
        var fileURL = upload.preparedFileURL
        var contentType = upload.contentType
        if upload.needsPreparation {
            do {
                let prepared = try await Self.prepare(
                    url: upload.sourceURL,
                    convertHEIC: upload.options.convertHEIC
                )
                fileURL = prepared.fileURL
                contentType = prepared.contentType
                if prepared.fileURL != upload.sourceURL {
                    resources[id] = TransferResource(cleanupURLs: [prepared.fileURL])
                    if case .upload(var persisted) = persistedRetries[id] {
                        persisted.preparedBookmark = try? bookmarks.makeBookmark(for: prepared.fileURL)
                        persistedRetries[id] = .upload(persisted)
                    }
                }
                var updated = upload
                updated.preparedFileURL = fileURL
                updated.contentType = contentType
                updated.needsPreparation = false
                retryDescriptors[id] = .upload(updated)
                mutate(id) { job in
                    job.total = prepared.size
                }
            } catch is CancellationError {
                await finishCancellation(id: id)
                return
            } catch {
                if userIntents[id] == .pause {
                    await finishCancellation(id: id)
                    return
                }
                mutate(id) { job in
                    job.status = .failed
                    job.errorMessage = error.localizedDescription
                    job.finishedAt = .now
                }
                finishResource(id)
                pumpFinished()
                if activeCount == 0, !jobs.contains(where: { $0.status == .paused }) {
                    onAllFinished?()
                }
                return
            }
        }
        await runUpload(
            id: id,
            client: upload.client,
            key: upload.objectKey,
            fileURL: fileURL,
            contentType: contentType,
            acl: upload.acl,
            speedLimit: upload.speedLimit,
            playSound: upload.playSound,
            expectedDestination: upload.expectedDestination
        )
    }

    private func finishCancellation(id: UUID) async {
        let status = jobs.first(where: { $0.id == id })?.status
        let storedIntent = userIntents.removeValue(forKey: id)
        let intent: UserIntent
        if let storedIntent {
            intent = storedIntent
        } else if status == .paused || status == .queued {
            // A stale task is exiting after pause/resume already changed status.
            if status == .queued { return }
            intent = .pause
        } else {
            intent = .cancel
        }
        if intent == .pause {
            if jobs.first(where: { $0.id == id })?.status == .queued {
                return
            }
            mutate(id) { job in
                job.status = .paused
                job.finishedAt = nil
                job.errorMessage = nil
            }
            return
        }
        let checkpoint = checkpoints[id]
        await discardCheckpoint(checkpoint, descriptor: retryDescriptors[id])
        checkpoints[id] = nil
        finishResource(id)
        mutate(id) { job in
            job.status = .cancelled
            job.finishedAt = .now
        }
    }

    private func discardCheckpoint(
        _ checkpoint: TransferCheckpoint?,
        descriptor: RetryDescriptor?
    ) async {
        guard let checkpoint, let descriptor else { return }
        switch (checkpoint, descriptor) {
        case (.upload(let upload), .upload(let retry)):
            try? await retry.client.abortMultipartUpload(upload)
        case (.download(let download), .download(let retry)):
            try? retry.client.removePartialDownload(
                checkpoint: download,
                destination: retry.destination,
                within: retry.scopedRoot
            )
        default:
            break
        }
    }

    private func runDownload(
        id: UUID,
        client: OSSClient,
        key: String,
        expectedETag: String,
        destination: URL,
        root: URL,
        speedLimit: TransferSpeedLimit,
        overwriteIdentity: LocalFileIdentity?
    ) async {
        guard await waitForSlot(id: id, kind: .download) else {
            if Task.isCancelled {
                await finishCancellation(id: id)
            } else if jobs.first(where: { $0.id == id })?.status == .cancelled {
                finishResource(id)
            }
            return
        }
        defer {
            finishSlot(kind: .download)
        }
        mutate(id) { $0.status = .running }
        do {
            let suppliedCheckpoint: RangeDownloadCheckpoint?
            if case .download(let checkpoint) = checkpoints[id] {
                suppliedCheckpoint = checkpoint
            } else {
                suppliedCheckpoint = nil
            }
            let expectedSize = jobs.first(where: { $0.id == id })?.total ?? 0
            let integrityVerified = try await client.downloadResumable(
                key: key,
                to: destination,
                within: root,
                expectedSize: expectedSize,
                expectedETag: expectedETag,
                overwrite: overwriteIdentity != nil,
                speedLimit: speedLimit,
                checkpoint: suppliedCheckpoint,
                beforeReplacingExisting: overwriteIdentity.map { expected in
                    { @Sendable in
                        let current = try LocalFileIdentity.capture(destination)
                        guard current == expected else {
                            throw LocalFileReplacementError.changed(destination.lastPathComponent)
                        }
                    }
                },
                onCheckpoint: { [weak self] checkpoint in
                    Task { @MainActor in
                        self?.recordCheckpoint(
                            id,
                            checkpoint: checkpoint.map(TransferCheckpoint.download)
                        )
                    }
                },
                onProgress: { [weak self] sent, total in
                    Task { @MainActor in
                        self?.recordProgress(id, transferred: sent, total: total)
                    }
                }
            )
            mutate(id) { job in
                job.status = .completed
                job.transferred = max(job.transferred, job.total)
                job.finishedAt = .now
                job.integrityVerified = integrityVerified
            }
            checkpoints[id] = nil
            finishResource(id)
            Haptics.commit()
        } catch is CancellationError {
            await finishCancellation(id: id)
        } catch {
            if userIntents[id] == .pause {
                await finishCancellation(id: id)
                return
            }
            // See the upload path: a failed download must not keep its
            // .partial file around for retries that start from scratch.
            let checkpoint = checkpoints[id]
            let descriptor = retryDescriptors[id]
            Task { [weak self] in
                await self?.discardCheckpoint(checkpoint, descriptor: descriptor)
            }
            checkpoints[id] = nil
            mutate(id) { job in
                job.status = .failed
                job.errorMessage = error.localizedDescription
                job.finishedAt = .now
            }
            finishResource(id)
        }
    }

    private func waitForSlot(id: UUID, kind: TransferKind) async -> Bool {
        while !Task.isCancelled {
            guard let index = jobs.firstIndex(where: { $0.id == id }),
                  jobs[index].status == .queued
            else { return false }
            let hasEarlierQueued = jobs[..<index].contains { $0.status == .queued && $0.kind == kind }
            let hasCapacity = kind == .upload
                ? runningUploads < concurrency
                : runningDownloads < downloadConcurrency
            if hasCapacity && !hasEarlierQueued { break }
            try? await Task.sleep(for: .milliseconds(80))
        }
        guard !Task.isCancelled else { return false }
        if kind == .upload {
            runningUploads += 1
        } else {
            runningDownloads += 1
        }
        return true
    }

    private func finishSlot(kind: TransferKind) {
        if kind == .upload {
            runningUploads = max(0, runningUploads - 1)
        } else {
            runningDownloads = max(0, runningDownloads - 1)
        }
        pumpFinished()
        // Paused jobs are deliberately not active; only fire "all finished"
        // when nothing is running, queued, or paused.
        if activeCount == 0, !jobs.contains(where: { $0.status == .paused }) {
            onAllFinished?()
        }
    }

    private func pumpFinished() {
        updateDockBadge()
    }

    private func finishResource(_ id: UUID) {
        resources.removeValue(forKey: id)?.finish()
    }

    private func mutate(_ id: UUID, persist: Bool = true, _ body: (inout TransferJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        body(&jobs[index])
        if persist { persistJournal() }
    }

    func recordProgress(
        _ id: UUID,
        transferred: Int64,
        total: Int64,
        at timestamp: Date = .now
    ) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].isActive else { return }
        jobs[index].transferred = transferred
        if total > 0 { jobs[index].total = total }
        var samples = progressSamples[id, default: []]
        samples.append((timestamp, transferred))
        let cutoff = timestamp.addingTimeInterval(-30)
        samples.removeAll { $0.date < cutoff }
        if samples.count > 8 {
            samples.removeFirst(samples.count - 8)
        }
        progressSamples[id] = samples

        if let lastProgressPersistenceAt,
           timestamp.timeIntervalSince(lastProgressPersistenceAt) < 1 {
            return
        }
        lastProgressPersistenceAt = timestamp
        persistJournal()
    }

    func currentBytesPerSecond(_ id: UUID) -> Double? {
        guard let samples = progressSamples[id],
              let first = samples.first,
              let last = samples.last,
              last.date > first.date,
              last.bytes >= first.bytes
        else { return nil }
        return Double(last.bytes - first.bytes) / last.date.timeIntervalSince(first.date)
    }

    func estimatedRemaining(_ id: UUID) -> TimeInterval? {
        guard let job = jobs.first(where: { $0.id == id }),
              let rate = currentBytesPerSecond(id), rate > 0
        else { return nil }
        return Double(max(0, job.total - job.transferred)) / rate
    }

    private func updateDockBadge() {
        let count = activeCount
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        ProcessLifetime.setTransfersActive(count > 0)
    }

    private enum RetryDescriptor: Sendable {
        case upload(UploadRetryDescriptor)
        case download(DownloadRetryDescriptor)
    }

    private struct UploadRetryDescriptor: Sendable {
        var client: OSSClient
        var account: OSSAccount
        var bucket: OSSBucket?
        var sourceURL: URL
        var preparedFileURL: URL
        var objectKey: String
        var contentType: String
        var acl: ObjectACL
        var options: UploadPreparationOptions
        var speedLimit: TransferSpeedLimit
        var playSound: Bool
        var expectedDestination: OSSObjectIdentity?
        var needsPreparation: Bool = false
    }

    private struct DownloadRetryDescriptor: Sendable {
        var client: OSSClient
        var account: OSSAccount?
        var bucket: OSSBucket?
        var object: OSSObject
        var destination: URL
        var scopedRoot: URL
        var speedLimit: TransferSpeedLimit
        var overwriteIdentity: LocalFileIdentity?
    }

    private func restore(
        retry: PersistedTransferRetry,
        for id: UUID,
        accounts: [OSSAccount]
    ) {
        switch retry {
        case .upload(let upload):
            guard let account = accounts.first(where: { $0.id == upload.accountID }) else {
                unavailableRetryReasons[id] = "原账号已不存在，无法重试。"
                return
            }
            guard let source = try? bookmarks.resolve(upload.sourceBookmark) else {
                unavailableRetryReasons[id] = "原文件或文件夹权限已失效，请重新选择后再上传。"
                return
            }
            guard FileManager.default.fileExists(atPath: source.path) else {
                unavailableRetryReasons[id] = "原文件已移动或删除，请重新选择后再上传。"
                return
            }
            guard let client = try? clientProvider(account, upload.bucket) else {
                unavailableRetryReasons[id] = "账号密钥不可用，请重新编辑账号后再重试。"
                return
            }
            let converted = upload.convertHEIC && Self.isConvertibleHEIC(source)
            var prepared = source
            var needsPreparation = false
            if converted {
                if let preparedBookmark = upload.preparedBookmark,
                   let preparedURL = try? bookmarks.resolve(preparedBookmark),
                   FileManager.default.fileExists(atPath: preparedURL.path) {
                    prepared = preparedURL
                    resources[id] = TransferResource(cleanupURLs: [preparedURL])
                } else {
                    needsPreparation = true
                }
            }
            retryDescriptors[id] = .upload(
                UploadRetryDescriptor(
                    client: client,
                    account: account,
                    bucket: upload.bucket,
                    sourceURL: source,
                    preparedFileURL: prepared,
                    objectKey: upload.objectKey,
                    contentType: converted
                        ? "image/jpeg"
                        : (UTType(filenameExtension: source.pathExtension)?.preferredMIMEType
                            ?? "application/octet-stream"),
                    acl: account.defaultACL,
                    options: UploadPreparationOptions(
                        imagesOnly: false,
                        convertHEIC: upload.convertHEIC
                    ),
                    speedLimit: uploadSpeedLimit,
                    playSound: upload.playSound,
                    // Legacy journals may contain a broad overwrite flag. Never
                    // revive it after restart because it was not bound to a
                    // destination identity and may now authorize stale writes.
                    expectedDestination: nil,
                    needsPreparation: needsPreparation
                )
            )
        case .download(let download):
            guard let account = accounts.first(where: { $0.id == download.accountID }) else {
                unavailableRetryReasons[id] = "原账号已不存在，无法重试。"
                return
            }
            guard let root = try? bookmarks.resolve(download.rootBookmark),
                  let destination = try? FileSafety.destination(
                    root: root,
                    relativePath: download.relativeDestination
                  ) else {
                unavailableRetryReasons[id] = "下载目录权限已失效，请重新选择目录。"
                return
            }
            guard let client = try? clientProvider(account, download.bucket) else {
                unavailableRetryReasons[id] = "账号密钥不可用，请重新编辑账号后再重试。"
                return
            }
            retryDescriptors[id] = .download(
                DownloadRetryDescriptor(
                    client: client,
                    account: account,
                    bucket: download.bucket,
                    object: download.object,
                    destination: destination,
                    scopedRoot: root,
                    speedLimit: downloadSpeedLimit,
                    overwriteIdentity: nil
                )
            )
        }
    }

    private func rehydrateJobURLs(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              let descriptor = retryDescriptors[id]
        else { return }
        switch descriptor {
        case .download(let download):
            jobs[index].localURL = download.destination
        case .upload(let upload):
            if jobs[index].localURL == nil {
                jobs[index].localURL = upload.sourceURL
            }
            if jobs[index].publicURL == nil {
                jobs[index].publicURL = upload.account.publicURL(
                    bucketName: upload.client.bucket ?? upload.bucket?.name ?? "",
                    bucket: upload.bucket,
                    key: upload.objectKey
                )
            }
        }
    }

    nonisolated private static func isConvertibleHEIC(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "heic" || ext == "heif"
    }

    private func persistJournal() {
        let records = jobs.map { job in
            PersistedTransfer(
                job: job,
                retry: persistedRetries[job.id],
                checkpoint: checkpoints[job.id]
            )
        }
        do {
            try journal.save(records)
            journalErrorMessage = nil
        } catch {
            reportJournalError("无法保存传输记录：\(error.localizedDescription)")
        }
    }

    private func reportJournalError(_ message: String) {
        journalErrorMessage = message
        onJournalError?(message)
    }

    nonisolated private static func relativePath(from root: URL, to destination: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard destinationPath.hasPrefix(prefix) else { return nil }
        return String(destinationPath.dropFirst(prefix.count))
    }

    private struct PreparedUpload {
        var fileURL: URL
        var filename: String
        var contentType: String
        var size: Int64
    }

    private struct ExpandedFile {
        var url: URL
        var relativePath: String
    }

    private struct Expansion {
        var files: [ExpandedFile]
        var skipped: Int
        var failures: [(url: URL, message: String)]
    }

    private enum UserIntent {
        case pause
        case cancel
    }

    nonisolated private static func expand(_ urls: [URL]) -> Expansion {
        var result: [ExpandedFile] = []
        var failures: [(url: URL, message: String)] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                if isPackage(url) {
                    result.append(ExpandedFile(url: url, relativePath: url.lastPathComponent))
                    continue
                }
                if let enumerator = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey, .isPackageKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    for case let file as URL in enumerator {
                        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey])
                        guard values?.isRegularFile == true || values?.isPackage == true else { continue }
                        let relative = PathTemplate.nestedRelative(
                            rootName: url.lastPathComponent,
                            rootPath: url.path,
                            filePath: file.path
                        )
                        result.append(ExpandedFile(url: file, relativePath: relative))
                    }
                } else {
                    failures.append((
                        url,
                        "无法读取文件夹“\(url.lastPathComponent)”"
                    ))
                }
            } else {
                result.append(ExpandedFile(url: url, relativePath: url.lastPathComponent))
            }
        }
        return Expansion(files: result, skipped: 0, failures: failures)
    }

    nonisolated private static func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
    }

    nonisolated private static func prepare(url: URL, convertHEIC: Bool) async throws -> PreparedUpload {
        try await ensureUbiquitousItemIsDownloaded(url)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue || isPackage(url) {
            throw OSSServiceError(
                statusCode: 0,
                code: "UnsupportedPackage",
                message: "无法将程序包作为单个文件上传：\(url.lastPathComponent)",
                requestId: ""
            )
        }
        let ext = url.pathExtension.lowercased()
        if convertHEIC, ext == "heic" || ext == "heif" {
            guard let image = NSImage(contentsOf: url),
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
            else {
                throw OSSServiceError(statusCode: 0, code: "HEICConvert", message: "无法将 HEIC 转为 JPEG", requestId: "")
            }
            let name = (url.lastPathComponent as NSString).deletingPathExtension + ".jpg"
            let dest = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "-" + name)
            try jpeg.write(to: dest)
            return PreparedUpload(fileURL: dest, filename: name, contentType: "image/jpeg", size: Int64(jpeg.count))
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return PreparedUpload(
            fileURL: url,
            filename: url.lastPathComponent,
            contentType: ImageKind.contentType(for: url.lastPathComponent),
            size: Int64(values.fileSize ?? 0)
        )
    }

    nonisolated private static func ensureUbiquitousItemIsDownloaded(_ url: URL) async throws {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        var values = try url.resourceValues(forKeys: keys)
        guard values.isUbiquitousItem == true,
              values.ubiquitousItemDownloadingStatus == .notDownloaded
        else { return }

        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        for _ in 0..<300 {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(200))
            values = try url.resourceValues(forKeys: keys)
            if values.ubiquitousItemDownloadingStatus != .notDownloaded {
                return
            }
        }
        throw OSSServiceError(
            statusCode: 0,
            code: "ICloudDownloadTimeout",
            message: "等待 iCloud 下载文件超时",
            requestId: ""
        )
    }
}
