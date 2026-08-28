import AppKit
import Foundation
import Observation

enum BannerAction: Equatable {
    case undoCloudOperation
}

enum InspectorSurface: Equatable {
    case unavailable
    case folder
    case searchEmpty
    case object(OSSObject)
    case multiple(count: Int, folderCount: Int, objects: [OSSObject])
}

struct BannerMessage: Identifiable, Equatable {
    var id = UUID()
    var text: String
    var isError: Bool
    var action: BannerAction? = nil

    var displayDuration: Duration {
        action == nil ? .milliseconds(2_400) : .milliseconds(5_500)
    }
}

@MainActor
@Observable
final class AppModel {
    static let settingsSession = AppModel(kind: .settings)

    enum Kind {
        case window
        case settings
    }

    private let services: AppServices
    private let kind: Kind
    private let clientProvider: @MainActor (OSSAccount, OSSBucket?) throws -> OSSClient

    var accounts: [OSSAccount] {
        get { services.accounts }
        set { services.accounts = newValue }
    }
    var transfers: TransferEngine
    var settings: AppSettings
    var updates: AppUpdater
    var favorites: FavoriteStore
    var showMenuBarExtra: Bool {
        get { services.showMenuBarExtra }
        set { services.showMenuBarExtra = newValue }
    }
    var transferFilter: TransferFilter {
        get { services.transferFilter }
        set { services.transferFilter = newValue }
    }

    var selectedAccountID: OSSAccount.ID?
    var buckets: [OSSBucket] = []
    var selectedBucketName: String?
    var browser = BrowserModel()
    var searchScope: BucketSearchScope = .folder
    var searchFilter: BucketSearchFilter = .all
    var searchController = BucketSearchController()
    var searchSelectedKeys: Set<String> = []

    var showInspector = false
    var objectPropertiesModel: ObjectPropertiesModel?
    var showObjectProperties = false
    var crossBucketPreflight: CrossBucketPreflight?
    var showCrossBucketPreflight = false
    var cloudConflictPrompt: CloudConflictPrompt?
    var showAccountSheet = false
    var editingAccount: OSSAccount?
    var isLoadingBuckets = false
    var banner: BannerMessage?
    var previewItem: URL? {
        didSet {
            guard let oldValue,
                  oldValue != previewItem,
                  ownedPreviewURLs.remove(oldValue) != nil
            else { return }
            try? FileManager.default.removeItem(at: oldValue)
        }
    }
    var inspectorHead: ObjectHead?
    var inspectorText: String?
    var isLoadingHead = false
    var wantsDeleteConfirmation = false
    private var pendingDeleteKeys: Set<String> = []
    var wantsNewFolder = false
    var isOrganizingCloud = false {
        didSet { ProcessLifetime.setOrganizing(isOrganizingCloud) }
    }
    private(set) var lastCloudUndoOperation: CloudUndoOperation?
    private(set) var lastDeleteUndoOperation: CloudDeleteUndoOperation?
    var cloudClipboard: CloudDragPayload?
    var cloudClipboardMode: CloudOperationMode = .copy
    private var cloudClipboardChangeCount = -1
    var pendingOpenURLs: [URL] = []
    private var pendingOwnedTemporaryURLs: Set<URL> = []
    private var ownedPreviewURLs: Set<URL> = []
    var overwritePrompt: OverwritePrompt?
    private var uploadGeneration = 0
    private var previewGeneration = 0
    private var didLoadWindow = false
    private var listingRefreshTask: Task<Void, Never>?
    private var listingLoadTask: Task<ObjectListing, Error>?
    private var bucketLoadTask: Task<[OSSBucket], Error>?
    private var inspectorLoadTask: Task<(ObjectHead, String?), Error>?
    private let listingRequestGate = BrowserRequestGate()
    private let bucketRequestGate = BrowserRequestGate()
    private let inspectorRequestGate = BrowserRequestGate()

