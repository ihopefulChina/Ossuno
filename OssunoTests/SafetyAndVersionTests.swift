import Foundation
import Security
import Testing
@testable import Ossuno

struct SafetyAndVersionTests {
    @Test func corruptPrimaryRecoversTheLastKnownGoodAccounts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-account-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = AccountRepository(directory: directory)
        let original = Self.account(name: "Original")
        var updated = original
        updated.name = "Updated"

        try repository.save([original])
        try repository.save([updated])
        try Data("not-json".utf8).write(to: repository.primaryURL, options: .atomic)

        let loaded = repository.load()

        #expect(loaded.accounts == [updated])
        #expect(loaded.recovery?.kind == .restoredBackup)
        let restored = try JSONDecoder().decode(
            [OSSAccount].self,
            from: Data(contentsOf: repository.primaryURL)
        )
        #expect(restored == [updated])
        let preservedCorruptFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("accounts.corrupt-") }
        #expect(preservedCorruptFiles.count == 1)
        #expect(repository.load().permitsCredentialCleanup)
    }

    @Test func accountTransactionRollbackDoesNotPromoteTheFailedVersionToBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-account-rollback-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = AccountRepository(directory: directory)
        let original = Self.account(name: "Original")
        var failedUpdate = original
        failedUpdate.name = "Failed update"

        try repository.save([original])
        try repository.save([failedUpdate])
        // Mirrors AppModel's compensating save after a Keychain update fails.
        try repository.save([original])
        try Data("not-json".utf8).write(to: repository.primaryURL, options: .atomic)

        let loaded = repository.load()

        #expect(loaded.accounts == [original])
        #expect(loaded.recovery?.kind == .restoredBackup)
    }

    @Test func firstAccountSaveCreatesARecoverableBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-account-first-save-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = AccountRepository(directory: directory)
        let original = Self.account(name: "Original")
        try repository.save([original])
        try FileManager.default.removeItem(at: repository.primaryURL)

        let loaded = repository.load()

        #expect(loaded.accounts == [original])
        #expect(loaded.recovery?.kind == .restoredBackup)
        #expect(!loaded.permitsCredentialCleanup)
        // This backup is byte-for-byte the last committed configuration, so
        // the authority snapshot can safely recognize it on the next launch.
        #expect(repository.load().permitsCredentialCleanup)
    }

    @Test func authoritySnapshotRecoversWhenBothAccountFilesAreMissing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-account-authority-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = AccountRepository(directory: directory)
        let original = Self.account(name: "Original")
        try repository.save([original])
        try FileManager.default.removeItem(at: repository.primaryURL)
        try FileManager.default.removeItem(at: repository.backupURL)

        let loaded = repository.load()

        #expect(loaded.accounts == [original])
        #expect(loaded.recovery?.kind == .restoredBackup)
        #expect(!loaded.permitsCredentialCleanup)
        #expect(repository.load().permitsCredentialCleanup)
    }

    @Test func legacyBackupRecoveryStaysNonAuthoritativeAcrossRelaunches() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-account-legacy-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = AccountRepository(directory: directory)
        let original = Self.account(name: "Original")
        var newer = original
        newer.name = "Newer"
        try repository.save([original])
        try repository.save([newer])
        // Simulates an installation created before cleanup authority existed.
        try FileManager.default.removeItem(at: repository.cleanupAuthorityURL)
        try Data("not-json".utf8).write(to: repository.primaryURL, options: .atomic)

        let recovered = repository.load()

        #expect(recovered.accounts == [original])
        #expect(!recovered.permitsCredentialCleanup)
        #expect(!repository.load().permitsCredentialCleanup)
    }

    @Test func twoCorruptAccountFilesArePreservedAndReported() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-account-unrecoverable-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = AccountRepository(directory: directory)
        try Data("broken-primary".utf8).write(to: repository.primaryURL)
        try Data("broken-backup".utf8).write(to: repository.backupURL)

        let loaded = repository.load()

        #expect(loaded.accounts.isEmpty)
        #expect(loaded.recovery?.kind == .unrecoverable)
        #expect(try Data(contentsOf: repository.primaryURL) == Data("broken-primary".utf8))
        #expect(try Data(contentsOf: repository.backupURL) == Data("broken-backup".utf8))
        #expect(!loaded.permitsCredentialCleanup)
    }

    @Test func missingAccountConfigurationNeverAuthorizesKeychainCleanup() {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-account-missing-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = AccountRepository(directory: directory)

        let loaded = repository.load()

        #expect(loaded.accounts.isEmpty)
        #expect(loaded.recovery == nil)
        #expect(!loaded.permitsCredentialCleanup)
    }

    @Test func onlyAValidPrimaryAccountFileAuthorizesKeychainCleanup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-account-authoritative-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = AccountRepository(directory: directory)
        try repository.save([])

        let loaded = repository.load()

        #expect(loaded.accounts.isEmpty)
        #expect(loaded.recovery == nil)
        #expect(loaded.permitsCredentialCleanup)
    }

    @Test func externallyReplacedValidAccountFileDoesNotAuthorizeKeychainCleanup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-account-replaced-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = AccountRepository(directory: directory)
        try repository.save([Self.account(name: "Original")])
        try JSONEncoder().encode([OSSAccount]()).write(to: repository.primaryURL, options: .atomic)

        let loaded = repository.load()

        #expect(loaded.accounts.isEmpty)
        #expect(loaded.recovery == nil)
        #expect(!loaded.permitsCredentialCleanup)
    }

    @Test func aNewAccountInheritsItsBucketPermission() {
        #expect(AccountDraft.fresh().defaultACL == .default)
    }

    @Test func inheritedBucketPermissionUsesASignedLinkFallback() {
        let account = OSSAccount(
            id: UUID(),
            name: "Inherited",
            accessKeyId: "test",
            regionID: "cn-hangzhou",
            endpointOverride: "",
            cdnDomain: "",
            defaultACL: .default,
            prefixTemplate: "",
            useTransferAccelerate: false,
            createdAt: .now
        )

        #expect(account.prefersSignedLinks)
    }

    @Test func onlyExplicitPublicPermissionsNeedAPublicWarning() {
        #expect(!ObjectACL.default.isPublic)
        #expect(!ObjectACL.private.isPublic)
        #expect(ObjectACL.publicRead.isPublic)
        #expect(ObjectACL.publicReadWrite.isPublic)
    }

    @Test func accountDraftRequiresNonWhitespaceCredentials() {
        var draft = AccountDraft.fresh()
        draft.accessKeyId = "   "
        draft.secret = "   "

        #expect(!draft.isReadyToSave)

        draft.accessKeyId = "LTAI-example"
        draft.secret = "example-secret"

        #expect(draft.isReadyToSave)
    }

    @Test func newlyPublicPermissionsRequireConfirmation() {
        #expect(AccountACLConfirmation.requiresConfirmation(from: .private, to: .publicRead))
        #expect(AccountACLConfirmation.requiresConfirmation(from: .publicRead, to: .publicReadWrite))
        #expect(AccountACLConfirmation.requiresConfirmation(from: nil, to: .publicRead))
        #expect(!AccountACLConfirmation.requiresConfirmation(from: .publicRead, to: .publicRead))
        #expect(!AccountACLConfirmation.requiresConfirmation(from: .publicRead, to: .private))
        #expect(!AccountACLConfirmation.requiresConfirmation(from: nil, to: .default))
    }

    @Test func malformedVersionsAreRejected() {
        #expect(AppVersion.parts("1.two.3") == nil)
        #expect(AppVersion.parts("1..3") == nil)
        #expect(AppVersion.parts("1.2.3") == [1, 2, 3])
        #expect(!AppVersion.isNewer("1.two.3", than: "0.0.3"))
    }

    @Test func diagnosticsExcludeStorageAndCredentialIdentifiers() {
        let account = OSSAccount(
            id: UUID(),
            name: "Production Account",
            accessKeyId: "LTAI-sensitive-id",
            regionID: "cn-secret-region",
            endpointOverride: "https://internal.example.test",
            cdnDomain: "secret-cdn.example.test",
            defaultACL: .private,
            prefixTemplate: "private/{yyyy}/",
            useTransferAccelerate: false,
            createdAt: .now
        )
        let transfer = TransferJob(
            id: UUID(),
            kind: .upload,
            status: .failed,
            title: "private-object.jpg",
            objectKey: "production-bucket/private/object.jpg",
            localURL: URL(filePath: "/Users/private/Documents/private-object.jpg"),
            transferred: 0,
            total: 42,
            errorMessage: "RequestId secret-request-id",
            publicURL: URL(string: "https://production-bucket.example.test/private/object.jpg?Signature=secret"),
            finishedAt: .now
        )
        let input = DiagnosticsReport.Input(
            version: "0.0.9",
            build: "9",
            operatingSystem: "macOS 15.6",
            architecture: "arm64",
            updateFeedHost: "github.com",
            accounts: [account],
            transfers: [transfer],
            settings: .init(
                concurrentUploads: 3,
                convertHEIC: true,
                imagesOnly: true,
                playCompleteSound: false,
                showMenuBarWhileTransferring: true,
                checkUpdatesAutomatically: true
            )
        )

        let report = DiagnosticsReport.make(input: input)

        #expect(report.contains("Ossuno 0.0.9 (9)"))
        #expect(report.contains("Configured accounts: 1"))
        #expect(report.contains("Failed transfers: 1"))
        for sensitive in [
            "LTAI", "secret", "Production Account", "production-bucket",
            "private/object.jpg", "/Users/", "RequestId", "Signature"
        ] {
            #expect(!report.localizedCaseInsensitiveContains(sensitive))
        }
    }

    @Test func transferAccelerateIsOnlyUsedForObjectScopedHosts() {
        let account = OSSAccount(
            id: UUID(),
            name: "Accel",
            accessKeyId: "test",
            regionID: "cn-hangzhou",
            endpointOverride: "",
            cdnDomain: "",
            defaultACL: .default,
            prefixTemplate: "",
            useTransferAccelerate: true,
            createdAt: .now
        )
        let bucket = OSSBucket(
            name: "design-assets",
            regionID: "cn-hangzhou",
            location: "oss-cn-hangzhou",
            extranetEndpoint: "oss-cn-hangzhou.aliyuncs.com",
            createdAt: nil
        )

        #expect(account.apiHost(for: nil) == "oss-cn-hangzhou.aliyuncs.com")
        #expect(account.apiHost(for: bucket) == "oss-accelerate.aliyuncs.com")
    }

    @Test func objectURLPreservesExactKey() throws {
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
        let url = try #require(
            account.publicURL(
                bucketName: "bucket",
                bucket: nil,
                key: "a//空 格/+?#.txt"
            )
        )

        #expect(url.host == "bucket.oss-cn-hangzhou.aliyuncs.com")
        #expect(url.path(percentEncoded: true) == "/a//%E7%A9%BA%20%E6%A0%BC/%2B%3F%23.txt")
    }

    @Test func objectURLPreservesCustomEndpointSchemeAndPort() throws {
        let account = OSSAccount(
            id: UUID(),
            name: "Test",
            accessKeyId: "test",
            regionID: "cn-hangzhou",
            endpointOverride: "http://127.0.0.1:9000",
            cdnDomain: "",
            defaultACL: .publicRead,
            prefixTemplate: "",
            useTransferAccelerate: false,
            createdAt: .now
        )

        let url = try #require(account.publicURL(bucketName: "bucket", bucket: nil, key: "a.txt"))

        #expect(url.scheme == "http")
        #expect(url.host == "127.0.0.1")
        #expect(url.port == 9000)
    }

    @Test func sanitizedNamesReplaceColonAndRejectTraversal() {
        #expect(FileSafety.sanitizedFileName("shot:1.png") == "shot-1.png")
        #expect(FileSafety.sanitizedRelativePath("a:b/c:d.jpg") == "a-b/c-d.jpg")
        #expect(FileSafety.sanitizedFileName("..") == "未命名文件")
        #expect(FileSafety.sanitizedFileName("") == "未命名文件")
    }

    @Test func unsafeRelativePathsAreRejected() {
        #expect(throws: FileSafety.Error.self) {
            try FileSafety.relativeComponents("../outside.txt")
        }
        #expect(throws: FileSafety.Error.self) {
            try FileSafety.relativeComponents("/absolute.txt")
        }
        #expect(throws: FileSafety.Error.self) {
            try FileSafety.relativeComponents("nested//empty.txt")
        }
    }

    @Test func symlinkCannotEscapeDownloadRoot() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-safety-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = base.appending(path: "root", directoryHint: .isDirectory)
        let outside = base.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "link"),
            withDestinationURL: outside
        )

        #expect(throws: FileSafety.Error.self) {
            try FileSafety.destination(root: root, relativePath: "link/file.txt")
        }
    }

    @Test func objectNamesRejectPathComponents() throws {
        #expect(try ObjectNameValidator.validate(" photo.jpg ") == "photo.jpg")
        #expect(throws: FileSafety.Error.self) { try ObjectNameValidator.validate("") }
        #expect(throws: FileSafety.Error.self) { try ObjectNameValidator.validate("nested/name") }
        #expect(throws: FileSafety.Error.self) { try ObjectNameValidator.validate("..") }
    }

    @Test func linkTextEscapingUsesTheOutputContext() {
        #expect(LinkEscaping.markdownAlt("a]b\\c") == "a\\]b\\\\c")
        #expect(LinkEscaping.htmlAttribute("a\"<&") == "a&quot;&lt;&amp;")
        #expect(
            LinkEscaping.markdownImage(name: "a]b.png", url: "https://example.test/a.png")
                == "![a\\]b.png](https://example.test/a.png)"
        )
        #expect(
            LinkEscaping.htmlImage(name: "a\"<&.png", url: "https://example.test/a.png")
                == "<img src=\"https://example.test/a.png\" alt=\"a&quot;&lt;&amp;.png\" />"
        )
    }

    @Test func orphanCleanupOnlyTargetsUUIDCredentialsForDeletedAccounts() {
        let kept = UUID(uuidString: "0A3DB3D9-5721-46B9-AC8A-4D17CA76093B")!
        let removed = UUID(uuidString: "9A910925-62B0-42D2-8B83-2E371F145B95")!
        let stored: Set<String> = [
            kept.uuidString,
            kept.uuidString + ".sts",
            removed.uuidString,
            removed.uuidString + ".sts",
            "future-format-entry"
        ]

        #expect(
            SecretStore.orphanedCredentialAccounts(
                stored,
                validAccountIDs: [kept],
                configurationIsAuthoritative: true
            ) == [
                removed.uuidString,
                removed.uuidString + ".sts"
            ]
        )
        #expect(
            SecretStore.orphanedCredentialAccounts(
                stored,
                validAccountIDs: [],
                configurationIsAuthoritative: false
            ).isEmpty
        )
    }

    @Test func automaticKeychainFallsBackWhenDataProtectionNeedsEntitlement() throws {
        let access = RecordingKeychainAccess(modernFailure: errSecMissingEntitlement)
        let backend = KeychainSecretBackend(access: access)
        let account = "account"

        try backend.set("temporary-secret", for: account)
        #expect(try backend.get(account) == "temporary-secret")
        try backend.delete(account)

        #expect(access.setModes == [true, false])
        #expect(access.readModes == [true, false, true, false])
        #expect(access.deleteModes == [false])
        #expect(access.values.isEmpty)
    }

    @Test func automaticKeychainDeleteRestoresTheFirstBackendWhenTheSecondFails() throws {
        let access = RecordingKeychainAccess(deleteFailureModes: [false])
        let backend = KeychainSecretBackend(access: access)
        let account = "account"
        try access.set("same-secret", for: account, modern: true)
        try access.set("same-secret", for: account, modern: false)

        #expect(throws: KeychainStoreError.self) {
            try backend.delete(account)
        }

        #expect(access.deleteModes == [true, false])
        #expect(try access.read(account: account, modern: true) == "same-secret")
        #expect(try access.read(account: account, modern: false) == "same-secret")
    }

    @Test func automaticKeychainDeleteContinuesWhenAnEmptyModernLookupNeedsEntitlementToDelete() throws {
        let access = RecordingKeychainAccess(modernDeleteFailure: errSecMissingEntitlement)
        let backend = KeychainSecretBackend(access: access)
        let account = "account"
        try access.set("legacy-secret", for: account, modern: false)

        try backend.delete(account)

        #expect(access.readModes == [true, false])
        #expect(access.deleteModes == [true, false])
        #expect(try access.read(account: account, modern: false) == nil)
    }

    @Test func automaticKeychainDeleteDoesNotHideAnEntitlementFailureForAnObservedModernValue() throws {
        let access = RecordingKeychainAccess(modernDeleteFailure: errSecMissingEntitlement)
        let backend = KeychainSecretBackend(access: access)
        let account = "account"
        try access.set("modern-secret", for: account, modern: true)

        #expect(throws: KeychainStoreError.self) {
            try backend.delete(account)
        }

        #expect(access.deleteModes == [true])
        #expect(try access.read(account: account, modern: true) == "modern-secret")
    }

    @Test func commonKeychainErrorsProvideChineseRecoveryGuidance() {
        #expect(
            KeychainStoreError(status: errSecMissingEntitlement)
                .localizedDescription.contains("已签名的最新版本")
        )
        #expect(
            KeychainStoreError(status: errSecInteractionNotAllowed)
                .localizedDescription.contains("解锁")
        )
        #expect(
            KeychainStoreError(status: errSecAuthFailed)
                .localizedDescription.contains("允许访问")
        )
    }

    private static func account(name: String) -> OSSAccount {
        OSSAccount(
            id: UUID(uuidString: "0A3DB3D9-5721-46B9-AC8A-4D17CA76093B")!,
            name: name,
            accessKeyId: "redacted",
            regionID: "cn-hangzhou",
            endpointOverride: "",
            cdnDomain: "",
            defaultACL: .private,
            prefixTemplate: "",
            useTransferAccelerate: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

private final class RecordingKeychainAccess: KeychainItemAccessing, @unchecked Sendable {
    var values: [String: String] = [:]
    var setModes: [Bool] = []
    var readModes: [Bool] = []
    var deleteModes: [Bool] = []
    private let modernFailure: OSStatus?
    private let modernDeleteFailure: OSStatus?
    private let deleteFailureModes: Set<Bool>

    init(
        modernFailure: OSStatus? = nil,
        modernDeleteFailure: OSStatus? = nil,
        deleteFailureModes: Set<Bool> = []
    ) {
        self.modernFailure = modernFailure
        self.modernDeleteFailure = modernDeleteFailure
        self.deleteFailureModes = deleteFailureModes
    }

    func read(account: String, modern: Bool) throws -> String? {
        readModes.append(modern)
        try failIfNeeded(modern)
        return values[key(account, modern: modern)]
    }

    func set(_ value: String, for account: String, modern: Bool) throws {
        setModes.append(modern)
        try failIfNeeded(modern)
        values[key(account, modern: modern)] = value
    }

    func delete(account: String, modern: Bool) throws {
        deleteModes.append(modern)
        try failIfNeeded(modern)
        if modern, let modernDeleteFailure {
            throw KeychainStoreError(status: modernDeleteFailure)
        }
        if deleteFailureModes.contains(modern) {
            throw KeychainStoreError(status: errSecAuthFailed)
        }
        values.removeValue(forKey: key(account, modern: modern))
    }

    private func failIfNeeded(_ modern: Bool) throws {
        if modern, let modernFailure {
            throw KeychainStoreError(status: modernFailure)
        }
    }

    private func key(_ account: String, modern: Bool) -> String {
        "\(modern ? "modern" : "legacy"):\(account)"
    }
}

struct TransferFinishNoticeTests {
    @Test func successfulUploadProducesACompletionNotice() {
        let job = TransferJob(
            id: UUID(),
            kind: .upload,
            status: .completed,
            title: "封面.png",
            objectKey: "封面.png",
            transferred: 10,
            total: 10,
            finishedAt: .now
        )

        let notice = TransferFinishNotice.content(jobs: [job])

        #expect(notice?.title == "传输完成")
        #expect(notice?.body == "“封面.png”已上传")
    }

    @Test func cancelledQueueDoesNotNotify() {
        let job = TransferJob(
            id: UUID(),
            kind: .download,
            status: .cancelled,
            title: "a.txt",
            objectKey: "a.txt",
            transferred: 0,
            total: 10,
            finishedAt: .now
        )

        #expect(TransferFinishNotice.content(jobs: [job]) == nil)
    }

    @Test func mixedResultsMentionFailures() {
        let jobs = [
            TransferJob(
                id: UUID(),
                kind: .upload,
                status: .completed,
                title: "a.txt",
                objectKey: "a.txt",
                transferred: 1,
                total: 1,
                finishedAt: .now
            ),
            TransferJob(
                id: UUID(),
                kind: .upload,
                status: .failed,
                title: "b.txt",
                objectKey: "b.txt",
                transferred: 0,
                total: 1,
                errorMessage: "denied",
                finishedAt: .now
            ),
        ]

        let notice = TransferFinishNotice.content(jobs: jobs)

        #expect(notice?.title == "传输已结束")
        #expect(notice?.body == "成功 1 项，失败 1 项")
    }
}
