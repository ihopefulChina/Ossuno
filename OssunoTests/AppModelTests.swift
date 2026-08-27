import AppKit
import Foundation
import Testing
@testable import Ossuno

@MainActor
struct AppModelTests {
    @Test func ordinaryBannerUsesShortDisplayDurationWithoutAnAction() {
        let banner = BannerMessage(text: "已复制链接", isError: false)

        #expect(banner.action == nil)
        #expect(banner.displayDuration == .milliseconds(2_400))
    }

    @Test func undoBannerUsesLongDisplayDurationAndSemanticAction() {
        let banner = BannerMessage(
            text: "已重命名“封面.png”",
            isError: false,
            action: .undoCloudOperation
        )

        #expect(banner.action == .undoCloudOperation)
        #expect(banner.displayDuration == .milliseconds(5_500))
    }

    @Test func presentingUndoFeedbackPreservesTheSemanticAction() {
        let model = AppModel(kind: .settings, services: AppServices(accounts: []))

        model.present("已移动 2 项", action: .undoCloudOperation)

        #expect(model.banner?.text == "已移动 2 项")
        #expect(model.banner?.isError == false)
        #expect(model.banner?.action == .undoCloudOperation)
    }

    @Test func preferredBrowserViewPersists() {
        let defaults = Self.defaults()
        let first = AppSettings(defaults: defaults)

        first.preferredViewMode = .list

        #expect(AppSettings(defaults: defaults).preferredViewMode == .list)
    }

    @Test func browserDoesNotHideUnknownObjectTypesByDefault() {
        let defaults = Self.defaults()
        let settings = AppSettings(defaults: defaults)
        let browser = BrowserModel(defaults: defaults)
        browser.objects = [
            OSSObject(
                key: "database.dump",
                size: 1,
                etag: "dump",
                lastModified: nil,
                storageClass: "Standard"
            )
        ]

        #expect(!settings.imagesOnly)
        #expect(!browser.imagesOnly)
        #expect(browser.visibleObjects.map(\.key) == ["database.dump"])
    }

    @Test func materialFilterChoicePersists() {
        let defaults = Self.defaults()
        let settings = AppSettings(defaults: defaults)

        settings.imagesOnly = true
        #expect(AppSettings(defaults: defaults).imagesOnly)

        settings.imagesOnly = false
        #expect(!AppSettings(defaults: defaults).imagesOnly)
    }

    @Test func textEditingDetectionCoversFieldEditorsAndSecureFields() {
        let editor = NSTextView()
        let secureField = NSSecureTextField()
        let unrelated = NSView()

        #expect(BrowserKeyEvent.isEditingText(responder: editor, fieldEditor: editor))
        #expect(BrowserKeyEvent.isEditingText(responder: secureField, fieldEditor: editor))
        #expect(!BrowserKeyEvent.isEditingText(responder: unrelated, fieldEditor: editor))
    }