    private var lastAccountID: String {
        get { UserDefaults.standard.string(forKey: "nav.lastAccount") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "nav.lastAccount") }
    }
    private var lastBucketName: String {
        get { UserDefaults.standard.string(forKey: "nav.lastBucket") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "nav.lastBucket") }
    }

    var selectedAccount: OSSAccount? {
        accounts.first(where: { $0.id == selectedAccountID })
    }

    var selectedBucket: OSSBucket? {
        buckets.first(where: { $0.name == selectedBucketName })
    }

    var hasWorkspace: Bool {
        selectedAccount != nil && selectedBucket != nil
    }

    var canShowInformation: Bool {
        selectedBucket != nil
    }

    var canUndoCloudOperation: Bool {
        if let deletion = lastDeleteUndoOperation {
            return !isOrganizingCloud && isCurrentScope(for: deletion)
        }
        guard let operation = lastCloudUndoOperation else { return false }
        return !isOrganizingCloud && isCurrentScope(for: operation)
    }

    var undoCloudOperationTitle: String {
        if let deletion = lastDeleteUndoOperation,
           isCurrentScope(for: deletion) {
            return deletion.title
        }
        guard let operation = lastCloudUndoOperation,
              isCurrentScope(for: operation)
        else { return "撤销" }
        return operation.title
    }

    init(
        kind: Kind = .window,
        services: AppServices = .shared,
        clientProvider: @escaping @MainActor (OSSAccount, OSSBucket?) throws -> OSSClient = AppModel.defaultClient
    ) {
        self.kind = kind
        self.services = services
        self.clientProvider = clientProvider
        self.transfers = services.transfers
        self.settings = services.settings
        self.updates = services.updates
        self.favorites = services.favorites
        browser.viewMode = services.settings.preferredViewMode
        browser.imagesOnly = services.settings.imagesOnly
        if let stored = UUID(uuidString: lastAccountID), services.accounts.contains(where: { $0.id == stored }) {
            selectedAccountID = stored
        } else {
            selectedAccountID = services.accounts.first?.id
        }
        if kind == .window {
            services.register(self)
        }
    }

    func becomeFocused() {
        services.register(self)
    }

    func setPreferredViewMode(_ mode: BrowserViewMode) {
        settings.preferredViewMode = mode
        browser.viewMode = mode
    }

    func applyPreferredViewModeToAllSessions(_ mode: BrowserViewMode) {
        settings.preferredViewMode = mode
        for session in services.sessions {
            session.browser.viewMode = mode
        }
    }

    func bootstrap() {
        services.bootstrapIfNeeded()
        guard !didLoadWindow else { return }
        didLoadWindow = true
        browser.imagesOnly = settings.imagesOnly
        if selectedAccount != nil, buckets.isEmpty {
            Task { await refreshBuckets(selecting: lastBucketName.isEmpty ? nil : lastBucketName) }
        } else if selectedBucket != nil {
            Task { await refreshListing() }
        }
    }

    func pruneIfNeeded() {
        if let id = selectedAccountID, !accounts.contains(where: { $0.id == id }) {
            invalidateAllBrowserRequests()
            selectedAccountID = accounts.first?.id
            buckets = []
            selectedBucketName = nil
            browser.reset()
            if selectedAccount != nil {
                Task { await refreshBuckets() }
            }
        }
        browser.imagesOnly = settings.imagesOnly
    }

    var sidebarSelection: SidebarSelection? {
        if let accountID = selectedAccountID,
           let favorite = favorites.items.first(where: {
               $0.accountID == accountID
                   && $0.bucketName == selectedBucketName
                   && $0.prefix == browser.prefix
           }) {
            return .favorite(favorite.id)
        }
        if let name = selectedBucketName {
            return .bucket(name)
        }
        if let id = selectedAccountID {
            return .account(id)
        }
        return nil
    }

    func applySidebarSelection(_ selection: SidebarSelection?) {
        switch selection {
        case .account(let id):
            guard let account = accounts.first(where: { $0.id == id }),
                  selectedAccountID != id
            else { return }
            selectAccount(account)
        case .bucket(let name):
            guard let bucket = buckets.first(where: { $0.name == name }) else { return }
            if selectedBucketName == name, browser.prefix.isEmpty { return }
            selectBucket(bucket)
        case .favorite(let id):
            guard let favorite = favorites.items.first(where: { $0.id == id }) else { return }
            openFavorite(favorite)
        case nil:
            break
        }
    }

    func selectAccount(_ account: OSSAccount) {
        invalidateAllBrowserRequests()
        selectedAccountID = account.id
        lastAccountID = account.id.uuidString
        selectedBucketName = nil
        buckets = []
        browser.reset()
        Task { await refreshBuckets() }
    }

    func selectBucket(_ bucket: OSSBucket) {
        selectBucket(bucket, prefix: "")
    }

    private func selectBucket(_ bucket: OSSBucket, prefix: String) {
        clearBucketSearch()
        invalidateListingAndInspectorRequests()
        selectedBucketName = bucket.name
        lastBucketName = bucket.name
        browser.navigate(to: prefix, record: false)
        browser.backStack = []
        browser.forwardStack = []
        Task { await refreshListing() }
    }

    func openFolder(_ folder: OSSFolder) {
        invalidateListingAndInspectorRequests()
        browser.navigate(to: folder.prefix)
        Task { await refreshListing() }
    }

    var isCurrentFolderFavorite: Bool {
        isFavorite(prefix: browser.prefix)
    }

    func isFavorite(prefix: String) -> Bool {
        guard let accountID = selectedAccountID, let bucketName = selectedBucketName else {
            return false
        }
        return favorites.contains(
            accountID: accountID,
            bucketName: bucketName,
            prefix: prefix
        )
    }

    func toggleCurrentFolderFavorite() {
        let name = browser.prefix.isEmpty
            ? (selectedBucketName ?? "存储空间")
            : PathTemplate.lastComponent(browser.prefix)
        toggleFavorite(prefix: browser.prefix, name: name)
    }

    func toggleFavorite(prefix: String, name: String) {
        guard let accountID = selectedAccountID, let bucketName = selectedBucketName else { return }
        if isFavorite(prefix: prefix) {
            favorites.remove(accountID: accountID, bucketName: bucketName, prefix: prefix)
        } else {
            favorites.add(
                FavoriteLocation(
                    accountID: accountID,
                    bucketName: bucketName,
                    prefix: prefix,
                    name: name
                )
            )
        }
    }

    func openFavorite(_ favorite: FavoriteLocation) {
        guard let account = accounts.first(where: { $0.id == favorite.accountID }) else {
            favorites.remove(favorite)
            present("这个常用位置的账号已不存在", error: true)
            return
        }

        let expectedAccountID = favorite.accountID
        let expectedBucketName = favorite.bucketName

        if selectedAccountID != account.id {
            invalidateAllBrowserRequests()
            selectedAccountID = account.id
            lastAccountID = account.id.uuidString
            selectedBucketName = nil
            buckets = []
            browser.reset()
        }

        Task {
            if selectedAccountID == expectedAccountID,
               !buckets.contains(where: { $0.name == expectedBucketName }) {
                await refreshBuckets(selecting: expectedBucketName)
            }
            guard selectedAccountID == expectedAccountID else { return }
            guard let bucket = buckets.first(where: { $0.name == expectedBucketName }) else {
                favorites.remove(favorite)
                present("这个常用位置的存储空间已不存在", error: true)
                return
            }
            selectBucket(bucket, prefix: favorite.prefix)
        }
    }

    func goToPrefix(_ prefix: String) {
        invalidateListingAndInspectorRequests()
        browser.navigate(to: prefix)
        Task { await refreshListing() }
    }

    func goBack() {
        guard browser.goBack() else { return }
        invalidateListingAndInspectorRequests()
        Task { await refreshListing() }
    }

    func goForward() {
        guard browser.goForward() else { return }
        invalidateListingAndInspectorRequests()
        Task { await refreshListing() }
    }

    func refreshListing() async {
        guard let client = makeClient(),
              let accountID = selectedAccountID,
              let bucketName = selectedBucketName
        else { return }
        listingLoadTask?.cancel()
        let prefix = browser.prefix
        let context = listingRequestGate.begin(
            accountID: accountID,
            bucketName: bucketName,
            prefix: prefix,
            objectKey: nil
        )
        browser.isLoading = true
        browser.errorMessage = nil
        let task = Task { try await client.listAll(prefix: prefix) }
        listingLoadTask = task
        do {
            let listing = try await task.value
            guard listingRequestGate.canCommit(context),
                  selectedAccountID == context.accountID,
                  selectedBucketName == context.bucketName,
                  browser.prefix == context.prefix
            else { return }
            browser.apply(listing, imagesOnly: settings.imagesOnly)
            if listing.isTruncated {
                present("这个文件夹里的对象很多，只加载了前几页")
            }
        } catch is CancellationError {
            // Ignore.
        } catch {
            if listingRequestGate.canCommit(context) {
                browser.errorMessage = error.localizedDescription
            }
        }
        if listingRequestGate.canCommit(context) {
            browser.isLoading = false
            listingLoadTask = nil
        }
    }

    var isBucketSearchActive: Bool {
        guard searchScope == .bucket else { return false }
        let text = browser.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty || searchFilter != .all
    }

    /// Folder-scope typing must still reveal the scope picker; Bucket search
    /// and the large-file filter live in that chrome.
    var showsSearchChrome: Bool {
        selectedBucket != nil && (
            searchScope == .bucket
            || !browser.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || searchFilter != .all
        )
    }

    var searchVisibleKeys: Set<String> {
        Set(searchController.results.map(\.key))
    }

    var searchSelectedObjects: [OSSObject] {
        searchController.results.filter { searchSelectedKeys.contains($0.key) }
    }

    var actionableSelectionKeys: Set<String> {
        isBucketSearchActive ? searchSelectedKeys : browser.actionableSelectionKeys
    }

    var actionableObjects: [OSSObject] {
        isBucketSearchActive ? searchSelectedObjects : browser.selectedObjects
    }

    var actionableFolders: [OSSFolder] {
        isBucketSearchActive ? [] : browser.selectedFolders
    }

    func selectSearchKeys(_ keys: Set<String>) {
        searchSelectedKeys = keys.intersection(searchVisibleKeys)
    }

    func selectAllVisible() {
        if isBucketSearchActive {
            searchSelectedKeys = searchVisibleKeys
        } else {
            browser.selectAllVisible()
        }
    }

    func clearVisibleSelection() {
        if isBucketSearchActive {
            searchSelectedKeys = []
        } else {
            browser.clearSelection()
        }
    }

    func object(forKey key: String) -> OSSObject? {
        if isBucketSearchActive {
            return searchController.results.first(where: { $0.key == key })
        }
        return browser.visibleObjects.first(where: { $0.key == key })
            ?? browser.objects.first(where: { $0.key == key })
    }

    func openVisibleItem(id: String) {
        if isBucketSearchActive {
            if let object = object(forKey: id) {
                Task { await openSearchResult(object) }
            }
            return
        }
        if let folder = browser.folders.first(where: { $0.prefix == id }) {
            openFolder(folder)
            return
        }
        selectForContextMenu(id)
        Task { await quickLookSelection() }
    }

    func selectForContextMenu(_ key: String) {
        if isBucketSearchActive {
            if searchVisibleKeys.contains(key), !searchSelectedKeys.contains(key) {
                searchSelectedKeys = [key]
            }
            return
        }
        browser.selectForContextMenu(key: key)
    }

    func menuActionKeys(clickedKey: String) -> Set<String> {
        if actionableSelectionKeys.contains(clickedKey) {
            return actionableSelectionKeys
        }
        return [clickedKey]
    }

    func deleteMenuTitle(clickedKey: String) -> String {
        let keys = menuActionKeys(clickedKey: clickedKey)
        if keys.count > 1 {
            return "删除 \(keys.count) 项"
        }
        if !isBucketSearchActive, browser.folders.contains(where: { $0.prefix == clickedKey }) {
            return "删除文件夹"
        }
        return "删除"
    }

    func downloadMenuTitle(clickedKey: String) -> String {
        let keys = menuActionKeys(clickedKey: clickedKey)
        if !isBucketSearchActive {
            let files = browser.objects.filter { keys.contains($0.key) }.count
            let folders = browser.folders.filter { keys.contains($0.prefix) }.count
            if folders == 1 && files == 0 && keys.count == 1 {
                return "下载文件夹"
            }
            if files + folders > 1 {
                return "下载 \(files + folders) 项"
            }
        } else if keys.count > 1 {
            return "下载 \(keys.count) 项"
        }
        return "下载"
    }

    func requestRename(key: String) {
        guard !isOrganizingCloud else { return }
        if isBucketSearchActive,
           let object = searchController.results.first(where: { $0.key == key }) {
            Task { @MainActor in
                await openSearchResult(object)
                if !browser.beginRenaming(key: key) {
                    present("无法重命名这个项目，请打开所在文件夹后再试", error: true)
                }
            }
            return
        }
        Task { @MainActor in
            await Task.yield()
            if !browser.beginRenaming(key: key) {
                present("无法重命名这个项目", error: true)
            }
        }
    }

    func requestRenameSelection() {
        if isBucketSearchActive {
            guard searchSelectedObjects.count == 1, let object = searchSelectedObjects.first else { return }
            requestRename(key: object.key)
            return
        }
        guard !isOrganizingCloud else { return }
        guard browser.selectedKeys.count == 1, let key = browser.selectedKeys.first else { return }
        requestRename(key: key)
    }

    func runBucketSearch(now: Date = .now) async {
        guard searchScope == .bucket,
              let accountID = selectedAccountID,
              let bucketName = selectedBucketName,
              let client = makeClient()
        else {
            clearBucketSearch()
            return
        }
        let query = BucketSearchQuery(
            accountID: accountID,
            bucketName: bucketName,
            text: browser.searchText,
            filter: searchFilter
        )
        await searchController.search(query: query, now: now) { token in
            try await client.listObjectPage(prefix: "", token: token)
        }
        selectSearchKeys(searchSelectedKeys)
    }

    func cancelBucketSearch() {
        searchController.cancel()
    }

    func clearBucketSearch() {
        searchController.clear()
        searchSelectedKeys = []
    }

    func openSearchResult(_ object: OSSObject) async {
        searchScope = .folder
        browser.searchText = ""
        clearBucketSearch()
        invalidateListingAndInspectorRequests()
        browser.navigate(to: PathTemplate.parentPrefix(object.key))
        browser.revealObjectTemporarily(object.key)
        await refreshListing()
        browser.replaceSelection([object.key])
    }

    func refreshBuckets(selecting preferred: String? = nil) async {
        guard let account = selectedAccount else { return }
        bucketLoadTask?.cancel()
        let context = bucketRequestGate.begin(
            accountID: account.id,
            bucketName: nil,
            prefix: "",
            objectKey: nil
        )
        isLoadingBuckets = true
        do {
            let client = try clientProvider(account, nil)
            let task = Task { try await client.listBuckets() }
            bucketLoadTask = task
            let list = try await task.value
            guard bucketRequestGate.canCommit(context), selectedAccountID == context.accountID else { return }
            buckets = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let current = selectedBucketName
            if let current, buckets.contains(where: { $0.name == current }) {
                lastBucketName = current
                if browser.objects.isEmpty && browser.folders.isEmpty {
                    await refreshListing()
                }
            } else if let preferred, let match = buckets.first(where: { $0.name == preferred }) {
                selectBucket(match)
            } else if let first = buckets.first {
                selectBucket(first)
            }
        } catch is CancellationError {
            // A newer account request replaced this one.
        } catch {
            if bucketRequestGate.canCommit(context) {
                present(error.localizedDescription, error: true)
            }
        }
        if bucketRequestGate.canCommit(context) {
            isLoadingBuckets = false
            bucketLoadTask = nil
        }
    }

    func makeClient() -> OSSClient? {
        guard let account = selectedAccount else { return nil }
        do {
            return try clientProvider(account, selectedBucket)
        } catch {
            present(error.localizedDescription, error: true)
            return nil
        }
    }

    func testAccount(_ account: OSSAccount) async throws -> Int {
        let client = try clientProvider(account, nil)
        return try await client.listBuckets().count
    }

    func saveAccount(_ draft: AccountDraft) async throws {
        let region = draft.regionID
        let creds = OSSCredentials(
            accessKeyId: draft.accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines),
            accessKeySecret: draft.secret,
            securityToken: draft.token.isEmpty ? nil : draft.token
        )
        let probe = OSSClient(
            credentials: creds,
            region: region,
            endpointHost: OSSAccount(
                id: draft.id,
                name: draft.name,
                accessKeyId: creds.accessKeyId,
                regionID: region,
                endpointOverride: draft.endpointOverride,
                cdnDomain: draft.cdnDomain,
                defaultACL: draft.defaultACL,
                prefixTemplate: draft.prefixTemplate,
                useTransferAccelerate: draft.useTransferAccelerate,
                createdAt: draft.createdAt
            ).apiHost(for: nil),
            bucket: nil
        )
        let found = try await probe.listBuckets()
        let account = OSSAccount(
            id: draft.id,
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            accessKeyId: creds.accessKeyId,
            regionID: region,
            endpointOverride: draft.endpointOverride.trimmingCharacters(in: .whitespacesAndNewlines),
            cdnDomain: draft.cdnDomain.trimmingCharacters(in: .whitespacesAndNewlines),
            defaultACL: draft.defaultACL,
            prefixTemplate: draft.prefixTemplate,
            useTransferAccelerate: draft.useTransferAccelerate,
            createdAt: draft.createdAt
        )
        var updatedAccounts = accounts
        if let index = updatedAccounts.firstIndex(where: { $0.id == account.id }) {
            updatedAccounts[index] = account
        } else {
            updatedAccounts.append(account)
        }
        let previousSecrets = try AccountStore.secrets(id: account.id)
        try AccountStore.save(updatedAccounts)
        do {
            try AccountStore.storeSecrets(id: account.id, secret: draft.secret, token: draft.token)
        } catch {
            let primary = error
            do {
                try AccountStore.save(accounts)
                try AccountStore.restoreSecrets(id: account.id, snapshot: previousSecrets)
            } catch let rollbackError {
                throw AccountStoreError.rollbackFailed(
                    primary: primary.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw primary
        }
        accounts = updatedAccounts
        buckets = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        selectedAccountID = account.id
        lastAccountID = account.id.uuidString
        let keep = selectedBucketName
        if let keep, buckets.contains(where: { $0.name == keep }) {
            selectedBucketName = keep
            lastBucketName = keep
            await refreshListing()
        } else if let first = buckets.first {
            selectBucket(first)
        }
        present("已连接，共 \(found.count) 个存储空间")
        if !pendingOpenURLs.isEmpty, hasWorkspace {
            let queued = pendingOpenURLs
            let owned = pendingOwnedTemporaryURLs
            pendingOpenURLs = []
            pendingOwnedTemporaryURLs = []
            upload(urls: queued, ownedTemporaryURLs: owned)
        }
    }

    func deleteAccount(_ account: OSSAccount) {
        let updatedAccounts = accounts.filter { $0.id != account.id }
        var previousSecrets: AccountStore.Secrets?
        var persistedUpdatedAccounts = false
        do {
            let snapshot = try AccountStore.secrets(id: account.id)
            previousSecrets = snapshot
            // Commit the non-secret account list first. If the process exits
            // between these two durable writes, startup cleanup removes only an
            // orphaned Keychain item; it never loses credentials for an account
            // that still exists in accounts.json.
            try AccountStore.save(updatedAccounts)
            persistedUpdatedAccounts = true
            try AccountStore.deleteSecrets(id: account.id)
        } catch {
            let primary = error
            if persistedUpdatedAccounts || previousSecrets != nil {
                do {
                    if persistedUpdatedAccounts {
                        try AccountStore.save(accounts)
                    }
                    if let previousSecrets {
                        try AccountStore.restoreSecrets(id: account.id, snapshot: previousSecrets)
                    }
                } catch let rollbackError {
                    present(
                        AccountStoreError.rollbackFailed(
                            primary: primary.localizedDescription,
                            rollback: rollbackError.localizedDescription
                        ).localizedDescription,
                        error: true
                    )
                    return
                }
            }
            present("无法删除账号：\(primary.localizedDescription)", error: true)
            return
        }
        accounts = updatedAccounts
        services.sessions.forEach { $0.pruneIfNeeded() }
        pruneIfNeeded()
    }

    func upload(
        urls: [URL],
        to prefix: String? = nil,
        applyTemplate: Bool? = nil,
        ownedTemporaryURLs: Set<URL> = []
    ) {
        guard let account = selectedAccount, let bucket = selectedBucket else {
            pendingOpenURLs.append(contentsOf: urls)
            pendingOwnedTemporaryURLs.formUnion(ownedTemporaryURLs)
            showAccountSheet = accounts.isEmpty
            present("先添加账号并选择存储空间", error: true)
            return
        }
        // Resolve the client and destination synchronously. Otherwise a quick
        // account/Bucket switch before the Task starts can upload into the new
        // selection while retaining the old path.
        guard let client = makeClient() else {
            pendingOpenURLs.append(contentsOf: urls)
            pendingOwnedTemporaryURLs.formUnion(ownedTemporaryURLs)
            return
        }
        let dest = prefix ?? browser.prefix
        let useTemplate = applyTemplate ?? dest.isEmpty
        Task {
            await beginUpload(
                urls: urls,
                prefix: dest,
                applyTemplate: useTemplate,
                ownedTemporaryURLs: ownedTemporaryURLs,
                client: client,
                account: account,
                bucket: bucket
            )
        }
    }

    func confirmOverwrite() {
        guard let prompt = overwritePrompt else { return }
        guard prompt.canOverwriteSafely else {
            present("安全覆盖要求 Bucket 已开启版本控制", error: true)
            return
        }
        overwritePrompt = nil
        commit(
            plan: prompt.plan,
            client: prompt.client,
            account: prompt.account,
            bucket: prompt.bucket,
            overwriteDestinations: prompt.overwriteDestinations
        )
    }

    func skipOverwriteConflicts() {
        guard let prompt = overwritePrompt else { return }
        overwritePrompt = nil
        commit(
            plan: prompt.plan,
            client: prompt.client,
            account: prompt.account,
            bucket: prompt.bucket,
            excludingSources: prompt.skipSources
        )
    }

    func cancelOverwrite() {
        guard let prompt = overwritePrompt else { return }
        overwritePrompt = nil
        transfers.abandon(plan: prompt.plan)
    }

    private func beginUpload(
        urls: [URL],
        prefix: String,
        applyTemplate: Bool,
        ownedTemporaryURLs: Set<URL>,
        client: OSSClient,
        account: OSSAccount,
        bucket: OSSBucket
    ) async {
        uploadGeneration += 1
        let generation = uploadGeneration
        if overwritePrompt != nil {
            cancelOverwrite()
        }
        let options = TransferEngine.UploadPreparationOptions(
            // Browsing filters must never discard files selected for upload.
            imagesOnly: false,
            convertHEIC: settings.convertHEIC,
            ownedTemporaryURLs: ownedTemporaryURLs
        )
        let plan = await TransferEngine.planUploads(
            urls: urls,
            prefix: prefix,
            template: account.prefixTemplate,
            applyTemplate: applyTemplate,
            options: options
        )
        if plan.skipped > 0 {
            present("已跳过 \(plan.skipped) 个不支持的文件")
        }
        let viable = plan.items.filter { $0.failure == nil }
        guard !viable.isEmpty else {
            transfers.enqueue(plan: plan, client: client, account: account, bucket: bucket, settings: settings)
            return
        }
        let existingIdentities: [String: OSSObjectIdentity]
        do {
            let existing = try await existingKeys(among: viable.map(\.objectKey), client: client)
            existingIdentities = try await existingObjectIdentities(
                among: Array(existing),
                client: client
            )
        } catch {
            transfers.abandon(plan: plan)
            present("无法确认目标是否已有同名文件，已取消上传", error: true)
            return
        }
        guard generation == uploadGeneration else {
            transfers.abandon(plan: plan)
            return
        }
        let existing = Set(existingIdentities.keys)
        let needsOverwriteCapability = !existing.isEmpty
            && (settings.transferConflictPolicy == .ask
                || settings.transferConflictPolicy == .replace)
        let overwriteSafetyStatus: OSSBucketVersioningStatus?
        if needsOverwriteCapability {
            do {
                overwriteSafetyStatus = try await client.bucketVersioningStatus()
            } catch {
                // The prompt remains useful for skipping conflicts, but the
                // destructive option must be disabled when status is unknown.
                overwriteSafetyStatus = nil
            }
        } else {
            overwriteSafetyStatus = nil
        }
        guard generation == uploadGeneration else {
            transfers.abandon(plan: plan)
            return
        }
        let resolutions = TransferConflictPlanner.plan(
            keys: viable.map(\.objectKey),
            existing: existing,
            policy: settings.transferConflictPolicy
        )
        let replaceNeedsSafePrompt = settings.transferConflictPolicy == .replace
            && overwriteSafetyStatus != .enabled
        let conflictItems = zip(viable, resolutions).compactMap {
            item,
            resolution -> TransferEngine.PlannedUpload? in
            if resolution == .ask { return item }
            if replaceNeedsSafePrompt, existing.contains(item.objectKey) { return item }
            return nil
        }
        let conflicts = conflictItems.map {
            PathTemplate.relative($0.objectKey, under: prefix)
        }
        if !conflicts.isEmpty {
            let conflictKeys = Set(conflictItems.map(\.objectKey))
            let skipSources = Set(conflictItems.map(\.sourceURL))
            overwritePrompt = OverwritePrompt(
                plan: plan,
                client: client,
                account: account,
                bucket: bucket,
                conflicts: Array(Set(conflicts)).sorted(),
                skipSources: skipSources,
                overwriteDestinations: Dictionary(uniqueKeysWithValues: conflictKeys.compactMap {
                    key -> (String, OSSObjectIdentity)? in
                    guard let identity = existingIdentities[key]
                    else { return nil }
                    return (key, identity)
                }),
                versioningStatus: overwriteSafetyStatus
            )
            return
        }

        var resolvedPlan = plan
        var resolutionIndex = 0
        var excludedSources = Set<URL>()
        for index in resolvedPlan.items.indices where resolvedPlan.items[index].failure == nil {
            switch resolutions[resolutionIndex] {
            case .renamed(let key):
                resolvedPlan.items[index].objectKey = key
            case .skip:
                excludedSources.insert(resolvedPlan.items[index].sourceURL)
            case .useOriginal, .ask:
                break
            }
            resolutionIndex += 1
        }
        commit(
            plan: resolvedPlan,
            client: client,
            account: account,
            bucket: bucket,
            excludingSources: excludedSources,
            overwriteDestinations: settings.transferConflictPolicy == .replace
                ? existingIdentities.filter { key, _ in
                    resolvedPlan.items.contains { $0.objectKey == key }
                }
                : [:]
        )
    }

    private func commit(
        plan: TransferEngine.UploadPlan,
        client: OSSClient,
        account: OSSAccount,
        bucket: OSSBucket?,
        excludingSources: Set<URL> = [],
        overwriteDestinations: [String: OSSObjectIdentity] = [:]
    ) {
        transfers.enqueue(
            plan: plan,
            client: client,
            account: account,
            bucket: bucket,
            settings: settings,
            excludingSources: excludingSources,
            overwriteDestinations: overwriteDestinations
        )
        scheduleListingRefresh()
    }

    func existingKeys(among keys: [String], client: OSSClient) async throws -> Set<String> {
        let unique = Array(Set(keys))
        if unique.count > 40 {
            let parents = Set(unique.map { PathTemplate.parentPrefix($0) })
            var found = Set<String>()
            for parent in parents {
                let listing = try await client.listAllObjects(prefix: parent)
                if listing.truncated {
                    found.formUnion(try await existingKeysByHead(
                        unique.filter { PathTemplate.parentPrefix($0) == parent },
                        client: client
                    ))
                    continue
                }
                found.formUnion(listing.objects.map(\.key))
            }
            return found.intersection(unique)
        }
        return try await existingKeysByHead(unique, client: client)
    }

    private func existingKeysByHead(
        _ keys: [String],
        client: OSSClient,
        maximumConcurrent: Int = 8
    ) async throws -> Set<String> {
        let limit = max(1, maximumConcurrent)
        return try await withThrowingTaskGroup(of: (String, Bool).self) { group in
            var iterator = keys.makeIterator()
            for _ in 0..<min(limit, keys.count) {
                guard let key = iterator.next() else { break }
                group.addTask {
                    (key, try await client.objectExists(key: key))
                }
            }
            var found = Set<String>()
            while let (key, exists) = try await group.next() {
                if exists { found.insert(key) }
                if let next = iterator.next() {
                    group.addTask {
                        (next, try await client.objectExists(key: next))
                    }
                }
            }
            return found
        }
    }

    private func existingObjectIdentities(
        among keys: [String],
        client: OSSClient,
        maximumConcurrent: Int = 8
    ) async throws -> [String: OSSObjectIdentity] {
        let unique = Array(Set(keys))
        let limit = max(1, maximumConcurrent)
        return try await withThrowingTaskGroup(of: (String, OSSObjectIdentity?).self) { group in
            var iterator = unique.makeIterator()
            func enqueue(_ key: String) {
                group.addTask {
                    do {
                        let head = try await client.head(key: key)
                        guard let identity = head.identity else {
                            throw OSSServiceError(
                                statusCode: 0,
                                code: "MissingDestinationIdentity",
                                message: "OSS 未返回目标对象的完整标识，无法安全覆盖：\(key)",
                                requestId: ""
                            )
                        }
                        return (key, identity)
                    } catch let error as OSSServiceError where error.statusCode == 404 {
                        // The object disappeared after the listing. Treat it as
                        // create-only; the final write still performs its own
                        // no-overwrite/versioning safety check.
                        return (key, nil)
                    }
                }
            }
            for _ in 0..<min(limit, unique.count) {
                guard let key = iterator.next() else { break }
                enqueue(key)
            }
            var identities: [String: OSSObjectIdentity] = [:]
            while let (key, identity) = try await group.next() {
                if let identity { identities[key] = identity }
                if let next = iterator.next() { enqueue(next) }
            }
            return identities
        }
    }

    func ingestIncoming(_ urls: [URL]) {
        pendingOpenURLs.append(contentsOf: urls)
    }

    func confirmPendingOpen() {
        let urls = pendingOpenURLs
        let owned = pendingOwnedTemporaryURLs
        pendingOpenURLs = []
        pendingOwnedTemporaryURLs = []
        upload(urls: urls, ownedTemporaryURLs: owned)
    }

    func cancelPendingOpen() {
        pendingOwnedTemporaryURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        pendingOwnedTemporaryURLs = []
        pendingOpenURLs = []
    }

    func requestDeleteSelection() {
        requestDeleteSelection(keys: actionableSelectionKeys)
    }

    func requestDeleteSelection(keys: Set<String>, deferConfirmation: Bool = false) {
        guard !isOrganizingCloud else {
            present("请等待当前云端整理完成", error: true)
            return
        }
        // Restrict to what the current view actually shows and what
        // deleteSelection will act on, so the confirmation dialog never
        // over-counts hidden folder items during Bucket search.
        let visible = isBucketSearchActive ? searchVisibleKeys : browser.visibleKeys
        let known = Set(keys.filter(visible.contains))
        guard !known.isEmpty else { return }
        pendingDeleteKeys = known
        if isBucketSearchActive {
            searchSelectedKeys = known
        } else {
            browser.replaceSelection(known)
        }
        if deferConfirmation {
            DispatchQueue.main.async { [weak self] in
                self?.wantsDeleteConfirmation = true
            }
        } else {
            wantsDeleteConfirmation = true
        }
    }

    func cancelPendingDelete() {
        pendingDeleteKeys = []
    }

    private var deleteTargetFolders: [OSSFolder] {
        if isBucketSearchActive { return [] }
        return browser.folders.filter { pendingDeleteKeys.contains($0.prefix) }
    }

    private var deleteTargetObjects: [OSSObject] {
        if isBucketSearchActive {
            let fromResults = searchController.results.filter { pendingDeleteKeys.contains($0.key) }
            let missing = pendingDeleteKeys.subtracting(fromResults.map(\.key))
            // The confirmation dialog is live. If the search list refreshes
            // after the user clicked delete, still name the pending keys.
            let synthesized = missing.sorted().map {
                OSSObject(key: $0, size: 0, etag: "", lastModified: nil, storageClass: "")
            }
            return fromResults + synthesized
        }
        return browser.objects.filter { pendingDeleteKeys.contains($0.key) }
    }

    var deleteDialogTitle: String {
        let folders = deleteTargetFolders
        let files = deleteTargetObjects
        let count = folders.count + files.count
        if count <= 1, let folder = folders.first, files.isEmpty {
            return "删除文件夹“\(folder.name)”？"
        }
        if count <= 1, let file = files.first {
            return "删除“\(file.name)”？"
        }
        return "删除 \(max(count, pendingDeleteKeys.count)) 项？"
    }

    var deleteDialogMessage: String {
        let folders = deleteTargetFolders
        let files = deleteTargetObjects
        var lines: [String] = folders.prefix(8).map { "\($0.name)/" }
        let remain = 8 - lines.count
        if remain > 0 {
            lines.append(contentsOf: files.prefix(remain).map(\.name))
        }
        let extra = folders.count + files.count - lines.count
        var text = lines.joined(separator: "\n")
        if extra > 0 {
            text += "\n以及另外 \(extra) 项"
        }
        if !folders.isEmpty {
            text += (text.isEmpty ? "" : "\n") + "文件夹里的对象会一并从 OSS 删除。"
        } else if !text.isEmpty {
            text += "\n将从 OSS 删除。"
        }
        text += "\n若 Bucket 已开启版本控制，可立即撤销；否则删除是永久的。"
        return text
    }

    func scheduleListingRefresh() {
        listingRefreshTask?.cancel()
        listingRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await self?.refreshListing()
        }
    }

    func createFolder(named raw: String) async {
        let name: String
        do {
            name = try ObjectNameValidator.validate(raw)
        } catch {
            present(error.localizedDescription, error: true)
            return
        }
        guard let client = makeClient() else { return }
        let key = PathTemplate.join(browser.prefix, key: name) + "/"
        do {
            try await client.putData(
                key: key,
                data: Data(),
                contentType: "application/x-directory",
                acl: .default,
                allowVersionedCreate: true
            )
            noteBucketMutated()
            await refreshListing()
        } catch {
            present(error.localizedDescription, error: true)
        }
    }

    func deleteSelection() async {
        guard !isOrganizingCloud else {
            present("请等待当前云端整理完成", error: true)
            return
        }
        guard let client = makeClient(),
              let accountID = selectedAccountID,
              let bucketName = selectedBucketName
        else { return }
        let pending = pendingDeleteKeys
        pendingDeleteKeys = []
        let keys: [String]
        if !pending.isEmpty {
            // The confirmation already captured a visible, user-approved set.
            // Do not re-intersect with a search that may have restarted empty.
            keys = isBucketSearchActive
                ? pending.sorted()
                : browser.orderedVisibleKeys.filter(pending.contains)
        } else if isBucketSearchActive {
            keys = searchController.results.map(\.key).filter(actionableSelectionKeys.contains)
        } else {
            keys = browser.orderedVisibleKeys.filter(actionableSelectionKeys.contains)
        }
        guard !keys.isEmpty else { return }
        let previousCloudUndo = lastCloudUndoOperation
        let previousDeleteUndo = lastDeleteUndoOperation
        var receipts: [OSSDeleteReceipt] = []
        do {
            for key in keys {
                if key.hasSuffix("/") {
                    try await deletePrefix(key, client: client) { receipt in
                        receipts.append(receipt)
                    }
                } else {
                    receipts.append(try await client.deleteObject(key: key))
                }
            }
            lastCloudUndoOperation = nil
            recordDeleteUndo(
                receipts: receipts,
                sourceSelection: Set(keys),
                accountID: accountID,
                bucketName: bucketName
            )
            noteBucketMutated()
            browser.clearSelection()
            await refreshListing()
            Haptics.alignment()
            present(
                keys.count == 1 ? "已删除 1 项" : "已删除 \(keys.count) 项",
                action: lastDeleteUndoOperation == nil ? nil : .undoCloudOperation
            )
        } catch {
            guard !receipts.isEmpty else {
                lastCloudUndoOperation = previousCloudUndo
                lastDeleteUndoOperation = previousDeleteUndo
                present(error.localizedDescription, error: true)
                return
            }
            lastCloudUndoOperation = nil
            recordDeleteUndo(
                receipts: receipts,
                sourceSelection: Set(receipts.map(\.key)),
                accountID: accountID,
                bucketName: bucketName
            )
            noteBucketMutated()
            await refreshListing()
            present(
                "已删除 \(receipts.count) 个对象，之后失败：\(error.localizedDescription)",
                error: true,
                action: lastDeleteUndoOperation == nil ? nil : .undoCloudOperation
            )
        }
    }

    private func deletePrefix(
        _ prefix: String,
        client: OSSClient,
        onDeleted: (OSSDeleteReceipt) -> Void
    ) async throws {
        let listing = try await client.listAllObjects(prefix: prefix, includePlaceholders: true)
        if listing.truncated {
            throw OSSServiceError(
                statusCode: 0,
                code: "IncompleteList",
                message: "目录未列完，已取消删除，以免漏删",
                requestId: ""
            )
        }
        for object in listing.objects.sorted(by: { $0.key.count > $1.key.count }) {
            onDeleted(try await client.deleteObject(key: object.key))
        }
    }

    private func recordDeleteUndo(
        receipts: [OSSDeleteReceipt],
        sourceSelection: Set<String>,
        accountID: UUID,
        bucketName: String
    ) {
        let markers = receipts.compactMap(\.undoMarker)
        guard !markers.isEmpty, markers.count == receipts.count else {
            lastDeleteUndoOperation = nil
            return
        }
        lastDeleteUndoOperation = CloudDeleteUndoOperation(
            accountID: accountID,
            bucketName: bucketName,
            title: "撤销删除",
            markers: markers,
            sourceSelection: sourceSelection
        )
    }

    @discardableResult
    func rename(_ object: OSSObject, to raw: String) async -> Bool {
        guard !isOrganizingCloud else {
            present("请等待当前云端整理完成", error: true)
            return false
        }
        guard let client = makeClient(),
              let accountID = selectedAccountID,
              let bucketName = selectedBucketName
        else { return false }
        let name: String
        do {
            name = try ObjectNameValidator.validate(raw)
        } catch {
            present(error.localizedDescription, error: true)
            return false
        }
        let dest = PathTemplate.join(PathTemplate.parentPrefix(object.key), key: name)
        guard dest != object.key else { return true }
        isOrganizingCloud = true
        defer { isOrganizingCloud = false }
        do {
            let destinationIdentity = try await client.renameObject(
                from: object.key,
                to: dest,
                overwrite: false
            )
            noteBucketMutated()
            await refreshListing()
            browser.select(key: dest, modifiers: [])
            lastDeleteUndoOperation = nil
            lastCloudUndoOperation = CloudUndoOperation(
                accountID: accountID,
                bucketName: bucketName,
                title: "撤销重命名",
                mappings: [
                    CloudObjectMapping(sourceKey: object.key, destinationKey: dest)
                ],
                committedDestinationIdentities: [dest: destinationIdentity],
                favoriteMoves: [],
                sourceSelection: [object.key],
                destinationSelection: [dest]
            )
            present("已重命名“\(name)”", action: .undoCloudOperation)
            return true
        } catch CloudObjectOperationError.sourceCleanupFailed {
            // Copy committed but the source delete failed: the object now
            // exists under both names. Refresh so the browser shows the truth.
            await refreshListing()
            present("目标已复制完成，但未能删除原文件", error: true)
            return false
        } catch {
            present(error.localizedDescription, error: true)
            return false
        }
    }

    @discardableResult
    func renameFolder(_ folder: OSSFolder, to raw: String) async -> Bool {
        guard !isOrganizingCloud else {
            present("请等待当前云端整理完成", error: true)
            return false
        }
        guard let client = makeClient(),
              let accountID = selectedAccountID,
              let bucketName = selectedBucketName
        else { return false }
        let name: String
        do {
            name = try ObjectNameValidator.validate(raw)
        } catch {
            present(error.localizedDescription, error: true)
            return false
        }
        let destination = PathTemplate.join(
            PathTemplate.parentPrefix(folder.prefix),
            key: name
        ) + "/"
        guard destination != folder.prefix else { return true }

        isOrganizingCloud = true
        defer { isOrganizingCloud = false }
        do {
            let mappings = try await client.prefixMappings(
                from: folder.prefix,
                to: destination
            )
            let destinationIdentities = try await client.performCloudOperation(
                mappings,
                mode: .move
            )
            favorites.replacePrefix(
                accountID: accountID,
                bucketName: bucketName,
                source: folder.prefix,
                destination: destination
            )
            noteBucketMutated()
            await refreshListing()
            browser.select(key: destination, modifiers: [])
            lastDeleteUndoOperation = nil
            lastCloudUndoOperation = CloudUndoOperation(
                accountID: accountID,
                bucketName: bucketName,
                title: "撤销重命名",
                mappings: mappings,
                committedDestinationIdentities: destinationIdentities,
                favoriteMoves: [
                    CloudFavoriteMove(
                        sourcePrefix: folder.prefix,
                        destinationPrefix: destination
                    )
                ],
                sourceSelection: [folder.prefix],
                destinationSelection: [destination]
            )
            present("已重命名“\(folder.name)”", action: .undoCloudOperation)
            return true
        } catch CloudObjectOperationError.sourceCleanupFailed {
            // A folder rename is a copy-then-delete of every object in it and
            // can partially succeed; refresh so the listing shows the truth.
            await refreshListing()
            present("目标已复制完成，但未能删除部分原文件", error: true)
            return false
        } catch {
            present(error.localizedDescription, error: true)
            return false
        }
    }

    func cloudDragPayload(clickedKey: String) -> CloudDragPayload {
        let keys = menuActionKeys(clickedKey: clickedKey)
        if isBucketSearchActive {
            let visible = searchVisibleKeys
            let resolved = keys.filter(visible.contains)
            return CloudDragPayload(
                accountID: selectedAccountID ?? UUID(),
                bucketName: selectedBucketName ?? "",
                sourceRegionID: selectedBucket?.regionID ?? selectedAccount?.regionID,
                objectKeys: searchController.results.filter { resolved.contains($0.key) }.map(\.key),
                folderPrefixes: []
            )
        }
        let visible = browser.visibleKeys
        let resolved = keys.filter(visible.contains)
        return CloudDragPayload(
            accountID: selectedAccountID ?? UUID(),
            bucketName: selectedBucketName ?? "",
            sourceRegionID: selectedBucket?.regionID ?? selectedAccount?.regionID,
            objectKeys: browser.visibleObjects.filter { resolved.contains($0.key) }.map(\.key),
            folderPrefixes: browser.visibleFolders.filter { resolved.contains($0.prefix) }.map(\.prefix)
        )
    }

    func finderItemProvider(clickedKey: String) -> NSItemProvider {
        let payload = cloudDragPayload(clickedKey: clickedKey)
        guard (!payload.objectKeys.isEmpty || !payload.folderPrefixes.isEmpty),
              let client = makeClient()
        else { return NSItemProvider() }
        return FinderExportCoordinator.itemProvider(
            for: payload,
            client: client,
            speedLimit: settings.downloadSpeedLimit
        )
    }

    func presentObjectProperties(for object: OSSObject) {
        guard let client = makeClient() else { return }
        objectPropertiesModel = ObjectPropertiesModel(
            object: object,
            client: client,
            onSaved: { [weak self] in self?.didSaveObjectProperties() }
        )
        showObjectProperties = true
    }

    private func didSaveObjectProperties() {
        noteBucketMutated()
        scheduleListingRefresh()
        Task { await loadInspector() }
        present("对象属性已保存到云端")
    }

    func noteBucketMutated(accountID: UUID? = nil, bucketName: String? = nil) {
        let account = accountID ?? selectedAccountID
        let bucket = bucketName ?? selectedBucketName
        if let account, let bucket {
            searchController.invalidate(accountID: account, bucketName: bucket)
        }
        let touchesCurrent =
            (accountID == nil || accountID == selectedAccountID)
            && (bucketName == nil || bucketName == selectedBucketName)
        if touchesCurrent, isBucketSearchActive {
            Task { await runBucketSearch() }
        }
    }

    var canCopyCloudItems: Bool {
        !actionableSelectionKeys.isEmpty
    }

    var resolvedClipboardItem: CloudClipboardItem? {
        if let item = CloudClipboard.read() {
            return item
        }
        if let payload = cloudClipboard,
           NSPasteboard.general.changeCount == cloudClipboardChangeCount
        {
            return CloudClipboardItem(payload: payload, mode: cloudClipboardMode)
        }
        return nil
    }

    var resolvedCloudClipboard: CloudDragPayload? {
        resolvedClipboardItem?.payload
    }

    var canPasteCloudItems: Bool {
        resolvedClipboardItem != nil
    }

    var canPaste: Bool {
        canPasteCloudItems || hasFileURLsOnPasteboard
    }

    var pasteMenuTitle: String {
        clipboardMode == .move ? "移动到此处" : "粘贴"
    }

    var pasteIntoFolderTitle: String {
        clipboardMode == .move ? "移动到此文件夹" : "粘贴到此文件夹"
    }

    private var clipboardMode: CloudOperationMode {
        resolvedClipboardItem?.mode ?? cloudClipboardMode
    }

    func copyCloudSelection(clickedKey: String? = nil) {
        rememberSelectionOnClipboard(clickedKey: clickedKey, mode: .copy)
    }

    func cutCloudSelection(clickedKey: String? = nil) {
        rememberSelectionOnClipboard(clickedKey: clickedKey, mode: .move)
    }

    func paste(into destinationPrefix: String? = nil) {
        let destination = destinationPrefix ?? browser.prefix
        if let item = resolvedClipboardItem {
            if item.mode == .move,
               CloudObjectOperation.staysInPlace(
                objectKeys: item.payload.objectKeys,
                folderPrefixes: item.payload.folderPrefixes,
                destinationPrefix: destination
               )
            {
                present("项目已经在这个位置")
                return
            }
            let destinationAccountID = selectedAccountID
            let destinationBucketName = selectedBucketName
            Task {
                guard selectedAccountID == destinationAccountID,
                      selectedBucketName == destinationBucketName
                else {
                    present("目标账号或 Bucket 已改变，本次操作已取消", error: true)
                    return
                }
                let succeeded = await organizeCloud(item.payload, to: destination, mode: item.mode)
                if succeeded, item.mode == .move {
                    clearCloudClipboard()
                }
            }
            return
        }
        pasteFromClipboard(to: destination)
    }

    func pasteCloudItems(into destinationPrefix: String? = nil) {
        paste(into: destinationPrefix)
    }

    private func rememberSelectionOnClipboard(clickedKey: String?, mode: CloudOperationMode) {
        let key = clickedKey
            ?? actionableSelectionKeys.sorted().first
            ?? ""
        let payload = cloudDragPayload(clickedKey: key)
        guard !payload.isEmpty else { return }
        rememberCloudClipboard(payload, mode: mode)
        if mode == .move {
            present("已剪切 \(payload.itemCount) 项")
        } else {
            present("已复制 \(payload.itemCount) 项")
        }
    }

    private func rememberCloudClipboard(_ payload: CloudDragPayload, mode: CloudOperationMode) {
        cloudClipboard = payload
        cloudClipboardMode = mode
        CloudClipboard.write(payload, mode: mode)
        cloudClipboardChangeCount = NSPasteboard.general.changeCount
    }

    private func clearCloudClipboard() {
        cloudClipboard = nil
        cloudClipboardMode = .copy
        cloudClipboardChangeCount = -1
        CloudClipboard.clear()
    }

    func moveCloudItems(_ payload: CloudDragPayload, to destinationPrefix: String) {
        let destinationAccountID = selectedAccountID
        let destinationBucketName = selectedBucketName
        Task {
            guard selectedAccountID == destinationAccountID,
                  selectedBucketName == destinationBucketName
            else {
                present("目标账号或 Bucket 已改变，本次操作已取消", error: true)
                return
            }
            await organizeCloud(payload, to: destinationPrefix, mode: .move)
        }
    }

    @discardableResult
    func organizeCloud(
        _ payload: CloudDragPayload,
        to destinationPrefix: String,
        mode: CloudOperationMode,
        conflictPolicy overridePolicy: TransferConflictPolicy? = nil
    ) async -> Bool {
        guard !isOrganizingCloud else {
            present("请等待当前云端整理完成", error: true)
            return false
        }
        let conflictPolicy = overridePolicy ?? settings.transferConflictPolicy
        guard payload.accountID == selectedAccountID,
              payload.bucketName == selectedBucketName
        else {
            await prepareCrossBucketOperation(
                payload,
                to: destinationPrefix,
                mode: mode,
                conflictPolicy: conflictPolicy
            )
            return false
        }
        guard let client = makeClient(),
              let accountID = selectedAccountID,
              let bucketName = selectedBucketName
        else { return false }

        isOrganizingCloud = true
        defer { isOrganizingCloud = false }
        do {
            var mappings: [CloudObjectMapping] = []
            var movedPrefixes: [(source: String, destination: String)] = []
            var topLevelDestinations = Set<String>()

            for sourceKey in payload.objectKeys {
                var destination = PathTemplate.join(
                    destinationPrefix,
                    key: PathTemplate.lastComponent(sourceKey)
                )
                if destination == sourceKey {
                    guard mode == .copy else { continue }
                    destination = try await availableCloudKey(
                        destination,
                        reserved: topLevelDestinations.union([sourceKey]),
                        client: client
                    )
                }
                topLevelDestinations.insert(destination)
                mappings.append(CloudObjectMapping(sourceKey: sourceKey, destinationKey: destination))
            }
            for sourcePrefix in payload.folderPrefixes {
                var destination = PathTemplate.join(
                    destinationPrefix,
                    key: PathTemplate.lastComponent(sourcePrefix)
                ) + "/"
                if destination == sourcePrefix {
                    guard mode == .copy else { continue }
                    destination = try await availableCloudKey(
                        destination,
                        reserved: topLevelDestinations.union([sourcePrefix]),
                        client: client
                    )
                }
                topLevelDestinations.insert(destination)
                mappings.append(contentsOf: try await client.prefixMappings(
                    from: sourcePrefix,
                    to: destination
                ))
                movedPrefixes.append((sourcePrefix, destination))
            }
            guard !mappings.isEmpty else {
                present("项目已经在这个位置")
                return false
            }

            let existing = try await existingKeys(
                among: mappings.map(\.destinationKey),
                client: client
            )
            let conflictVersioningStatus: OSSBucketVersioningStatus?
            if !existing.isEmpty,
               conflictPolicy == .ask || conflictPolicy == .replace {
                do {
                    conflictVersioningStatus = try await client.bucketVersioningStatus()
                } catch {
                    conflictVersioningStatus = nil
                }
            } else {
                conflictVersioningStatus = nil
            }
            if !existing.isEmpty,
               conflictPolicy == .ask
                || (conflictPolicy == .replace && conflictVersioningStatus != .enabled) {
                cloudConflictPrompt = CloudConflictPrompt(
                    payload: payload,
                    destinationPrefix: destinationPrefix,
                    mode: mode,
                    conflictKeys: existing.sorted(),
                    isCrossBucket: false,
                    destinationAccountID: accountID,
                    destinationBucketName: bucketName,
                    versioningStatus: conflictVersioningStatus
                )
                return false
            }

            var resolvedMappings: [CloudObjectMapping] = []
            var reserved = Set(mappings.map(\.destinationKey)).union(existing)
            var changedMapping = false
            for var mapping in mappings {
                guard existing.contains(mapping.destinationKey) else {
                    resolvedMappings.append(mapping)
                    continue
                }
                switch conflictPolicy {
                case .skip:
                    changedMapping = true
                case .replace:
                    resolvedMappings.append(mapping)
                case .keepBoth:
                    mapping.destinationKey = try await availableCloudKey(
                        mapping.destinationKey,
                        reserved: reserved,
                        client: client
                    )
                    reserved.insert(mapping.destinationKey)
                    changedMapping = true
                    resolvedMappings.append(mapping)
                case .ask:
                    // Conflicts were returned above. This branch only keeps the
                    // switch exhaustive if the prompt state changes later.
                    break
                }
            }
            guard !resolvedMappings.isEmpty else {
                present("所有同名项目都已跳过")
                return false
            }
            let selection = Set(resolvedMappings.map(\.destinationKey))
            let operationResult = try await performCloudOperationSafely(
                resolvedMappings,
                mode: mode,
                existingDestinations: conflictPolicy == .replace ? existing : [],
                client: client
            )
            noteBucketMutated()
            if mode == .move, !changedMapping {
                for pair in movedPrefixes {
                    favorites.replacePrefix(
                        accountID: accountID,
                        bucketName: bucketName,
                        source: pair.source,
                        destination: pair.destination
                    )
                }
            }
            browser.clearSelection()
            await refreshListing()
            browser.replaceSelection(selection)
            let count = payload.objectKeys.count + payload.folderPrefixes.count
            if mode == .move {
                lastDeleteUndoOperation = nil
                lastCloudUndoOperation = CloudUndoOperation(
                    accountID: accountID,
                    bucketName: bucketName,
                    title: "撤销移动",
                    mappings: resolvedMappings,
                    committedDestinationIdentities: operationResult.committedDestinationIdentities,
                    favoriteMoves: (changedMapping ? [] : movedPrefixes).map {
                        CloudFavoriteMove(
                            sourcePrefix: $0.source,
                            destinationPrefix: $0.destination
                        )
                    },
                    sourceSelection: Set(payload.objectKeys + payload.folderPrefixes),
                    destinationSelection: selection
                )
            }
            present(
                operationResult.cleanupFailures.isEmpty
                    ? (mode == .move ? "已移动 \(count) 项" : "已复制 \(count) 项")
                    : "操作已完成，但有 \(operationResult.cleanupFailures.count) 个临时安全备份未能清理",
                error: !operationResult.cleanupFailures.isEmpty,
                action: mode == .move && operationResult.cleanupFailures.isEmpty ? .undoCloudOperation : nil
            )
            return true
        } catch CloudObjectOperationError.sourceCleanupFailed {
            // A move copies first and deletes second, so it can partially
            // succeed. Refresh so the browser shows what actually happened.
            await refreshListing()
            present("目标已复制完成，但未能删除部分原文件", error: true)
            return false
        } catch {
            present(error.localizedDescription, error: true)
            return false
        }
    }

    func resolveCloudConflicts(_ policy: TransferConflictPolicy) {
        guard policy != .ask, let prompt = cloudConflictPrompt else { return }
        guard policy != .replace || prompt.canReplaceSafely else {
            present("安全覆盖要求目标 Bucket 已开启版本控制", error: true)
            return
        }
        cloudConflictPrompt = nil
        guard selectedAccountID == prompt.destinationAccountID,
              selectedBucketName == prompt.destinationBucketName
        else {
            present("目标账号或 Bucket 已改变，本次操作已取消", error: true)
            return
        }
        Task {
            let succeeded = await organizeCloud(
                prompt.payload,
                to: prompt.destinationPrefix,
                mode: prompt.mode,
                conflictPolicy: policy
            )
            if succeeded, prompt.mode == .move {
                clearCloudClipboard()
            }
        }
    }

    func cancelCloudConflicts() {
        cloudConflictPrompt = nil
    }

    private func availableCloudKey(
        _ key: String,
        reserved: Set<String>,
        client: OSSClient
    ) async throws -> String {
        var occupied = reserved
        var candidate = TransferConflictPlanner.availableKey(for: key, existing: occupied)
        while try await client.objectExists(key: candidate) {
            occupied.insert(candidate)
            candidate = TransferConflictPlanner.availableKey(for: key, existing: occupied)
        }
        return candidate
    }

    /// Creates recoverable copies before replacing existing objects. OSS has no
    /// multi-object transaction on unversioned buckets, so this is the only way
    /// to restore the original destination if a later item fails.
    private func performCloudOperationSafely(
        _ mappings: [CloudObjectMapping],
        mode: CloudOperationMode,
        existingDestinations: Set<String>,
        client: OSSClient
    ) async throws -> (
        cleanupFailures: [String],
        committedDestinationIdentities: [String: OSSObjectIdentity]
    ) {
        let backupKeys = existingDestinations.intersection(mappings.map(\.destinationKey))
        let backups = try await createDestinationBackups(keys: backupKeys, client: client)
        let expectedDestinations = Dictionary(uniqueKeysWithValues: backups.map {
            ($0.originalKey, $0.originalIdentity)
        })
        do {
            let committedDestinationIdentities = try await client.performCloudOperation(
                mappings,
                mode: mode,
                overwrite: false,
                overwriteDestinations: backupKeys,
                expectedDestinations: expectedDestinations
            )
            return (
                await cleanupDestinationBackups(backups, client: client),
                committedDestinationIdentities
            )
        } catch let operationError {
            guard let cloudError = operationError as? CloudObjectOperationError else {
                // Validation and destination preflight errors occur before the
                // copy loop. Nothing was written, so restoring every backup
                // would itself overwrite concurrent user changes.
                let cleanupFailures = await cleanupDestinationBackups(backups, client: client)
                if cleanupFailures.isEmpty { throw operationError }
                throw CloudRollbackError.manualInspectionRequired(
                    operation: operationError.localizedDescription,
                    keys: cleanupFailures
                )
            }
            let byDestination = backups.reduce(into: [String: CloudDestinationBackup]()) {
                $0[$1.originalKey] = $1
            }
            var failures: [String] = []
            var preserved: [String] = []
            switch cloudError {
            case .copyPhaseFailed(
                _,
                let modifiedExisting,
                let residualDestinations,
                let uncertainDestinations
            ):
                // Never restore a backup by copying it over the current key.
                // OSS has no destination If-Match, so that could overwrite a
                // newer concurrent value. The low-level operation already
                // removes only exact version IDs created by this operation;
                // anything left over is preserved for manual inspection.
                let manualDestinations = modifiedExisting
                    .union(residualDestinations)
                    .union(uncertainDestinations)
                let manualBackups = manualDestinations.compactMap { byDestination[$0] }
                let manualBackupKeys = Set(manualBackups.map(\.backupKey))
                failures.append(contentsOf: await cleanupDestinationBackups(
                    backups.filter { !manualBackupKeys.contains($0.backupKey) },
                    client: client
                ))
                preserved.append(contentsOf: manualDestinations)
                preserved.append(contentsOf: manualBackups.map(\.backupKey))

            case .sourceCleanupFailed(
                _,
                let removedSources,
                let uncertainSources,
                let residualDestinations
            ):
                let destinationBySource = mappings.reduce(into: [String: String]()) {
                    $0[$1.sourceKey] = $1.destinationKey
                }
                let committedDestinations = Set(removedSources.compactMap { destinationBySource[$0] })
                let uncertainDestinations = Set(uncertainSources.compactMap { destinationBySource[$0] })
                let manualDestinations = residualDestinations.union(uncertainDestinations)
                let manualBackups = manualDestinations.compactMap { byDestination[$0] }
                let manualBackupKeys = Set(manualBackups.map(\.backupKey))
                // Destinations whose exact source version was removed are the
                // committed part of the move. All other destinations remain in
                // place; copying a backup over them would introduce another
                // unguarded write after source cleanup has begun.
                let safeToClean = backups.filter {
                    committedDestinations.contains($0.originalKey)
                        || !manualBackupKeys.contains($0.backupKey)
                }
                failures.append(contentsOf: await cleanupDestinationBackups(
                    safeToClean,
                    client: client
                ))
                preserved.append(contentsOf: manualDestinations)
                preserved.append(contentsOf: manualBackups.map(\.backupKey))

            default:
                // destinationExists and other pre-copy failures have not
                // modified a destination. Only discard the unused backups.
                failures.append(contentsOf: await cleanupDestinationBackups(backups, client: client))
            }
            let inspectionKeys = Array(Set(failures + preserved)).sorted()
            if inspectionKeys.isEmpty { throw operationError }
            throw CloudRollbackError.manualInspectionRequired(
                operation: operationError.localizedDescription,
                keys: inspectionKeys
            )
        }
    }

    private func createDestinationBackups(
        keys: Set<String>,
        client: OSSClient
    ) async throws -> [CloudDestinationBackup] {
        guard !keys.isEmpty else { return [] }
        let root = ".ossuno-rollback/\(UUID().uuidString)/"
        var backups: [CloudDestinationBackup] = []
        do {
            for originalKey in keys.sorted() {
                let snapshot = try await client.objectSnapshot(key: originalKey)
                let head = snapshot.head
                let acl = snapshot.acl
                guard let originalIdentity = head.identity else {
                    throw OSSServiceError(
                        statusCode: 0,
                        code: "MissingDestinationIdentity",
                        message: "OSS 未返回目标对象的完整标识，无法安全覆盖：\(originalKey)",
                        requestId: ""
                    )
                }
                let backupKey = root + UUID().uuidString
                let versionID: String?
                do {
                    versionID = try await client.copyObject(
                        from: originalKey,
                        to: backupKey,
                        // The UUID key is owned by this operation. Treat it as an
                        // explicit write so rollback also works in version-enabled
                        // buckets where OSS ignores create-only headers.
                        overwrite: true,
                        // Rollback objects must never inherit a public source ACL.
                        // The original ACL is stored separately and restored only
                        // when copying the backup back to its user-visible key.
                        acl: .private,
                        sourceETag: head.etag,
                        sourceVersionID: head.versionID,
                        storageClass: head.storageClass,
                        serverSideEncryption: head.serverSideEncryption,
                        serverSideEncryptionKeyID: head.serverSideEncryptionKeyID,
                        serverSideDataEncryption: head.serverSideDataEncryption,
                        requireCommittedVersionID: true
                    )
                } catch let error {
                    if let cloudError = error as? CloudObjectOperationError,
                       case .copyOutcomeUncertain = cloudError {
                        // The server may have committed the private backup even
                        // though it omitted/lost the exact version response. Keep
                        // its random key in the manual residual set and never issue
                        // an unscoped DELETE in this versioned bucket.
                        backups.append(
                            CloudDestinationBackup(
                                originalKey: originalKey,
                                backupKey: backupKey,
                                backupVersionID: nil,
                                acl: acl,
                                originalIdentity: originalIdentity
                            )
                        )
                    }
                    throw error
                }
                let backup = CloudDestinationBackup(
                    originalKey: originalKey,
                    backupKey: backupKey,
                    backupVersionID: versionID,
                    acl: acl,
                    originalIdentity: originalIdentity
                )
                // Record the key before any further request can fail. In an
                // Enabled bucket cleanup is safe only with the exact version
                // returned for this write; an unscoped DELETE would merely add
                // a marker and leave the private backup version behind.
                backups.append(backup)
                if Self.exactVersionID(versionID) == nil {
                    let status = try await client.bucketVersioningStatus()
                    guard status == .disabled else {
                        throw CloudObjectOperationError.copyOutcomeUncertain(
                            destination: backupKey
                        )
                    }
                }
            }
            return backups
        } catch let operationError {
            let cleanupFailures = await cleanupDestinationBackups(backups, client: client)
            if cleanupFailures.isEmpty { throw operationError }
            throw CloudRollbackError.rollbackFailed(
                operation: operationError.localizedDescription,
                failures: cleanupFailures
            )
        }
    }

    private func cleanupDestinationBackups(
        _ backups: [CloudDestinationBackup],
        client: OSSClient
    ) async -> [String] {
        var failures: [String] = []
        for backup in backups.reversed() {
            do {
                if Self.exactVersionID(backup.backupVersionID) == nil {
                    guard try await client.bucketVersioningStatus() == .disabled else {
                        failures.append(backup.backupKey)
                        continue
                    }
                }
                _ = try await client.deleteObject(
                    key: backup.backupKey,
                    versionID: backup.backupVersionID
                )
            } catch {
                failures.append(backup.backupKey)
            }
        }
        return failures
    }

    private func prepareCrossBucketOperation(
        _ payload: CloudDragPayload,
        to destinationPrefix: String,
        mode: CloudOperationMode,
        conflictPolicy: TransferConflictPolicy
    ) async {
        guard let sourceAccount = accounts.first(where: { $0.id == payload.accountID }),
              let destinationAccount = selectedAccount,
              let destinationBucket = selectedBucket,
              let destinationClient = makeClient()
        else {
            present("来源账号已不可用，无法继续", error: true)
            return
        }
        let sourceRegion = payload.sourceRegionID ?? sourceAccount.regionID
        // The drag payload already carries the source region. Re-listing the
        // destination account's buckets here both hides errors and can resolve
        // a same-named bucket in the wrong account.
        let resolvedSourceBucket = (sourceAccount.id == selectedAccountID
            ? buckets.first(where: { $0.name == payload.bucketName })
            : nil) ?? OSSBucket(
            name: payload.bucketName,
            regionID: sourceRegion,
            location: sourceRegion,
            extranetEndpoint: "",
            createdAt: nil
        )
        let sourceClient: OSSClient
        do {
            sourceClient = try clientProvider(sourceAccount, resolvedSourceBucket)
        } catch {
            present(error.localizedDescription, error: true)
            return
        }

        isOrganizingCloud = true
        defer { isOrganizingCloud = false }
        do {
            var folders: [String: [OSSObject]] = [:]
            for prefix in payload.folderPrefixes {
                let listing = try await sourceClient.listAllObjects(prefix: prefix)
                guard !listing.truncated else { throw CloudObjectOperationError.incompleteListing }
                folders[prefix] = listing.objects
            }
            var plan = try CrossBucketOperation.plan(
                sourceAccountID: sourceAccount.id,
                destinationAccountID: destinationAccount.id,
                sourceRegion: resolvedSourceBucket.regionID,
                destinationRegion: destinationBucket.regionID,
                destinationPrefix: destinationPrefix,
                objectKeys: payload.objectKeys,
                folders: folders
            )
            for index in plan.mappings.indices where plan.mappings[index].expectedSize == 0 {
                plan.mappings[index].expectedSize = try await sourceClient.head(
                    key: plan.mappings[index].sourceKey
                ).contentLength ?? 0
            }
            plan.method = CrossBucketOperation.executionMethod(
                preferred: plan.method,
                mappings: plan.mappings
            )
            let existingDestinations = try await existingKeys(
                among: plan.mappings.map(\.destinationKey),
                client: destinationClient
            )
            let conflictVersioningStatus: OSSBucketVersioningStatus?
            if !existingDestinations.isEmpty,
               conflictPolicy == .ask || conflictPolicy == .replace {
                do {
                    conflictVersioningStatus = try await destinationClient.bucketVersioningStatus()
                } catch {
                    conflictVersioningStatus = nil
                }
            } else {
                conflictVersioningStatus = nil
            }
            if !existingDestinations.isEmpty,
               conflictPolicy == .ask
                || (conflictPolicy == .replace && conflictVersioningStatus != .enabled) {
                cloudConflictPrompt = CloudConflictPrompt(
                    payload: payload,
                    destinationPrefix: destinationPrefix,
                    mode: mode,
                    conflictKeys: existingDestinations.sorted(),
                    isCrossBucket: true,
                    destinationAccountID: destinationAccount.id,
                    destinationBucketName: destinationBucket.name,
                    versioningStatus: conflictVersioningStatus
                )
                return
            }
            var renamed = 0
            var filtered: [CrossBucketMapping] = []
            var reserved = Set(plan.mappings.map { $0.destinationKey }).union(existingDestinations)
            for var mapping in plan.mappings {
                guard existingDestinations.contains(mapping.destinationKey) else {
                    filtered.append(mapping)
                    continue
                }
                switch conflictPolicy {
                case .skip:
                    continue
                case .replace:
                    filtered.append(mapping)
                case .keepBoth:
                    mapping.destinationKey = try await availableCloudKey(
                        mapping.destinationKey,
                        reserved: reserved,
                        client: destinationClient
                    )
                    reserved.insert(mapping.destinationKey)
                    renamed += 1
                    filtered.append(mapping)
                case .ask:
                    break
                }
            }
            let hadMappings = !plan.mappings.isEmpty
            plan.mappings = filtered
            plan.knownBytes = filtered.reduce(0) { partial, mapping in
                let (sum, overflow) = partial.addingReportingOverflow(max(0, mapping.expectedSize))
                return overflow ? Int64.max : sum
            }
            guard !filtered.isEmpty else {
                present(CrossBucketOperation.emptyResultMessage(hadMappings: hadMappings))
                return
            }
            crossBucketPreflight = CrossBucketPreflight(
                plan: plan,
                mode: mode,
                sourceAccount: sourceAccount,
                sourceBucket: resolvedSourceBucket,
                destinationAccount: destinationAccount,
                destinationBucket: destinationBucket,
                sourceClient: sourceClient,
                destinationClient: destinationClient,
                overwrite: conflictPolicy == .replace,
                renamedConflicts: renamed,
                existingDestinations: conflictPolicy == .replace ? existingDestinations : []
            )
            showCrossBucketPreflight = true
        } catch {
            present(error.localizedDescription, error: true)
        }
    }

    func confirmCrossBucketOperation() {
        guard let preflight = crossBucketPreflight else { return }
        crossBucketPreflight = nil
        Task { await executeCrossBucketOperation(preflight) }
    }

    private func executeCrossBucketOperation(_ preflight: CrossBucketPreflight) async {
        guard !isOrganizingCloud else { return }
        isOrganizingCloud = true
        defer { isOrganizingCloud = false }
        var copied: [CrossBucketMapping] = []
        var destinationVersions: [String: String] = [:]
        var removedSources: Set<String> = []
        var sourceSnapshots: [String: OSSObjectSnapshot] = [:]
        var sourceCleanupStarted = false
        var backups: [CloudDestinationBackup] = []
        var stagingObjects: [CloudTemporaryObject] = []
        var cleanupFailures: [String] = []
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "Ossuno-CrossBucket-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        do {
            if preflight.mode == .move {
                let sourceStatus = try await preflight.sourceClient.bucketVersioningStatus()
                guard sourceStatus.supportsSafeMove else {
                    throw OSSVersioningSafetyError(operation: .move, status: sourceStatus)
                }
                let destinationStatus = try await preflight.destinationClient.bucketVersioningStatus()
                guard destinationStatus.supportsSafeMove else {
                    throw OSSVersioningSafetyError(operation: .move, status: destinationStatus)
                }
            }
            backups = try await createDestinationBackups(
                keys: preflight.existingDestinations.intersection(
                    Set(preflight.plan.mappings.map(\.destinationKey))
                ),
                client: preflight.destinationClient
            )
            if preflight.plan.method == .relay {
                try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
            }
            for mapping in preflight.plan.mappings {
                try Task.checkCancellation()
                let sourceSnapshot = try await preflight.sourceClient.objectSnapshot(
                    key: mapping.sourceKey
                )
                sourceSnapshots[mapping.sourceKey] = sourceSnapshot
                let sourceHead = sourceSnapshot.head
                let sourceACL = sourceSnapshot.acl
                let shouldOverwrite = preflight.existingDestinations.contains(mapping.destinationKey)
                let expectedDestination = backups.first {
                    $0.originalKey == mapping.destinationKey
                }?.originalIdentity
                guard !shouldOverwrite || expectedDestination != nil else {
                    throw OSSServiceError(
                        statusCode: 0,
                        code: "MissingDestinationIdentity",
                        message: "没有可验证的目标安全副本，已取消覆盖：\(mapping.destinationKey)",
                        requestId: ""
                    )
                }
                if preflight.plan.method == .serverSide {
                    let versionID = try await preflight.destinationClient.copyObject(
                        fromBucket: preflight.sourceBucket.name,
                        sourceKey: mapping.sourceKey,
                        to: mapping.destinationKey,
                        overwrite: shouldOverwrite,
                        acl: sourceACL,
                        sourceETag: sourceHead.etag,
                        sourceVersionID: sourceHead.versionID,
                        storageClass: sourceHead.storageClass,
                        serverSideEncryption: sourceHead.serverSideEncryption,
                        serverSideEncryptionKeyID: sourceHead.serverSideEncryptionKeyID,
                        serverSideDataEncryption: sourceHead.serverSideDataEncryption,
                        allowVersionedCreate: !shouldOverwrite,
                        requireCommittedVersionID: shouldOverwrite || preflight.mode == .move,
                        expectedDestination: expectedDestination,
                        preflightDestination: false
                    )
                    if preflight.mode == .move {
                        guard let versionID,
                              !versionID.isEmpty,
                              versionID.caseInsensitiveCompare("null") != .orderedSame
                        else {
                            throw CloudObjectOperationError.copyOutcomeUncertain(
                                destination: mapping.destinationKey
                            )
                        }
                    }
                    copied.append(mapping)
                    if let versionID, !versionID.isEmpty {
                        destinationVersions[mapping.destinationKey] = versionID
                    }
                } else {
                    let local = temporaryRoot.appending(path: UUID().uuidString)
                    let tags = sourceSnapshot.tags
                    _ = try await preflight.sourceClient.downloadResumable(
                        key: mapping.sourceKey,
                        to: local,
                        within: temporaryRoot,
                        expectedSize: sourceHead.contentLength ?? mapping.expectedSize,
                        expectedETag: sourceHead.etag,
                        expectedVersionID: sourceHead.versionID,
                        speedLimit: settings.downloadSpeedLimit
                    )
                    let stagingKey = ".ossuno-staging/\(UUID().uuidString)"
                    // Register the random key before starting the mutating
                    // request. A lost response may mean OSS committed it; the
                    // cleanup path will preserve a nil-version record instead
                    // of issuing an unsafe key-scoped DELETE.
                    let stagingIndex = stagingObjects.endIndex
                    stagingObjects.append(
                        CloudTemporaryObject(key: stagingKey, versionID: nil)
                    )
                    let receipt = try await preflight.destinationClient.putObjectWithReceipt(
                        key: stagingKey,
                        fileURL: local,
                        contentType: sourceHead.contentType ?? "application/octet-stream",
                        // Staging keys are implementation details. Keeping them
                        // private prevents a public-read-write source ACL from
                        // exposing a mutable relay object before final commit.
                        acl: .private,
                        properties: OSSObjectProperties(
                            contentType: sourceHead.contentType ?? "application/octet-stream",
                            cacheControl: sourceHead.cacheControl ?? "",
                            contentDisposition: sourceHead.contentDisposition ?? "",
                            contentLanguage: sourceHead.contentLanguage ?? "",
                            expires: sourceHead.expires ?? "",
                            userMetadata: sourceHead.userMetadata
                        ),
                        contentEncoding: sourceHead.contentEncoding,
                        storageClass: sourceHead.storageClass,
                        serverSideEncryption: sourceHead.serverSideEncryption,
                        serverSideEncryptionKeyID: sourceHead.serverSideEncryptionKeyID,
                        serverSideDataEncryption: sourceHead.serverSideDataEncryption,
                        // The staging key is an unguessable, app-owned UUID. It
                        // is still a create-only write: Disabled buckets enforce
                        // forbid-overwrite, while Enabled buckets must return an
                        // exact version ID before the relay may continue.
                        allowVersionedCreate: true,
                        overwrite: false,
                        speedLimit: settings.uploadSpeedLimit
                    )
                    stagingObjects[stagingIndex].versionID = receipt.versionID
                    if Self.exactVersionID(receipt.versionID) == nil {
                        let status = try await preflight.destinationClient.bucketVersioningStatus()
                        guard status == .disabled else {
                            throw CloudObjectOperationError.copyOutcomeUncertain(
                                destination: stagingKey
                            )
                        }
                    }
                    if !tags.isEmpty {
                        try await preflight.destinationClient.putObjectTags(
                            key: stagingKey,
                            tags: tags,
                            versionID: receipt.versionID
                        )
                    }
                    let stagingHead = try await preflight.destinationClient.head(
                        key: stagingKey,
                        versionID: receipt.versionID
                    )
                    let versionID = try await preflight.destinationClient.copyObject(
                        from: stagingKey,
                        to: mapping.destinationKey,
                        overwrite: shouldOverwrite,
                        acl: sourceACL,
                        sourceETag: stagingHead.etag,
                        sourceVersionID: stagingHead.versionID,
                        storageClass: sourceHead.storageClass,
                        serverSideEncryption: sourceHead.serverSideEncryption,
                        serverSideEncryptionKeyID: sourceHead.serverSideEncryptionKeyID,
                        serverSideDataEncryption: sourceHead.serverSideDataEncryption,
                        allowVersionedCreate: !shouldOverwrite,
                        requireCommittedVersionID: shouldOverwrite || preflight.mode == .move,
                        expectedDestination: expectedDestination,
                        preflightDestination: false
                    )
                    if preflight.mode == .move {
                        guard let versionID,
                              !versionID.isEmpty,
                              versionID.caseInsensitiveCompare("null") != .orderedSame
                        else {
                            throw CloudObjectOperationError.copyOutcomeUncertain(
                                destination: mapping.destinationKey
                            )
                        }
                    }
                    // Record the committed destination before any cleanup which
                    // can still fail, so rollback always includes this object.
                    copied.append(mapping)
                    if let versionID, !versionID.isEmpty {
                        destinationVersions[mapping.destinationKey] = versionID
                    }
                    if let stageIndex = stagingObjects.firstIndex(where: { $0.key == stagingKey }) {
                        let stage = stagingObjects[stageIndex]
                        do {
                            _ = try await preflight.destinationClient.deleteObject(
                                key: stage.key,
                                versionID: stage.versionID
                            )
                            stagingObjects.remove(at: stageIndex)
                        } catch {
                            // Keep it in stagingObjects and retry during the
                            // operation-wide cleanup below.
                        }
                    }
                    do {
                        try FileManager.default.removeItem(at: local)
                    } catch {
                        // The temporary root cleanup retries this recursively.
                    }
                }
            }
            if preflight.mode == .move {
                sourceCleanupStarted = true
                for mapping in preflight.plan.mappings {
                    guard let snapshot = sourceSnapshots[mapping.sourceKey] else {
                        throw OSSServiceError(
                            statusCode: 0,
                            code: "MissingSourceIdentity",
                            message: "无法确认源对象版本，已保留来源和目标：\(mapping.sourceKey)",
                            requestId: ""
                        )
                    }
                    guard let versionID = Self.exactVersionID(snapshot.head.versionID) else {
                        throw OSSServiceError(
                            statusCode: 0,
                            code: "MissingSourceVersion",
                            message: "源对象没有可精确删除的 versionId，已保留来源和目标：\(mapping.sourceKey)",
                            requestId: ""
                        )
                    }
                    guard try await preflight.sourceClient.objectMatchesSnapshot(
                        key: mapping.sourceKey,
                        expected: snapshot,
                        versionID: versionID
                    ) else {
                        throw OSSServiceError(
                            statusCode: 0,
                            code: "SourceObjectChanged",
                            message: "源对象属性或标签在复制后发生变化，已保留来源和目标：\(mapping.sourceKey)",
                            requestId: ""
                        )
                    }
                    // Delete the exact version that was copied. A newer
                    // concurrent source version, if any, remains untouched.
                    _ = try await preflight.sourceClient.deleteObject(
                        key: mapping.sourceKey,
                        versionID: versionID
                    )
                    removedSources.insert(mapping.sourceKey)
                }
            }
            cleanupFailures.append(contentsOf: await cleanupDestinationBackups(
                backups,
                client: preflight.destinationClient
            ))
            cleanupFailures.append(contentsOf: await cleanupTemporaryObjects(
                stagingObjects,
                client: preflight.destinationClient
            ))
            do {
                if FileManager.default.fileExists(atPath: temporaryRoot.path) {
                    try FileManager.default.removeItem(at: temporaryRoot)
                }
            } catch {
                cleanupFailures.append(temporaryRoot.path)
            }
            noteBucketMutated(
                accountID: preflight.sourceAccount.id,
                bucketName: preflight.sourceBucket.name
            )
            noteBucketMutated(
                accountID: preflight.destinationAccount.id,
                bucketName: preflight.destinationBucket.name
            )
            await refreshListing()
            if preflight.mode == .move {
                clearCloudClipboard()
            }
            if cleanupFailures.isEmpty {
                present(preflight.mode == .move ? "已移动 \(copied.count) 个对象" : "已复制 \(copied.count) 个对象")
            } else {
                present("跨 Bucket 操作已完成，但有 \(cleanupFailures.count) 个临时文件未能清理", error: true)
            }
        } catch let operationError {
            if sourceCleanupStarted {
                // Once any source DELETE has begun, a missing response may mean
                // it already committed. Never restore or delete a destination:
                // that could remove the only remaining live copy. Keep private
                // backups as well so a human can resolve every uncertain key.
                cleanupFailures.append(contentsOf: backups.map(\.backupKey))
                cleanupFailures.append(contentsOf: await cleanupTemporaryObjects(
                    stagingObjects,
                    client: preflight.destinationClient
                ))
                do {
                    if FileManager.default.fileExists(atPath: temporaryRoot.path) {
                        try FileManager.default.removeItem(at: temporaryRoot)
                    }
                } catch {
                    cleanupFailures.append(temporaryRoot.path)
                }
                noteBucketMutated(
                    accountID: preflight.sourceAccount.id,
                    bucketName: preflight.sourceBucket.name
                )
                noteBucketMutated(
                    accountID: preflight.destinationAccount.id,
                    bucketName: preflight.destinationBucket.name
                )
                // The operation may have committed destinations and removed a
                // subset of sources. Refresh the currently visible scope before
                // reporting the manual-recovery state so the browser never keeps
                // presenting the pre-operation listing as authoritative.
                await refreshListing()
                let manualKeys = Array(Set(cleanupFailures + copied.map(\.destinationKey))).sorted()
                present(
                    "跨 Bucket 移动的源清理未完成：\(operationError.localizedDescription)\n"
                        + "为避免数据丢失，来源、目标和安全副本均已保留，请手动检查："
                        + manualKeys.prefix(8).joined(separator: "、"),
                    error: true
                )
                return
            }
            let uncertainDestinations: Set<String>
            if let cloudError = operationError as? CloudObjectOperationError,
               case .copyOutcomeUncertain(let destination) = cloudError {
                uncertainDestinations = [destination]
            } else {
                uncertainDestinations = []
            }
            let rollbackMappings = CrossBucketOperation.rollbackDestinations(
                copied: copied,
                removedSources: removedSources
            )
            let rollbackKeys = Set(rollbackMappings.map(\.destinationKey))
            var safelyRolledBack = Set<String>()
            var manualDestinations = uncertainDestinations
            for mapping in rollbackMappings {
                guard !uncertainDestinations.contains(mapping.destinationKey),
                      let versionID = destinationVersions[mapping.destinationKey],
                      !versionID.isEmpty
                else {
                    manualDestinations.insert(mapping.destinationKey)
                    continue
                }
                do {
                    // This exact-version delete is safe for both newly created
                    // and replaced keys. A later concurrent version remains the
                    // current value; no backup is copied over it.
                    _ = try await preflight.destinationClient.deleteObject(
                        key: mapping.destinationKey,
                        versionID: versionID
                    )
                    safelyRolledBack.insert(mapping.destinationKey)
                } catch {
                    manualDestinations.insert(mapping.destinationKey)
                }
            }
            let backupsToPreserve = backups.filter {
                manualDestinations.contains($0.originalKey)
            }
            let retainedBackupKeys = Set(backupsToPreserve.map(\.backupKey))
            cleanupFailures.append(contentsOf: manualDestinations)
            cleanupFailures.append(contentsOf: backupsToPreserve.map(\.backupKey))
            cleanupFailures.append(contentsOf: await cleanupDestinationBackups(
                backups.filter {
                    !retainedBackupKeys.contains($0.backupKey)
                        && (safelyRolledBack.contains($0.originalKey)
                            || !rollbackKeys.contains($0.originalKey))
                },
                client: preflight.destinationClient
            ))
            cleanupFailures.append(contentsOf: await cleanupTemporaryObjects(
                stagingObjects,
                client: preflight.destinationClient
            ))
            do {
                if FileManager.default.fileExists(atPath: temporaryRoot.path) {
                    try FileManager.default.removeItem(at: temporaryRoot)
                }
            } catch {
                cleanupFailures.append(temporaryRoot.path)
            }
            noteBucketMutated(
                accountID: preflight.sourceAccount.id,
                bucketName: preflight.sourceBucket.name
            )
            noteBucketMutated(
                accountID: preflight.destinationAccount.id,
                bucketName: preflight.destinationBucket.name
            )
            let rollbackDetail = cleanupFailures.isEmpty
                ? "已恢复本次尚未提交的目标对象"
                : "仍有 \(cleanupFailures.count) 项需要人工检查"
            present(
                "跨 Bucket 操作未完成：\(operationError.localizedDescription)\n\(rollbackDetail)",
                error: true
            )
        }
    }

    private func cleanupTemporaryObjects(
        _ objects: [CloudTemporaryObject],
        client: OSSClient
    ) async -> [String] {
        var failures: [String] = []
        for object in objects.reversed() {
            do {
                if Self.exactVersionID(object.versionID) == nil {
                    guard try await client.bucketVersioningStatus() == .disabled else {
                        failures.append(object.key)
                        continue
                    }
                }
                _ = try await client.deleteObject(key: object.key, versionID: object.versionID)
            } catch {
                failures.append(object.key)
            }
        }
        return failures
    }

    private static func exactVersionID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.caseInsensitiveCompare("null") != .orderedSame
        else { return nil }
        return value
    }

    func undoLastCloudOperation() async {
        guard !isOrganizingCloud, let client = makeClient() else { return }

        if let deletion = lastDeleteUndoOperation,
           isCurrentScope(for: deletion) {
            isOrganizingCloud = true
            defer { isOrganizingCloud = false }
            do {
                for marker in deletion.markers.reversed() {
                    try await client.deleteObject(
                        key: marker.key,
                        versionID: marker.versionID
                    )
                }
                lastDeleteUndoOperation = nil
                noteBucketMutated()
                browser.clearSelection()
                await refreshListing()
                browser.replaceSelection(deletion.sourceSelection)
                present("已恢复删除的项目")
            } catch {
                present(error.localizedDescription, error: true)
            }
            return
        }

        guard let operation = lastCloudUndoOperation,
              isCurrentScope(for: operation)
        else { return }

        guard operation.hasCompleteDestinationIdentities else {
            present("撤销记录缺少目标对象的精确版本信息，已取消以避免误移动", error: true)
            return
        }

        isOrganizingCloud = true
        defer { isOrganizingCloud = false }
        do {
            try await client.performCloudOperation(
                operation.inverseMappings,
                mode: .move,
                expectedSources: operation.committedDestinationIdentities
            )
            for move in operation.inverseFavoriteMoves {
                favorites.replacePrefix(
                    accountID: operation.accountID,
                    bucketName: operation.bucketName,
                    source: move.sourcePrefix,
                    destination: move.destinationPrefix
                )
            }
            lastCloudUndoOperation = nil
            noteBucketMutated()
            browser.clearSelection()
            await refreshListing()
            browser.replaceSelection(operation.sourceSelection)
            present("已撤销上一步操作")
        } catch {
            present(error.localizedDescription, error: true)
        }
    }

    private func isCurrentScope(for operation: CloudUndoOperation) -> Bool {
        selectedAccountID == operation.accountID
            && selectedBucketName == operation.bucketName
    }

    private func isCurrentScope(for operation: CloudDeleteUndoOperation) -> Bool {
        selectedAccountID == operation.accountID
            && selectedBucketName == operation.bucketName
    }

    func downloadSelection() {
        let objects = actionableObjects
        let folders = actionableFolders
        guard !objects.isEmpty || !folders.isEmpty else { return }
        guard let dest = chooseDownloadDirectory() else { return }
        let preserveObjectKeyPath = isBucketSearchActive
        Task {
            await startDownloads(
                objects: objects,
                folders: folders,
                to: dest,
                preserveObjectKeyPath: preserveObjectKeyPath
            )
        }
    }

    func downloadFolder(_ folder: OSSFolder) {
        guard let dest = chooseDownloadDirectory(message: "下载“\(folder.name)”到") else { return }
        Task { await startDownloads(objects: [], folders: [folder], to: dest) }
    }

    func downloadCurrentPrefix() {
        guard selectedBucket != nil else { return }
        let prefix = browser.prefix
        let name = prefix.isEmpty ? (selectedBucket?.name ?? "bucket") : PathTemplate.lastComponent(prefix)
        guard let dest = chooseDownloadDirectory(message: "下载“\(name)”到") else { return }
        Task { await startDownloads(objects: [], folders: [], to: dest, extraPrefix: (prefix, name)) }
    }

    private func chooseDownloadDirectory(message: String = "选择下载位置") -> URL? {
        if settings.downloadLocation == .downloads {
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "存储"
        panel.message = message
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func downloadRelativePath(for object: OSSObject, preserveKeyPath: Bool) -> String {
        preserveKeyPath ? PathTemplate.sanitizeKey(object.key) : object.name
    }

    func startDownloads(
        objects: [OSSObject],
        folders: [OSSFolder],
        to dest: URL,
        extraPrefix: (prefix: String, folderName: String)? = nil,
        preserveObjectKeyPath: Bool = false
    ) async {
        guard let account = selectedAccount,
              let bucket = selectedBucket,
              let client = makeClient() else { return }
        var items: [(object: OSSObject, destination: URL)] = []
        var skippedLocal = 0
        var skippedUnsafe = 0
        for object in objects {
            let url: URL
            do {
                url = try FileSafety.destination(
                    root: dest,
                    relativePath: downloadRelativePath(for: object, preserveKeyPath: preserveObjectKeyPath)
                )
            } catch {
                skippedUnsafe += 1
                continue
            }
            items.append((object: object, destination: url))
        }
        var prefixes: [(String, String)] = folders.map { ($0.prefix, $0.name) }
        if let extraPrefix {
            prefixes.append(extraPrefix)
        }
        if !prefixes.isEmpty {
            present("正在列出要下载的文件…")
        }
        for (prefix, folderName) in prefixes {
            do {
                let listing = try await client.listAllObjects(prefix: prefix)
                if listing.truncated {
                    present("“\(folderName)”没有完整列出，已取消下载，以免遗漏", error: true)
                    return
                }
                if listing.objects.isEmpty {
                    present("“\(folderName)”里没有可下载的文件", error: true)
                    continue
                }
                for object in listing.objects {
                    let relative = PathTemplate.relative(object.key, under: prefix)
                    let url: URL
                    do {
                        url = try FileSafety.destination(
                            root: dest,
                            relativePath: PathTemplate.join(folderName, key: relative)
                        )
                    } catch {
                        skippedUnsafe += 1
                        continue
                    }
                    items.append((object: object, destination: url))
                }
            } catch {
                present(error.localizedDescription, error: true)
                return
            }
        }
        guard !items.isEmpty else {
            if skippedUnsafe > 0 {
                present("对象路径不安全，已跳过 \(skippedUnsafe) 项", error: true)
            }
            return
        }
        guard let resolved = resolveDownloadConflicts(items: items, root: dest) else {
            return
        }
        items = resolved.items
        skippedLocal += resolved.skipped
        guard !items.isEmpty else {
            present("本地已有同名文件，已跳过 \(skippedLocal) 项")
            return
        }
        transfers.downloadConcurrency = settings.concurrentDownloads
        transfers.downloadSpeedLimit = settings.downloadSpeedLimit
        transfers.enqueueDownloadJobs(
            items: items,
            client: client,
            account: account,
            bucket: bucket,
            scopedRoot: dest,
            speedLimit: settings.downloadSpeedLimit,
            overwriteDestinations: resolved.overwriteDestinations
        )
        if skippedLocal + skippedUnsafe > 0 {
            present("已加入 \(items.count) 个下载，跳过 \(skippedLocal + skippedUnsafe) 项")
        } else if items.count > 1 {
            present("已加入 \(items.count) 个下载")
        }
    }

    private func resolveDownloadConflicts(
        items: [(object: OSSObject, destination: URL)],
        root: URL
    ) -> (items: [(object: OSSObject, destination: URL)], skipped: Int, overwriteDestinations: [URL: TransferEngine.LocalFileIdentity])? {
        let rootPath = root.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let relativePaths = items.map { item -> String in
            let path = item.destination.standardizedFileURL.path
            return path.hasPrefix(rootPrefix) ? String(path.dropFirst(rootPrefix.count)) : item.object.name
        }
        let existing = Set(zip(relativePaths, items).compactMap { relative, item in
            FileManager.default.fileExists(atPath: item.destination.path) ? relative : nil
        })
        var policy = settings.transferConflictPolicy
        if policy == .ask, !existing.isEmpty {
            let alert = NSAlert()
            alert.messageText = existing.count == 1 ? "本地已有同名文件" : "本地已有 \(existing.count) 个同名文件"
            alert.informativeText = "可以替换现有文件，或跳过这些项目。"
            alert.addButton(withTitle: "替换")
            alert.addButton(withTitle: "跳过")
            alert.addButton(withTitle: "取消")
            switch alert.runModal() {
            case .alertFirstButtonReturn: policy = .replace
            case .alertSecondButtonReturn: policy = .skip
            default: return nil
            }
        }
        let resolutions = TransferConflictPlanner.plan(
            keys: relativePaths,
            existing: existing,
            policy: policy
        )
        var resolved: [(object: OSSObject, destination: URL)] = []
        var overwriteDestinations: [URL: TransferEngine.LocalFileIdentity] = [:]
        var skipped = 0
        for (index, resolution) in resolutions.enumerated() {
            let item = items[index]
            switch resolution {
            case .skip, .ask:
                skipped += 1
            case .renamed(let relative):
                guard let destination = try? FileSafety.destination(root: root, relativePath: relative) else {
                    skipped += 1
                    continue
                }
                resolved.append((item.object, destination))
            case .useOriginal:
                resolved.append(item)
                if policy == .replace, existing.contains(relativePaths[index]) {
                    do {
                        overwriteDestinations[item.destination.standardizedFileURL] =
                            try TransferEngine.LocalFileIdentity.capture(item.destination)
                    } catch {
                        present(error.localizedDescription, error: true)
                        return nil
                    }
                }
            }
        }
        return (resolved, skipped, overwriteDestinations)
    }

    func copyURLs(style: LinkStyle = .plain) {
        guard let account = selectedAccount, let bucket = selectedBucket else { return }
        let client = account.prefersSignedLinks ? makeClient() : nil
        var usedSigned = false
        let urls = actionableObjects.compactMap { object -> String? in
            let resolved: URL?
            if let client,
               let signed = client.presignedURL(
                   key: object.key,
                   expires: settings.signedLinkLifetime.rawValue
               ) {
                usedSigned = true
                resolved = signed
            } else {
                resolved = account.publicURL(bucketName: bucket.name, bucket: bucket, key: object.key)
            }
            guard let url = resolved else { return nil }
            switch style {
            case .plain: return url.absoluteString
            case .markdown:
                return LinkEscaping.markdownImage(name: object.name, url: url.absoluteString)
            case .html:
                return LinkEscaping.htmlImage(name: object.name, url: url.absoluteString)
            }
        }
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.joined(separator: "\n"), forType: .string)
        Haptics.alignment()
        present(usedSigned ? "已复制签名链接，\(settings.signedLinkLifetime.title)内有效" : "已复制 \(urls.count) 条链接")
    }

    var inspectorObject: OSSObject? {
        isBucketSearchActive ? searchSelectedObjects.first : browser.primarySelection
    }

    /// What the inspector sheet should render. Search must never fall back to
    /// the hidden folder listing — download/delete in the sheet follow
    /// `actionableSelectionKeys`, so the heading has to match.
    var inspectorSurface: InspectorSurface {
        if isBucketSearchActive {
            let keys = actionableSelectionKeys
            if keys.count > 1 {
                return .multiple(
                    count: keys.count,
                    folderCount: 0,
                    objects: actionableObjects
                )
            }
            if let object = inspectorObject {
                return .object(object)
            }
            return .searchEmpty
        }
        if browser.selectedKeys.count > 1 {
            return .multiple(
                count: browser.selectedKeys.count,
                folderCount: browser.folders.filter { browser.selectedKeys.contains($0.prefix) }.count,
                objects: browser.objects.filter { browser.selectedKeys.contains($0.key) }
            )
        }
        if let object = browser.primarySelection {
            return .object(object)
        }
        if selectedBucket != nil {
            return .folder
        }
        return .unavailable
    }

    func loadInspector() async {
        guard let object = inspectorObject, let client = makeClient() else {
            inspectorLoadTask?.cancel()
            inspectorRequestGate.invalidate()
            inspectorHead = nil
            inspectorText = nil
            isLoadingHead = false
            return
        }
        inspectorLoadTask?.cancel()
        let context = inspectorRequestGate.begin(
            accountID: selectedAccountID,
            bucketName: selectedBucketName,
            prefix: browser.prefix,
            objectKey: object.key
        )
        isLoadingHead = true
        inspectorText = nil
        let task = Task { () throws -> (ObjectHead, String?) in
            let head = try await client.head(key: object.key)
            var text: String?
            if object.isText,
               object.size <= 512_000,
               let data = try? await client.objectData(key: object.key) {
                text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
            }
            return (head, text)
        }
        inspectorLoadTask = task
        do {
            let (head, text) = try await task.value
            guard inspectorRequestGate.canCommit(context),
                  inspectorObject?.key == context.objectKey
            else { return }
            inspectorHead = head
            inspectorText = text
        } catch is CancellationError {
            // A newer selection replaced this one.
        } catch {
            if inspectorRequestGate.canCommit(context) {
                inspectorHead = nil
                inspectorText = nil
            }
        }
        if inspectorRequestGate.canCommit(context) {
            isLoadingHead = false
            inspectorLoadTask = nil
        }
    }

    func quickLookSelection() async {
        let objects = actionableObjects
        if let object = objects.first, objects.count == 1 {
            await quickLook(object)
            return
        }
        guard !isBucketSearchActive else { return }
        // Space with only a single folder selected opens it (folders have no
        // QuickLook payload); this matches the double-click behavior in both
        // grid and list views.
        let folders = browser.selectedFolders
        if objects.isEmpty, folders.count == 1, let folder = folders.first {
            openFolder(folder)
        }
    }

    func quickLook(_ object: OSSObject) async {
        guard let client = makeClient() else { return }
        previewGeneration += 1
        let generation = previewGeneration
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OssunoQuickLook", directoryHint: .isDirectory)
        let name = (try? ObjectNameValidator.validate(object.name)) ?? "预览文件"
        let dest: URL
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            dest = try FileSafety.destination(
                root: directory,
                relativePath: "\(UUID().uuidString)-\(name)"
            )
            try await client.download(key: object.key, to: dest, within: directory)
            guard generation == previewGeneration else {
                try? FileManager.default.removeItem(at: dest)
                return
            }
            presentPreview(at: dest)
        } catch {
            guard generation == previewGeneration else { return }
            present(error.localizedDescription, error: true)
        }
    }

    func presentPreview(at url: URL) {
        ownedPreviewURLs.insert(url)
        previewItem = url
    }

    func copyFolderPath(_ prefix: String, includeBucket: Bool) {
        let text: String
        if includeBucket, let bucket = selectedBucket {
            text = prefix.isEmpty ? bucket.name : "\(bucket.name)/\(prefix)"
        } else {
            text = prefix.isEmpty ? "/" : prefix
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        present("已复制路径")
    }

    func copyFolderURL(_ prefix: String) {
        guard let account = selectedAccount, let bucket = selectedBucket,
              let url = account.publicURL(bucketName: bucket.name, bucket: bucket, key: prefix)
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        present("已复制链接")
    }

    func present(
        _ text: String,
        error: Bool = false,
        action: BannerAction? = nil
    ) {
        banner = BannerMessage(text: text, isError: error, action: action)
    }

    func pasteFromClipboard(to prefix: String? = nil) {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            upload(urls: urls, to: prefix)
            return
        }
        if let images = board.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            var files: [URL] = []
            for image in images {
                if let url = Self.writeTemporaryJPEG(image) {
                    files.append(url)
                }
            }
            if !files.isEmpty {
                upload(urls: files, to: prefix, ownedTemporaryURLs: Set(files))
            }
        }
    }

    private var hasFileURLsOnPasteboard: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: nil)
            || NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    private static func writeTemporaryJPEG(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
        else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(path: "clipboard-\(UUID().uuidString).jpg")
        do {
            try data.write(to: url)
        } catch {
            return nil
        }
        return url
    }

    private static func defaultClient(account: OSSAccount, bucket: OSSBucket?) throws -> OSSClient {
        let credentials = try AccountStore.credentials(for: account)
        return OSSClient(
            credentials: credentials,
            region: account.signingRegion(for: bucket),
            endpointHost: account.apiHost(for: bucket),
            bucket: bucket?.name
        )
    }

    private func invalidateListingAndInspectorRequests() {
        listingLoadTask?.cancel()
        listingLoadTask = nil
        listingRequestGate.invalidate()
        browser.isLoading = false
        inspectorLoadTask?.cancel()
        inspectorLoadTask = nil
        inspectorRequestGate.invalidate()
        inspectorHead = nil
        inspectorText = nil
        isLoadingHead = false
    }

    private func invalidateAllBrowserRequests() {
        clearBucketSearch()
        bucketLoadTask?.cancel()
        bucketLoadTask = nil
        bucketRequestGate.invalidate()
        isLoadingBuckets = false
        invalidateListingAndInspectorRequests()
    }
}

