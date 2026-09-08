import AppKit
import Foundation
import Observation

enum AppLinks {
    static let website = URL(string: "https://ihopefulchina.github.io/Ossuno/")!
    static let privacy = URL(string: "https://ihopefulchina.github.io/Ossuno/privacy.html")!
    static let support = URL(string: "https://ihopefulchina.github.io/Ossuno/support.html")!
    static let github = URL(string: "https://github.com/ihopefulChina/Ossuno")!
    static let releases = URL(string: "https://github.com/ihopefulChina/Ossuno/releases")!
    static let issues = URL(string: "https://github.com/ihopefulChina/Ossuno/issues")!
    static let security = URL(string: "https://github.com/ihopefulChina/Ossuno/security/policy")!
    static let privateSecurityReport = URL(string: "https://github.com/ihopefulChina/Ossuno/security/advisories/new")!
}

@MainActor
@Observable
final class AppServices {
    private static var sharedStorage: AppServices?
    static var shared: AppServices {
        if let sharedStorage { return sharedStorage }
        let services = AppServices(
            transfers: TransferEngine(journal: FileTransferJournal.live)
        )
        sharedStorage = services
        return services
    }

    var accounts: [OSSAccount]
    var accountRecovery: AccountRecovery?
    var settings = AppSettings()
    var transfers = TransferEngine()
    var updates = AppUpdater()
    var favorites = FavoriteStore()
    var showMenuBarExtra = false
    var transferFilter = TransferFilter.all
    weak var focused: AppModel?

    private var didBootstrap = false
    private let managesPersistedAccounts: Bool
    private let permitsCredentialCleanup: Bool
    private var sessionBoxes: [WeakSession] = []
    private var pendingIncomingURLs: [URL] = []
    private var didPresentAccountRecovery = false

    init(
        accounts: [OSSAccount]? = nil,
        settings: AppSettings = AppSettings(),
        transfers: TransferEngine = TransferEngine(),
        updates: AppUpdater = AppUpdater(),
        favorites: FavoriteStore = FavoriteStore()
    ) {
        self.managesPersistedAccounts = accounts == nil
        let loaded = accounts.map {
            AccountLoadResult(
                accounts: $0,
                recovery: nil,
                permitsCredentialCleanup: false
            )
        } ?? AccountStore.load()
        self.accounts = loaded.accounts
        self.accountRecovery = loaded.recovery
        self.permitsCredentialCleanup = loaded.permitsCredentialCleanup
        self.settings = settings
        self.transfers = transfers
        self.updates = updates
        self.favorites = favorites
    }

    var sessions: [AppModel] {
        sessionBoxes.compactMap(\.value)
    }

    func register(_ session: AppModel) {
        sessionBoxes.removeAll { $0.value == nil }
        if !sessionBoxes.contains(where: { $0.value === session }) {
            sessionBoxes.append(WeakSession(session))
        }
        focused = session
        if !didPresentAccountRecovery, let accountRecovery {
            didPresentAccountRecovery = true
            session.present(
                accountRecovery.message,
                error: accountRecovery.kind == .unrecoverable
            )
        }
        if !pendingIncomingURLs.isEmpty {
            let queued = pendingIncomingURLs
            pendingIncomingURLs = []
            session.ingestIncoming(queued)
        }
    }

    func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true
        // Never infer orphans from a recovered/corrupt account list: a backup
        // may legitimately omit newer accounts whose Keychain credentials are
        // still the only recoverable copy.
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if managesPersistedAccounts, permitsCredentialCleanup, !isRunningTests {
            do {
                try SecretStore.removeOrphanedCredentials(validAccountIDs: Set(accounts.map(\.id)))
            } catch {
                sessions.forEach {
                    $0.present("无法清理已删除账号留下的钥匙串凭证：\(error.localizedDescription)", error: true)
                }
            }
        }
        transfers.concurrency = settings.concurrentUploads
        transfers.downloadConcurrency = settings.concurrentDownloads
        transfers.uploadSpeedLimit = settings.uploadSpeedLimit
        transfers.downloadSpeedLimit = settings.downloadSpeedLimit
        transfers.onJournalError = { [weak self] message in
            self?.sessions.forEach { session in
                session.present(message, error: true)
            }
        }
        transfers.restore(accounts: accounts)
        updates.automaticallyChecksForUpdates = settings.checkUpdatesAutomatically
        transfers.onUploadFinished = { [weak self] in
            self?.sessions.forEach { session in
                session.noteBucketMutated()
                session.scheduleListingRefresh()
            }
        }
        transfers.onAllFinished = { [weak self] in
            guard let self else { return }
            showMenuBarExtra = false
            guard settings.notifyWhenTransfersFinish else { return }
            TransferNotifier.shared.postQueueFinished(
                jobs: transfers.jobs,
                sound: settings.playCompleteSound
            )
        }
    }

    func routeIncoming(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let target = sessions.first(where: { $0 === focused && $0.hasWorkspace })
            ?? sessions.first(where: \.hasWorkspace)
            ?? focused
            ?? sessions.first
        if let target {
            target.ingestIncoming(urls)
        } else {
            pendingIncomingURLs.append(contentsOf: urls)
        }
    }
}

private final class WeakSession {
    weak var value: AppModel?
    init(_ value: AppModel) { self.value = value }
}