    @Test func browserShortcutsRespectTheFocusedResponderRegionAndNativeControls() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 1_000, height: 700))
        window.contentView = root
        let browserRegion = CGRect(x: 250, y: 0, width: 750, height: 650)

        let sidebar = NSTableView(frame: CGRect(x: 0, y: 0, width: 240, height: 650))
        let browserTable = NSTableView(frame: CGRect(x: 280, y: 0, width: 700, height: 600))
        let browserButton = NSButton(frame: CGRect(x: 800, y: 610, width: 120, height: 28))
        root.addSubview(sidebar)
        root.addSubview(browserTable)
        root.addSubview(browserButton)

        #expect(!BrowserShortcutScope.shouldHandle(
            responder: sidebar,
            window: window,
            browserRegion: browserRegion
        ))
        #expect(BrowserShortcutScope.shouldHandle(
            responder: browserTable,
            window: window,
            browserRegion: browserRegion
        ))
        #expect(!BrowserShortcutScope.shouldHandle(
            responder: browserButton,
            window: window,
            browserRegion: browserRegion
        ))
    }

    @Test func editingAccountDraftKeepsThePersistedIdentityBeforeKeychainLoading() {
        let account = OSSAccount(
            id: UUID(),
            name: "Production",
            accessKeyId: "LTAI-existing",
            regionID: "cn-shanghai",
            endpointOverride: "https://oss.example.test",
            cdnDomain: "cdn.example.test",
            defaultACL: .private,
            prefixTemplate: "assets/{yyyy}/",
            useTransferAccelerate: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let draft = AccountSheet.initialDraft(editing: account)

        #expect(draft.id == account.id)
        #expect(draft.name == account.name)
        #expect(draft.accessKeyId == account.accessKeyId)
        #expect(draft.regionID == account.regionID)
        #expect(draft.endpointOverride == account.endpointOverride)
        #expect(draft.cdnDomain == account.cdnDomain)
        #expect(draft.defaultACL == account.defaultACL)
        #expect(draft.prefixTemplate == account.prefixTemplate)
        #expect(draft.useTransferAccelerate == account.useTransferAccelerate)
        #expect(draft.createdAt == account.createdAt)
        #expect(draft.secret.isEmpty)
        #expect(draft.token.isEmpty)
    }

    @Test func newAccountDraftStillGetsANewIdentity() {
        let draft = AccountSheet.initialDraft(editing: nil)

        #expect(draft.name.isEmpty)
        #expect(draft.accessKeyId.isEmpty)
        #expect(draft.secret.isEmpty)
    }

    @Test func newWindowUsesPreferredBrowserView() {
        let defaults = Self.defaults()
        let settings = AppSettings(defaults: defaults)
        settings.preferredViewMode = .list
        let services = AppServices(accounts: [], settings: settings)

        let model = AppModel(services: services)

        #expect(model.browser.viewMode == .list)
    }

    @Test func informationIsAvailableOnlyInsideABucket() {
        let model = AppModel(kind: .settings, services: AppServices(accounts: []))

        #expect(!model.canShowInformation)

        let bucket = OSSBucket(
            name: "design-assets",
            regionID: "cn-hangzhou",
            location: "oss-cn-hangzhou",
            extranetEndpoint: "oss-cn-hangzhou.aliyuncs.com",
            createdAt: nil
        )
        model.buckets = [bucket]
        model.selectedBucketName = bucket.name

        #expect(model.canShowInformation)
    }

    @Test func applyingPreferredViewUpdatesEveryOpenWindow() {
        let defaults = Self.defaults()
        let services = AppServices(accounts: [], settings: AppSettings(defaults: defaults))
        let first = AppModel(services: services)
        let second = AppModel(services: services)
        let settings = AppModel(kind: .settings, services: services)

        settings.applyPreferredViewModeToAllSessions(.list)

        #expect(first.browser.viewMode == .list)
        #expect(second.browser.viewMode == .list)
        #expect(settings.settings.preferredViewMode == .list)
    }

    @Test func testingAnAccountDoesNotChangeTheCurrentSelection() async throws {
        let account = OSSAccount(
            id: UUID(),
            name: "Studio",
            accessKeyId: "test",
            regionID: "cn-hangzhou",
            endpointOverride: "",
            cdnDomain: "",
            defaultACL: .default,
            prefixTemplate: "",
            useTransferAccelerate: false,
            createdAt: .now
        )
        let transport = AccountTestTransport()
        let services = AppServices(accounts: [account])
        let model = AppModel(kind: .settings, services: services) { _, _ in
            OSSClient(
                credentials: OSSCredentials(
                    accessKeyId: "test",
                    accessKeySecret: "secret",
                    securityToken: nil
                ),
                region: "cn-hangzhou",
                endpointHost: "oss-cn-hangzhou.aliyuncs.com",
                bucket: nil,
                transport: transport,
                testingVersioningStatusOverride: .disabled
            )
        }
        model.selectedAccountID = nil

        let bucketCount = try await model.testAccount(account)

        #expect(bucketCount == 2)
        #expect(model.selectedAccountID == nil)
    }

    @Test func bucketSearchUsesTheSelectedAccountAndBucket() async {
        let account = Self.account()
        let bucket = Self.bucket()
        let transport = BrowserSearchTransport()
        let model = Self.model(account: account, bucket: bucket, transport: transport)
        model.browser.searchText = "hero"
        model.searchScope = .bucket

        await model.runBucketSearch()

        #expect(model.searchController.activeQuery?.accountID == account.id)
        #expect(model.searchController.activeQuery?.bucketName == bucket.name)
        #expect(model.searchController.results.map(\.key) == ["art/hero.png"])
    }

    @Test func openingSearchResultNavigatesToItsFolderAndSelectsIt() async {
        let account = Self.account()
        let bucket = Self.bucket()
        let transport = BrowserSearchTransport()
        let model = Self.model(account: account, bucket: bucket, transport: transport)
        let object = OSSObject(
            key: "art/hero.png",
            size: 42,
            etag: "hero",
            lastModified: nil,
            storageClass: "Standard"
        )

        await model.openSearchResult(object)

        #expect(model.browser.prefix == "art/")
        #expect(model.browser.selectedKeys == [object.key])
    }

    @Test func openingUnknownSearchResultTemporarilyRevealsItWithoutChangingTheFilter() async {
        let account = Self.account()
        let bucket = Self.bucket()
        let transport = BrowserSearchTransport()
        let model = Self.model(account: account, bucket: bucket, transport: transport)
        model.settings.imagesOnly = true
        model.browser.imagesOnly = true
        let object = OSSObject(
            key: "art/database.dump",
            size: 84,
            etag: "dump",
            lastModified: nil,
            storageClass: "Standard"
        )

        await model.openSearchResult(object)

        #expect(model.settings.imagesOnly)
        #expect(model.browser.imagesOnly)
        #expect(model.browser.transientlyRevealedKey == object.key)
        #expect(model.browser.visibleObjects.contains(where: { $0.key == object.key }))
        #expect(model.browser.selectedKeys == [object.key])

        model.browser.navigate(to: "elsewhere/")

        #expect(model.browser.transientlyRevealedKey == nil)
        #expect(!model.browser.visibleObjects.contains(where: { $0.key == object.key }))
    }

    @Test func changingBucketClearsBucketSearchResults() async {
        let account = Self.account()
        let bucket = Self.bucket()
        let transport = BrowserSearchTransport()
        let model = Self.model(account: account, bucket: bucket, transport: transport)
        model.browser.searchText = "hero"
        model.searchScope = .bucket
        await model.runBucketSearch()

        model.selectBucket(
            OSSBucket(
                name: "archive",
                regionID: bucket.regionID,
                location: bucket.location,
                extranetEndpoint: bucket.extranetEndpoint,
                createdAt: nil
            )
        )

        #expect(model.searchController.results.isEmpty)
        #expect(model.searchController.activeQuery == nil)
    }

    @Test func clickingTheSelectedBucketAtRootDoesNotResetNavigation() {
        let account = Self.account()
        let bucket = Self.bucket()
        let transport = BrowserSearchTransport()
        let model = Self.model(account: account, bucket: bucket, transport: transport)
        model.browser.prefix = ""
        model.browser.backStack = ["art/"]

        model.applySidebarSelection(.bucket(bucket.name))

        #expect(model.selectedBucketName == bucket.name)
        #expect(model.browser.prefix == "")
        #expect(model.browser.backStack == ["art/"])
    }

    @Test func clickingTheCurrentBucketFromASubfolderReturnsToRoot() {
        let account = Self.account()
        let bucket = Self.bucket()
        let transport = BrowserSearchTransport()
        let model = Self.model(account: account, bucket: bucket, transport: transport)
        model.browser.prefix = "art/"
        model.browser.backStack = [""]

        model.applySidebarSelection(.bucket(bucket.name))

        #expect(model.selectedBucketName == bucket.name)
        #expect(model.browser.prefix == "")
        #expect(model.browser.backStack.isEmpty)
    }

    @Test func copySelectionMakesPasteAvailable() {
        let account = Self.account()
        let bucket = Self.bucket()
        let model = Self.model(account: account, bucket: bucket, transport: AccountTestTransport())
        model.browser.imagesOnly = false
        model.browser.objects = [
            OSSObject(key: "cover.png", size: 10, etag: "a", lastModified: nil, storageClass: "Standard")
        ]
        model.browser.replaceSelection(["cover.png"])

        #expect(model.canCopyCloudItems)

        model.copyCloudSelection()

        #expect(model.cloudClipboard?.objectKeys == ["cover.png"])
        #expect(model.cloudClipboard?.bucketName == bucket.name)
        #expect(model.banner?.text.contains("已复制") == true)
    }

    @Test func bucketSearchIsActiveOnlyForBucketScopeQueries() {
        let account = Self.account()
        let bucket = Self.bucket()
        let model = Self.model(account: account, bucket: bucket, transport: AccountTestTransport())

        model.searchScope = .folder
        model.browser.searchText = "hero"
        #expect(!model.isBucketSearchActive)

        model.searchScope = .bucket
        #expect(model.isBucketSearchActive)

        model.browser.searchText = "  "
        model.searchFilter = .all
        #expect(!model.isBucketSearchActive)

        model.searchFilter = .largeObjects
        #expect(model.isBucketSearchActive)
    }

    @Test func folderSearchTextStillShowsTheScopePicker() {
        let account = Self.account()
        let bucket = Self.bucket()
        let model = Self.model(account: account, bucket: bucket, transport: AccountTestTransport())

        #expect(!model.showsSearchChrome)

        model.browser.searchText = "hero"
        #expect(model.showsSearchChrome)
        #expect(!model.isBucketSearchActive)

        model.browser.searchText = ""
        model.searchScope = .bucket
        #expect(model.showsSearchChrome)
    }

    @Test func largeObjectSearchSelectionDrivesCopyAndDelete() async {
        let account = Self.account()
        let bucket = Self.bucket()
        let model = Self.model(account: account, bucket: bucket, transport: BrowserSearchTransport())
        model.searchScope = .bucket
        model.searchFilter = .all
        model.browser.searchText = "dump"
        await model.runBucketSearch()

        model.browser.replaceSelection(["unrelated-folder-item.png"])
        model.selectSearchKeys(["art/database.dump"])

        #expect(model.actionableSelectionKeys == ["art/database.dump"])
        #expect(model.actionableObjects.map(\.key) == ["art/database.dump"])
        #expect(model.canCopyCloudItems)

        let payload = model.cloudDragPayload(clickedKey: "art/database.dump")
        #expect(payload.objectKeys == ["art/database.dump"])
        #expect(payload.folderPrefixes.isEmpty)

        model.copyCloudSelection()
        #expect(model.cloudClipboard?.objectKeys == ["art/database.dump"])

        model.requestDeleteSelection()
        #expect(model.wantsDeleteConfirmation)
        #expect(model.deleteDialogTitle.contains("database.dump"))
    }

    @Test func searchContextMenuKeepsAMultiSelection() async {
        let account = Self.account()
        let bucket = Self.bucket()
        let model = Self.model(account: account, bucket: bucket, transport: BrowserSearchTransport())
        model.searchScope = .bucket
        model.browser.searchText = "art/"
        await model.runBucketSearch()

        model.selectSearchKeys(["art/hero.png", "art/database.dump"])
        model.selectForContextMenu("art/hero.png")

        #expect(model.searchSelectedKeys == ["art/hero.png", "art/database.dump"])
        #expect(model.menuActionKeys(clickedKey: "art/hero.png") == ["art/hero.png", "art/database.dump"])
        #expect(model.deleteMenuTitle(clickedKey: "art/hero.png") == "删除 2 项")
    }

    @Test func searchContextActionsTargetSearchHitsNotTheHiddenFolder() async {
        let account = Self.account()
        let bucket = Self.bucket()
        let model = Self.model(account: account, bucket: bucket, transport: BrowserSearchTransport())
        model.searchScope = .bucket
        model.browser.searchText = "dump"
        await model.runBucketSearch()
        model.selectSearchKeys(["art/database.dump"])

        #expect(model.object(forKey: "art/database.dump")?.size == 84)
        #expect(model.object(forKey: "cover.png") == nil)

        let actions = BrowserContextActions.live(
            model: model,
            kind: .bucketSearch,
            showFileImporter: {}
        )
        #expect(actions.tableItemIDs == ["art/database.dump"])
        #expect(actions.showsRevealInFolder)
        #expect(actions.usesSearchEmptyMenu)
        #expect(actions.viewMode == .list)
        #expect(actions.selectedKeys() == ["art/database.dump"])
    }

    @Test func inspectorObjectFollowsSearchSelectionNotTheHiddenFolder() async {
        let account = Self.account()
        let bucket = Self.bucket()
        let model = Self.model(account: account, bucket: bucket, transport: BrowserSearchTransport())
        model.searchScope = .bucket
        model.browser.searchText = "dump"
        await model.runBucketSearch()
        model.browser.imagesOnly = false
        model.browser.objects = [
            OSSObject(key: "cover.png", size: 10, etag: "a", lastModified: nil, storageClass: "Standard")
        ]
        model.browser.replaceSelection(["cover.png"])
        model.selectSearchKeys(["art/database.dump"])

        #expect(model.inspectorObject?.key == "art/database.dump")
    }

    @Test func confirmedSearchDeleteStillRunsAfterResultsAreCleared() async {
        let account = Self.account()
        let bucket = Self.bucket()
        let transport = RecordingDeleteTransport()
        let model = Self.model(account: account, bucket: bucket, transport: transport)
        model.searchScope = .bucket
        model.browser.searchText = "dump"
        await model.runBucketSearch()
        model.selectSearchKeys(["art/database.dump"])
        model.requestDeleteSelection()

        #expect(model.wantsDeleteConfirmation)
        model.searchController.clear()
        #expect(model.searchController.results.isEmpty)
        #expect(model.isBucketSearchActive)

        await model.deleteSelection()

        #expect(await transport.deletedKeys == ["art/database.dump"])
        #expect(model.banner?.text.contains("已删除") == true)
    }

    @Test func searchDownloadsKeepParentPrefixes() async {
        let account = Self.account()
        let bucket = Self.bucket()
        let model = Self.model(account: account, bucket: bucket, transport: BrowserSearchTransport())
        let first = OSSObject(
            key: "a/hero.png",
            size: 1,
            etag: "a",
            lastModified: nil,
            storageClass: "Standard"
        )
        let second = OSSObject(
            key: "b/hero.png",
            size: 1,
            etag: "b",
            lastModified: nil,
            storageClass: "Standard"
        )

        #expect(model.downloadRelativePath(for: first, preserveKeyPath: true) == "a/hero.png")
        #expect(model.downloadRelativePath(for: second, preserveKeyPath: true) == "b/hero.png")
        #expect(model.downloadRelativePath(for: first, preserveKeyPath: false) == "hero.png")

        let dest = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-search-download-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }

        await model.startDownloads(
            objects: [first, second],
            folders: [],
            to: dest,
            preserveObjectKeyPath: true
        )

        let relative = Set(model.transfers.jobs.compactMap { job -> String? in
            guard let path = job.localURL?.standardizedFileURL.path else { return nil }
            let root = dest.standardizedFileURL.path + "/"
            guard path.hasPrefix(root) else { return nil }
            return String(path.dropFirst(root.count))
        })
        #expect(relative == ["a/hero.png", "b/hero.png"])
    }

    @Test func searchRenamePresentsAnErrorWhenTheFolderListingCannotRevealTheHit() async throws {
        let account = Self.account()
        let bucket = Self.bucket()
        let model = Self.model(
            account: account,
            bucket: bucket,
            transport: SearchThenEmptyFolderTransport()
        )
        model.searchScope = .bucket
        model.browser.searchText = "dump"
        await model.runBucketSearch()
        model.selectSearchKeys(["art/database.dump"])

        model.requestRename(key: "art/database.dump")
        try await Self.waitUntil {
            model.banner?.isError == true
                && model.banner?.text.contains("无法重命名") == true
        }

        #expect(model.browser.renameSession == nil)
        #expect(model.banner?.text.contains("打开所在文件夹") == true)
    }

    @Test func copyWithoutSelectionDoesNotCreateAClipboard() {
        let account = Self.account()
        let bucket = Self.bucket()
        let model = Self.model(account: account, bucket: bucket, transport: AccountTestTransport())
        model.browser.imagesOnly = false
        model.browser.objects = [
            OSSObject(key: "cover.png", size: 10, etag: "a", lastModified: nil, storageClass: "Standard")
        ]

        model.copyCloudSelection()

        #expect(model.cloudClipboard == nil)
        #expect(!model.canCopyCloudItems)
    }

    @Test func copyClickedKeyWorksWithoutAPriorSelection() {
        let account = Self.account()
        let bucket = Self.bucket()
        let model = Self.model(account: account, bucket: bucket, transport: AccountTestTransport())
        model.browser.imagesOnly = false
        model.browser.folders = [OSSFolder(prefix: "art/")]
        model.browser.objects = [
            OSSObject(key: "cover.png", size: 10, etag: "a", lastModified: nil, storageClass: "Standard")
        ]

        model.copyCloudSelection(clickedKey: "art/")

        #expect(model.cloudClipboard?.folderPrefixes == ["art/"])
        #expect(model.canPasteCloudItems)
        #expect(model.canPaste)
    }

    @Test func copyPasteInTheSameFolderKeepsBothNames() {
        #expect(
            CloudObjectOperation.copyDestination(
                source: "cover.png",
                destinationPrefix: "",
                isFolder: false,
                reserved: []
            ) == "cover 2.png"
        )
        #expect(
            CloudObjectOperation.copyDestination(
                source: "art/",
                destinationPrefix: "",
                isFolder: true,
                reserved: []
            ) == "art 2/"
        )
        #expect(
            CloudObjectOperation.copyDestination(
                source: "cover.png",
                destinationPrefix: "art/",
                isFolder: false,
                reserved: []
            ) == "art/cover.png"
        )
        #expect(
            CloudObjectOperation.copyDestination(
                source: "cover.png",
                destinationPrefix: "art/",
                isFolder: false,
                reserved: ["art/cover.png"]
            ) == "art/cover 2.png"
        )
    }

    @Test func cloudClipboardRoundTripsThroughPasteboard() {
        let payload = CloudDragPayload(
            accountID: UUID(),
            bucketName: "design-assets",
            sourceRegionID: "cn-hangzhou",
            objectKeys: ["cover.png"],
            folderPrefixes: ["art/"]
        )
        let board = NSPasteboard.withUniqueName()

        CloudClipboard.write(payload, mode: .move, to: board)

        #expect(CloudClipboard.read(from: board)?.payload == payload)
        #expect(CloudClipboard.read(from: board)?.mode == .move)
    }

    @Test func cutSelectionUsesMoveOnPaste() {
        let account = Self.account()
        let bucket = Self.bucket()
        let model = Self.model(account: account, bucket: bucket, transport: AccountTestTransport())
        model.browser.imagesOnly = false
        model.browser.objects = [
            OSSObject(key: "cover.png", size: 10, etag: "a", lastModified: nil, storageClass: "Standard")
        ]
        model.browser.replaceSelection(["cover.png"])

        model.cutCloudSelection()

        #expect(model.cloudClipboard?.objectKeys == ["cover.png"])
        #expect(model.cloudClipboardMode == .move)
        #expect(model.pasteMenuTitle == "移动到此处")
        #expect(model.banner?.text.contains("已剪切") == true)
    }

    @Test func replacingThePasteboardInvalidatesTheInMemoryCloudClipboard() {
        let account = Self.account()
        let bucket = Self.bucket()
        let model = Self.model(account: account, bucket: bucket, transport: AccountTestTransport())
        model.browser.imagesOnly = false
        model.browser.objects = [
            OSSObject(key: "cover.png", size: 10, etag: "a", lastModified: nil, storageClass: "Standard")
        ]
        model.browser.replaceSelection(["cover.png"])
        model.copyCloudSelection()
        #expect(model.canPasteCloudItems)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("unrelated", forType: .string)

        #expect(model.cloudClipboard != nil)
        #expect(!model.canPasteCloudItems)
        #expect(model.resolvedClipboardItem == nil)
    }

    @Test func moveStaysInPlaceWhenPastingIntoTheSameFolder() {
        #expect(
            CloudObjectOperation.staysInPlace(
                objectKeys: ["cover.png"],
                folderPrefixes: [],
                destinationPrefix: ""
            )
        )
        #expect(
            !CloudObjectOperation.staysInPlace(
                objectKeys: ["cover.png"],
                folderPrefixes: [],
                destinationPrefix: "art/"
            )
        )
    }

    @Test func folderDeleteUsesClickedKeyEvenIfSelectionClears() {
        let account = Self.account()
        let bucket = Self.bucket()
        let model = Self.model(account: account, bucket: bucket, transport: AccountTestTransport())
        model.browser.imagesOnly = false
        model.browser.folders = [OSSFolder(prefix: "art/")]
        model.browser.replaceSelection(["art/"])

        model.requestDeleteSelection(keys: ["art/"])
        model.browser.clearSelection()

        #expect(model.wantsDeleteConfirmation)
        #expect(model.deleteDialogTitle.contains("art"))
    }

    @Test func organizingCloudBlocksDeleteConfirmation() {
        let account = Self.account()
        let bucket = Self.bucket()
        let transport = BrowserSearchTransport()
        let model = Self.model(account: account, bucket: bucket, transport: transport)
        model.browser.objects = [
            OSSObject(key: "a.txt", size: 1, etag: "a", lastModified: nil, storageClass: "Standard")
        ]
        model.browser.imagesOnly = false
        model.browser.replaceSelection(["a.txt"])
        model.isOrganizingCloud = true

        model.requestDeleteSelection()

        #expect(model.wantsDeleteConfirmation == false)
        #expect(model.banner?.isError == true)
    }

    @Test func incompleteFolderListingNeverEnqueuesDownloads() async {
        let account = Self.account()
        let bucket = Self.bucket()
        let transport = TruncatedListTransport()
        let model = Self.model(account: account, bucket: bucket, transport: transport)
        let folder = OSSFolder(prefix: "huge/")
        let dest = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-download-cap-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }

        await model.startDownloads(objects: [], folders: [folder], to: dest)

        #expect(model.transfers.jobs.isEmpty)
        #expect(model.banner?.text.contains("没有完整列出") == true)
        #expect(model.banner?.isError == true)
    }

    @Test func mutatingTheBucketClearsStaleSearchResults() async {
        let account = Self.account()
        let bucket = Self.bucket()
        let transport = BrowserSearchTransport()
        let model = Self.model(account: account, bucket: bucket, transport: transport)
        model.browser.searchText = "hero"
        model.searchScope = .bucket
        await model.runBucketSearch()

        #expect(model.searchController.results.map(\.key) == ["art/hero.png"])

        model.noteBucketMutated()

        #expect(model.searchController.results.isEmpty)
        #expect(model.searchController.activeQuery == nil)
    }

    @Test func inlineRenameUndoNeverFallsThroughToCloudUndo() {
        #expect(WorkspaceUndo.resolve(isRenaming: true, fieldCanUndo: true) == .field)
        #expect(WorkspaceUndo.resolve(isRenaming: true, fieldCanUndo: false) == .cancelRename)
        #expect(WorkspaceUndo.resolve(isRenaming: false, fieldCanUndo: false) == .cloud)
    }

    @Test func quitPromptsWhenOrganizingOrTransferring() {
        #expect(!AppTermination.shouldConfirm(transferring: false, organizing: false))
        #expect(AppTermination.shouldConfirm(transferring: true, organizing: false))
        #expect(AppTermination.shouldConfirm(transferring: false, organizing: true))
        #expect(AppTermination.prompt(transferring: false, organizing: true).title == "还有云端整理未完成")
    }

    @Test func existingKeysFallsBackToHeadWhenAParentListingIsTruncated() async throws {
        let account = Self.account()
        let bucket = Self.bucket()
        let transport = ConflictProbeTransport()
        let model = Self.model(account: account, bucket: bucket, transport: transport)
        let keys = (1...41).map { "file-\($0).txt" }

        let found = try await model.existingKeys(among: keys, client: model.makeClient()!)

        #expect(found == ["file-1.txt"])
        #expect(await transport.headCount == 41)
    }

    @Test func uploadOverwriteApprovalIsBoundToTheExactRemoteIdentity() async throws {
        for mutation in UploadIdentityMutation.allCases {
            let source = FileManager.default.temporaryDirectory
                .appending(path: "\(UUID().uuidString)-identity.txt")
            try Data("test data".utf8).write(to: source)
            defer { try? FileManager.default.removeItem(at: source) }

            let account = Self.account()
            let bucket = Self.bucket()
            let transport = UploadIdentityDriftTransport()
            let model = Self.model(
                account: account,
                bucket: bucket,
                transport: transport,
                versioningStatus: .enabled
            )
            model.settings.transferConflictPolicy = .ask

            model.upload(urls: [source], to: "", applyTemplate: false)
            try await Self.waitUntil { model.overwritePrompt != nil }
            let approvedIdentity = try #require(
                model.overwritePrompt?.overwriteDestinations.values.first
            )
            #expect(approvedIdentity == UploadIdentityDriftTransport.initialIdentity)

            await transport.apply(mutation)
            let changedIdentity = await transport.currentIdentity
            model.confirmOverwrite()
            try await Self.waitUntil {
                model.transfers.jobs.count == 1 && model.transfers.jobs.allSatisfy { !$0.isActive }
            }

            let job = try #require(model.transfers.jobs.first)
            #expect(job.status == .failed)
            #expect(job.errorMessage?.contains("目标对象在排队或传输期间发生变化") == true)
            #expect(await transport.putCount == 0)
            #expect(await transport.currentIdentity == changedIdentity)
        }
    }

    @Test func unversionedBucketKeepsOverwriteDisabledButStillAllowsSkipping() async throws {
        let source = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString)-unversioned.txt")
        try Data("test data".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let account = Self.account()
        let bucket = Self.bucket()
        let transport = UploadIdentityDriftTransport()
        let model = Self.model(account: account, bucket: bucket, transport: transport)
        model.settings.transferConflictPolicy = .ask

        model.upload(urls: [source], to: "", applyTemplate: false)
        try await Self.waitUntil { model.overwritePrompt != nil }

        #expect(model.overwritePrompt?.canOverwriteSafely == false)
        #expect(model.overwritePrompt?.message.contains("请先启用版本控制") == true)
        model.confirmOverwrite()
        #expect(model.overwritePrompt != nil)
        #expect(model.transfers.jobs.isEmpty)
        #expect(await transport.putCount == 0)

        model.skipOverwriteConflicts()
        try await Self.waitUntil { model.overwritePrompt == nil }
    }

    @Test func askPolicyPausesCloudCopyBeforeReplacingAnExistingObject() async {
        let account = Self.account()
        let bucket = Self.bucket()
        let transport = CloudConflictPromptTransport()
        let model = Self.model(account: account, bucket: bucket, transport: transport)
        model.settings.transferConflictPolicy = .ask
        let payload = CloudDragPayload(
            accountID: account.id,
            bucketName: bucket.name,
            sourceRegionID: bucket.regionID,
            objectKeys: ["source.txt"],
            folderPrefixes: []
        )

        let succeeded = await model.organizeCloud(payload, to: "archive/", mode: .copy)

        #expect(!succeeded)
        #expect(model.cloudConflictPrompt?.conflictKeys == ["archive/source.txt"])
        #expect(model.cloudConflictPrompt?.destinationAccountID == account.id)
        #expect(model.cloudConflictPrompt?.destinationBucketName == bucket.name)
        #expect(model.cloudConflictPrompt?.canReplaceSafely == false)
        #expect(await transport.methods == ["HEAD"])
    }

    private static func defaults() -> UserDefaults {
        let suite = "Ossuno.AppModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for AppModel state")
    }

    private static func account() -> OSSAccount {
        OSSAccount(
            id: UUID(),
            name: "Studio",
            accessKeyId: "test",
            regionID: "cn-hangzhou",
            endpointOverride: "",
            cdnDomain: "",
            defaultACL: .default,
            prefixTemplate: "",
            useTransferAccelerate: false,
            createdAt: .now
        )
    }

    private static func bucket() -> OSSBucket {
        OSSBucket(
            name: "design-assets",
            regionID: "cn-hangzhou",
            location: "oss-cn-hangzhou",
            extranetEndpoint: "oss-cn-hangzhou.aliyuncs.com",
            createdAt: nil
        )
    }

    private static func model(
        account: OSSAccount,
        bucket: OSSBucket,
        transport: any OSSHTTPTransport,
        versioningStatus: OSSBucketVersioningStatus = .disabled
    ) -> AppModel {
        let model = AppModel(kind: .settings, services: AppServices(accounts: [account])) { _, _ in
            OSSClient(
                credentials: OSSCredentials(
                    accessKeyId: "test",
                    accessKeySecret: "secret",
                    securityToken: nil
                ),
                region: bucket.regionID,
                endpointHost: bucket.extranetEndpoint,
                bucket: bucket.name,
                transport: transport,
                testingVersioningStatusOverride: versioningStatus
            )
        }
        model.selectedAccountID = account.id
        model.buckets = [bucket]
        model.selectedBucketName = bucket.name
        return model
    }
}