enum LinkStyle {
    case plain, markdown, html
}

struct OverwritePrompt: Identifiable {
    let id = UUID()
    var plan: TransferEngine.UploadPlan
    var client: OSSClient
    var account: OSSAccount
    var bucket: OSSBucket?
    var conflicts: [String]
    var skipSources: Set<URL>
    /// Exact remote identities that existed when the prompt was shown.
    /// Approval is scoped to these versions; a target that changes while a job
    /// is queued must be confirmed again instead of inheriting a stale Bool.
    var overwriteDestinations: [String: OSSObjectIdentity]
    /// OSS offers no destination compare-and-swap for replacement. Exact,
    /// recoverable overwrite therefore requires an Enabled versioned Bucket.
    var versioningStatus: OSSBucketVersioningStatus? = nil

    var canOverwriteSafely: Bool { versioningStatus == .enabled }

    var title: String {
        conflicts.count == 1 ? "“\(conflicts[0])”已存在" : "\(conflicts.count) 个文件已存在"
    }

    var message: String {
        let shown = conflicts.prefix(12)
        var text = shown.joined(separator: "\n")
        if conflicts.count > shown.count {
            text += "\n以及另外 \(conflicts.count - shown.count) 个"
        }
        if canOverwriteSafely {
            text += "\n只会替换上面已确认的精确版本；目标若发生变化会自动取消。"
        } else if let versioningStatus {
            text += "\nBucket 版本控制为 \(versioningStatus.rawValue)。为防止不可恢复的并发覆盖，请先启用版本控制，或跳过这些文件。"
        } else {
            text += "\n无法确认 Bucket 版本控制状态，覆盖已禁用；你仍可跳过这些文件。"
        }
        return text
    }
}

struct CloudConflictPrompt: Identifiable {
    let id = UUID()
    var payload: CloudDragPayload
    var destinationPrefix: String
    var mode: CloudOperationMode
    var conflictKeys: [String]
    var isCrossBucket: Bool
    var destinationAccountID: UUID
    var destinationBucketName: String
    var versioningStatus: OSSBucketVersioningStatus? = nil

    var canReplaceSafely: Bool { versioningStatus == .enabled }

    var title: String {
        conflictKeys.count == 1 ? "目标已有同名项目" : "目标已有 \(conflictKeys.count) 个同名项目"
    }

    var message: String {
        let shown = conflictKeys.prefix(10).map { PathTemplate.lastComponent($0) }
        var text = shown.joined(separator: "\n")
        if conflictKeys.count > shown.count {
            text += "\n以及另外 \(conflictKeys.count - shown.count) 个"
        }
        if canReplaceSafely {
            text += "\n目标已启用版本控制；可替换已确认版本，或选择保留/跳过。"
        } else if let versioningStatus {
            text += "\n目标 Bucket 版本控制为 \(versioningStatus.rawValue)，安全覆盖已禁用；请选择保留两者或跳过。"
        } else {
            text += "\n无法确认目标 Bucket 的版本控制状态，安全覆盖已禁用。"
        }
        return text
    }
}