private enum UploadIdentityMutation: CaseIterable, Sendable {
    case etag
    case versionID
    case size
}

private actor UploadIdentityDriftTransport: OSSHTTPTransport {
    static let initialIdentity = OSSObjectIdentity(
        etag: "approved-etag",
        versionID: "version-1",
        size: 9
    )

    private(set) var currentIdentity = UploadIdentityDriftTransport.initialIdentity
    private(set) var putCount = 0

    func apply(_ mutation: UploadIdentityMutation) {
        switch mutation {
        case .etag:
            currentIdentity.etag = "changed-etag"
        case .versionID:
            currentIdentity.versionID = "version-2"
        case .size:
            currentIdentity.size += 1
        }
    }

    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        if request.httpMethod == "HEAD" {
            return OSSHTTPResult(
                status: 200,
                headers: [
                    "Content-Length": String(currentIdentity.size),
                    "ETag": "\"\(currentIdentity.etag)\"",
                    "x-oss-version-id": currentIdentity.versionID ?? ""
                ],
                data: Data(),
                temporaryDownloadURL: nil
            )
        }
        if request.httpMethod == "PUT" {
            putCount += 1
        }
        return OSSHTTPResult(
            status: 200,
            headers: [:],
            data: Data(),
            temporaryDownloadURL: nil
        )
    }
}