struct AccountDraft: Identifiable {
    var id: UUID
    var name: String
    var accessKeyId: String
    var secret: String
    var token: String
    var regionID: String
    var endpointOverride: String
    var cdnDomain: String
    var defaultACL: ObjectACL
    var prefixTemplate: String
    var useTransferAccelerate: Bool
    var createdAt: Date

    var isReadyToSave: Bool {
        !accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func fresh() -> AccountDraft {
        AccountDraft(
            id: UUID(),
            name: "",
            accessKeyId: "",
            secret: "",
            token: "",
            regionID: "cn-hangzhou",
            endpointOverride: "",
            cdnDomain: "",
            defaultACL: .default,
            prefixTemplate: "",
            useTransferAccelerate: false,
            createdAt: .now
        )
    }

    static func from(_ account: OSSAccount, secret: String, token: String) -> AccountDraft {
        AccountDraft(
            id: account.id,
            name: account.name,
            accessKeyId: account.accessKeyId,
            secret: secret,
            token: token,
            regionID: account.regionID,
            endpointOverride: account.endpointOverride,
            cdnDomain: account.cdnDomain,
            defaultACL: account.defaultACL,
            prefixTemplate: account.prefixTemplate,
            useTransferAccelerate: account.useTransferAccelerate,
            createdAt: account.createdAt
        )
    }
}