private actor AccountTestTransport: OSSHTTPTransport {
    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        let xml = """
        <ListAllMyBucketsResult><Buckets>
          <Bucket><Name>design-assets</Name><Location>oss-cn-hangzhou</Location></Bucket>
          <Bucket><Name>website</Name><Location>oss-cn-shanghai</Location></Bucket>
        </Buckets></ListAllMyBucketsResult>
        """
        return OSSHTTPResult(
            status: 200,
            headers: [:],
            data: Data(xml.utf8),
            temporaryDownloadURL: nil
        )
    }
}

private actor TruncatedListTransport: OSSHTTPTransport {
    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        let xml = """
        <ListBucketResult>
          <IsTruncated>true</IsTruncated>
          <Contents>
            <Key>huge/a.txt</Key><Size>1</Size><ETag>a</ETag><StorageClass>Standard</StorageClass>
          </Contents>
        </ListBucketResult>
        """
        return OSSHTTPResult(status: 200, headers: [:], data: Data(xml.utf8), temporaryDownloadURL: nil)
    }
}

private actor ConflictProbeTransport: OSSHTTPTransport {
    private(set) var headCount = 0

    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        if request.httpMethod == "GET" {
            let xml = """
            <ListBucketResult>
              <IsTruncated>true</IsTruncated>
              <Contents>
                <Key>file-1.txt</Key><Size>1</Size><ETag>a</ETag><StorageClass>Standard</StorageClass>
              </Contents>
            </ListBucketResult>
            """
            return OSSHTTPResult(status: 200, headers: [:], data: Data(xml.utf8), temporaryDownloadURL: nil)
        }
        headCount += 1
        if request.url?.path.hasSuffix("/file-1.txt") == true {
            return OSSHTTPResult(status: 200, headers: [:], data: Data(), temporaryDownloadURL: nil)
        }
        return OSSHTTPResult(
            status: 404,
            headers: [:],
            data: Data("<Error><Code>NoSuchKey</Code><Message>missing</Message></Error>".utf8),
            temporaryDownloadURL: nil
        )
    }
}

private actor CloudConflictPromptTransport: OSSHTTPTransport {
    private(set) var methods: [String] = []

    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        methods.append(request.httpMethod ?? "")
        return OSSHTTPResult(
            status: 200,
            headers: ["Content-Length": "1", "ETag": "existing"],
            data: Data(),
            temporaryDownloadURL: nil
        )
    }
}

private actor RecordingDeleteTransport: OSSHTTPTransport {
    private(set) var deletedKeys: [String] = []

    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        if request.httpMethod == "DELETE" {
            let path = request.url?.path ?? ""
            deletedKeys.append(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            return OSSHTTPResult(
                status: 204,
                headers: [:],
                data: Data(),
                temporaryDownloadURL: nil
            )
        }
        let xml = """
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <Contents>
            <Key>art/database.dump</Key><Size>84</Size><ETag>dump</ETag><StorageClass>Standard</StorageClass>
          </Contents>
        </ListBucketResult>
        """
        return OSSHTTPResult(
            status: 200,
            headers: [:],
            data: Data(xml.utf8),
            temporaryDownloadURL: nil
        )
    }
}

private actor SearchThenEmptyFolderTransport: OSSHTTPTransport {
    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        let xml: String
        if request.url?.query?.contains("delimiter") == true {
            xml = """
            <ListBucketResult>
              <IsTruncated>false</IsTruncated>
            </ListBucketResult>
            """
        } else {
            xml = """
            <ListBucketResult>
              <IsTruncated>false</IsTruncated>
              <Contents>
                <Key>art/database.dump</Key><Size>84</Size><ETag>dump</ETag><StorageClass>Standard</StorageClass>
              </Contents>
            </ListBucketResult>
            """
        }
        return OSSHTTPResult(
            status: 200,
            headers: [:],
            data: Data(xml.utf8),
            temporaryDownloadURL: nil
        )
    }
}

private actor BrowserSearchTransport: OSSHTTPTransport {
    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        let xml = """
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <Contents>
            <Key>art/hero.png</Key><Size>42</Size><ETag>hero</ETag><StorageClass>Standard</StorageClass>
          </Contents>
          <Contents>
            <Key>notes/readme.txt</Key><Size>12</Size><ETag>readme</ETag><StorageClass>Standard</StorageClass>
          </Contents>
          <Contents>
            <Key>art/database.dump</Key><Size>84</Size><ETag>dump</ETag><StorageClass>Standard</StorageClass>
          </Contents>
        </ListBucketResult>
        """
        return OSSHTTPResult(
            status: 200,
            headers: [:],
            data: Data(xml.utf8),
            temporaryDownloadURL: nil
        )
    }
}
