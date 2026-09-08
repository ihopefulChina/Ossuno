import Foundation
import Testing
@testable import Ossuno

@MainActor
struct BrowserModelTests {
    @Test func orderedSelectionIncludesFoldersBeforeObjects() {
        let model = Self.model()

        #expect(model.orderedVisibleKeys == ["folder/", "a.txt", "b.txt", "c.txt"])
    }

    @Test func contextMenuSelectsAnUnselectedItem() {
        let model = Self.model()
        model.select(key: "a.txt", modifiers: [])

        model.selectForContextMenu(key: "folder/")

        #expect(model.selectedKeys == ["folder/"])
        #expect(model.focusedKey == "folder/")
        #expect(model.selectionAnchorKey == "folder/")
    }

    @Test func contextMenuKeepsAMultipleSelectionWhenTheClickedItemIsAlreadySelected() {
        let model = Self.model()
        model.replaceSelection(["a.txt", "c.txt"])
        let epoch = model.selectionEpoch

        model.selectForContextMenu(key: "c.txt")

        #expect(model.selectedKeys == ["a.txt", "c.txt"])
        #expect(model.focusedKey == "c.txt")
        #expect(model.selectionEpoch > epoch)
    }

    @Test func contextMenuIgnoresKeysThatAreNotVisible() {
        let model = Self.model()
        model.select(key: "a.txt", modifiers: [])

        model.selectForContextMenu(key: "missing.txt")

        #expect(model.selectedKeys == ["a.txt"])
        #expect(model.focusedKey == "a.txt")
    }

    @Test func commandSelectionTogglesWithoutLosingOtherItems() {
        let model = Self.model()

        model.select(key: "a.txt", modifiers: [])
        model.select(key: "c.txt", modifiers: [.toggle])
        #expect(model.selectedKeys == ["a.txt", "c.txt"])
        model.select(key: "a.txt", modifiers: [.toggle])
        #expect(model.selectedKeys == ["c.txt"])
    }

    @Test func shiftSelectionUsesAStableAnchorAndVisibleRange() {
        let model = Self.model()

        model.select(key: "a.txt", modifiers: [])
        model.select(key: "c.txt", modifiers: [.extendRange])

        #expect(model.selectedKeys == ["a.txt", "b.txt", "c.txt"])
        #expect(model.focusedKey == "c.txt")
    }

    @Test func primaryObjectUsesVisibleOrderEvenWhenFolderIsSelected() {
        let model = Self.model()
        model.replaceSelection(["folder/", "b.txt", "c.txt"])

        #expect(model.primarySelection?.key == "b.txt")
    }

    @Test func primaryObjectFollowsTheFocusedSelectedFile() {
        let model = Self.model()
        model.replaceSelection(["b.txt", "c.txt"])
        model.selectForContextMenu(key: "c.txt")

        #expect(model.primarySelection?.key == "c.txt")
    }

    @Test func applyRecordsWhenTheListingWasTruncated() {
        let model = Self.model()
        model.apply(
            ObjectListing(
                folders: [OSSFolder(prefix: "folder/")],
                objects: [],
                isTruncated: true,
                nextToken: "next"
            ),
            imagesOnly: false
        )

        #expect(model.isListingTruncated)
    }

    @Test func movingSelectionFollowsDisplayedOrder() {
        let model = Self.model()
        model.select(key: "a.txt", modifiers: [])

        model.moveSelection(.next, extending: false)
        #expect(model.selectedKeys == ["b.txt"])
        model.moveSelection(.previous, extending: true)
        #expect(model.selectedKeys == ["a.txt", "b.txt"])
    }

    @Test func searchRemovesHiddenSelectionFocusAndAnchor() {
        let model = Self.model()
        model.select(key: "a.txt", modifiers: [])

        model.searchText = "b"

        #expect(model.selectedKeys.isEmpty)
        #expect(model.focusedKey == nil)
        #expect(model.selectionAnchorKey == nil)
        #expect(model.selectedObjects.isEmpty)
    }

    @Test func searchKeepsASelectionThatRemainsVisible() {
        let model = Self.model()
        model.select(key: "b.txt", modifiers: [])

        model.searchText = "b"

        #expect(model.selectedKeys == ["b.txt"])
        #expect(model.focusedKey == "b.txt")
        #expect(model.selectionAnchorKey == "b.txt")
    }

    @Test func navigatingToAnotherFolderClearsTheFolderSearch() {
        let model = Self.model()
        model.searchText = "b"

        model.navigate(to: "folder/")

        #expect(model.searchText.isEmpty)
        #expect(model.selectedKeys.isEmpty)
    }

    @Test func mediaFilterRemovesAnUnsupportedSelection() {
        let model = Self.model()
        model.objects.append(
            OSSObject(
                key: "runtime.bin",
                size: 1,
                etag: "bin",
                lastModified: nil,
                storageClass: "Standard"
            )
        )
        model.select(key: "runtime.bin", modifiers: [])

        model.imagesOnly = true

        #expect(model.selectedKeys.isEmpty)
        #expect(model.focusedKey == nil)
        #expect(model.selectionAnchorKey == nil)
    }

    @Test func transientSearchRevealSurvivesRefreshButClearsWhenTheFilterChanges() {
        let model = BrowserModel(defaults: Self.defaults())
        let object = OSSObject(
            key: "art/database.dump",
            size: 1,
            etag: "dump",
            lastModified: nil,
            storageClass: "Standard"
        )
        model.imagesOnly = true
        model.revealObjectTemporarily(object.key)

        model.apply(
            ObjectListing(
                folders: [],
                objects: [object],
                isTruncated: false,
                nextToken: nil
            ),
            imagesOnly: true
        )
        model.replaceSelection([object.key])

        #expect(model.visibleObjects.map(\.key) == [object.key])
        #expect(model.selectedKeys == [object.key])

        model.imagesOnly = false
        model.imagesOnly = true

        #expect(model.transientlyRevealedKey == nil)
        #expect(model.visibleObjects.isEmpty)
        #expect(model.selectedKeys.isEmpty)
    }

    @Test func refreshedListingRemovesASelectionThatNoLongerExists() {
        let model = Self.model()
        model.select(key: "a.txt", modifiers: [])

        model.apply(
            ObjectListing(
                folders: [],
                objects: [
                    OSSObject(
                        key: "b.txt",
                        size: 1,
                        etag: "b",
                        lastModified: nil,
                        storageClass: "Standard"
                    )
                ],
                isTruncated: false,
                nextToken: nil
            ),
            imagesOnly: false
        )

        #expect(model.selectedKeys.isEmpty)
        #expect(model.focusedKey == nil)
        #expect(model.selectionAnchorKey == nil)
    }

    @Test func hiddenClickedKeyCannotCreateACloudDragPayload() {
        let services = AppServices(accounts: [])
        let app = AppModel(kind: .settings, services: services)
        app.browser.imagesOnly = false
        app.browser.objects = [
            OSSObject(
                key: "hidden.txt",
                size: 1,
                etag: "hidden",
                lastModified: nil,
                storageClass: "Standard"
            )
        ]
        app.browser.searchText = "visible"

        let payload = app.cloudDragPayload(clickedKey: "hidden.txt")

        #expect(payload.objectKeys.isEmpty)
        #expect(payload.folderPrefixes.isEmpty)
    }

    @Test func sizeSortingKeepsFoldersFirstAndUsesTheRequestedDirection() {
        let model = BrowserModel(defaults: Self.defaults())
        model.imagesOnly = false
        model.folders = [
            OSSFolder(prefix: "alpha/"),
            OSSFolder(prefix: "zulu/")
        ]
        model.objects = [
            OSSObject(key: "small.txt", size: 1, etag: "s", lastModified: nil, storageClass: "Standard"),
            OSSObject(key: "large.txt", size: 100, etag: "l", lastModified: nil, storageClass: "Standard")
        ]
        model.sortField = .size
        model.sortDirection = .descending

        #expect(model.visibleFolders.map(\.prefix) == ["zulu/", "alpha/"])
        #expect(model.visibleObjects.map(\.key) == ["large.txt", "small.txt"])
        #expect(model.orderedVisibleKeys == ["zulu/", "alpha/", "large.txt", "small.txt"])
    }

    @Test func browserSortPreferencePersistsAcrossWindows() {
        let defaults = Self.defaults()
        let first = BrowserModel(defaults: defaults)
        first.sortField = .modified
        first.sortDirection = .descending

        let reopened = BrowserModel(defaults: defaults)

        #expect(reopened.sortField == .modified)
        #expect(reopened.sortDirection == .descending)
    }

    @Test func favoriteLocationsPersistAndDoNotDuplicate() {
        let defaults = Self.defaults()
        let accountID = UUID()
        let favorite = FavoriteLocation(
            accountID: accountID,
            bucketName: "assets",
            prefix: "design/icons/",
            name: "icons"
        )
        let store = FavoriteStore(defaults: defaults)

        store.add(favorite)
        store.add(favorite)

        #expect(store.items == [favorite])
        #expect(FavoriteStore(defaults: defaults).items == [favorite])
        store.remove(favorite)
        #expect(store.items.isEmpty)
    }

    @Test func movingAFolderUpdatesNestedFavoriteLocations() {
        let defaults = Self.defaults()
        let accountID = UUID()
        let store = FavoriteStore(defaults: defaults)
        store.add(.init(
            accountID: accountID,
            bucketName: "assets",
            prefix: "old/sub/",
            name: "sub"
        ))

        store.replacePrefix(
            accountID: accountID,
            bucketName: "assets",
            source: "old/",
            destination: "new/"
        )

        #expect(store.items.first?.prefix == "new/sub/")
    }

    @Test func movingAFolderAcrossBucketsRelocatesFavoriteLocations() {
        let defaults = Self.defaults()
        let sourceAccount = UUID()
        let destinationAccount = UUID()
        let store = FavoriteStore(defaults: defaults)
        store.add(.init(
            accountID: sourceAccount,
            bucketName: "assets",
            prefix: "photos/sub/",
            name: "sub"
        ))

        store.replacePrefix(
            accountID: sourceAccount,
            bucketName: "assets",
            source: "photos/",
            destination: "archive/photos/",
            destinationAccountID: destinationAccount,
            destinationBucketName: "archive"
        )

        #expect(store.items.first?.accountID == destinationAccount)
        #expect(store.items.first?.bucketName == "archive")
        #expect(store.items.first?.prefix == "archive/photos/sub/")
        #expect(store.items.first?.name == "sub")
    }

    @Test func skippedChildrenPreventRelocatingAFolderFavorite() {
        #expect(
            FavoriteStore.didMoveFolderCompletely(
                sourcePrefix: "photos/",
                originalSourceKeys: ["photos/a.jpg", "photos/b.jpg"],
                remainingSourceKeys: ["photos/a.jpg", "photos/b.jpg"]
            )
        )
        #expect(
            !FavoriteStore.didMoveFolderCompletely(
                sourcePrefix: "photos/",
                originalSourceKeys: ["photos/a.jpg", "photos/b.jpg"],
                remainingSourceKeys: ["photos/a.jpg"]
            )
        )
        #expect(
            !FavoriteStore.didMoveFolderCompletely(
                sourcePrefix: "photos/",
                originalSourceKeys: ["photos/a.jpg"],
                remainingSourceKeys: []
            )
        )
        #expect(
            FavoriteStore.didMoveFolderCompletely(
                sourcePrefix: "photos/",
                originalSourceKeys: ["cover.png", "photos/a.jpg"],
                remainingSourceKeys: ["photos/a.jpg"]
            )
        )
    }

    @Test func nativeTableSelectionKeepsAKeyboardFocusAndAnchor() {
        let model = Self.model()

        model.replaceSelection(["b.txt", "c.txt"])

        #expect(model.focusedKey == "b.txt")
        #expect(model.selectionAnchorKey == "b.txt")
        model.moveSelection(.next, extending: true)
        #expect(model.selectedKeys == ["b.txt", "c.txt"])
    }

    @Test func staleRequestContextCannotCommit() {
        let gate = BrowserRequestGate()
        let accountID = UUID()
        let stale = gate.begin(
            accountID: accountID,
            bucketName: "bucket",
            prefix: "old/",
            objectKey: nil
        )
        let current = gate.begin(
            accountID: accountID,
            bucketName: "bucket",
            prefix: "new/",
            objectKey: nil
        )

        #expect(!gate.canCommit(stale))
        #expect(gate.canCommit(current))
        gate.invalidate()
        #expect(!gate.canCommit(current))
    }

    @Test func staleListingResponseCannotOverwriteCurrentFolder() async throws {
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
        let bucket = OSSBucket(
            name: "bucket",
            regionID: "cn-hangzhou",
            location: "oss-cn-hangzhou",
            extranetEndpoint: "oss-cn-hangzhou.aliyuncs.com",
            createdAt: nil
        )
        let transport = DelayedBrowserTransport()
        let services = AppServices(accounts: [account])
        let model = AppModel(kind: .window, services: services) { _, selectedBucket in
            OSSClient(
                credentials: OSSCredentials(accessKeyId: "test", accessKeySecret: "secret", securityToken: nil),
                region: "cn-hangzhou",
                endpointHost: "oss-cn-hangzhou.aliyuncs.com",
                bucket: selectedBucket?.name,
                transport: transport,
                testingVersioningStatusOverride: .disabled
            )
        }
        model.selectedAccountID = account.id
        model.buckets = [bucket]
        model.selectedBucketName = bucket.name
        model.browser.prefix = "old/"

        let staleTask = Task { await model.refreshListing() }
        try await Self.waitForRequests(1, transport: transport)
        model.browser.prefix = "new/"
        let currentTask = Task { await model.refreshListing() }
        try await Self.waitForRequests(2, transport: transport)

        await transport.resume(
            index: 1,
            data: Self.listingXML(key: "new/current.txt")
        )
        await currentTask.value
        await transport.resume(
            index: 0,
            data: Self.listingXML(key: "old/stale.txt")
        )
        await staleTask.value

        #expect(model.browser.prefix == "new/")
        #expect(model.browser.objects.map(\.key) == ["new/current.txt"])
        #expect(!model.browser.isLoading)
    }

    @Test func incomingFilesAreQueuedUntilTheFirstWindowSessionExists() {
        let services = AppServices(accounts: [])
        let incoming = URL(fileURLWithPath: "/tmp/cold-launch.png")

        services.routeIncoming([incoming])
        let model = AppModel(kind: .window, services: services)

        #expect(model.pendingOpenURLs == [incoming])
    }

    @Test func closingQuickLookDeletesItsOwnedTemporaryFile() throws {
        let services = AppServices(accounts: [])
        let model = AppModel(kind: .settings, services: services)
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-quicklook-test-\(UUID().uuidString)")
        try Data("preview".utf8).write(to: temporary)

        model.presentPreview(at: temporary)
        model.previewItem = nil

        #expect(!FileManager.default.fileExists(atPath: temporary.path))
    }

    @Test func invalidObjectRenameReportsFailureWithoutSendingARequest() async {
        let transport = RenameResultTransport(steps: [])
        let fixture = Self.renameModel(transport: transport)

        let succeeded = await fixture.model.rename(fixture.object, to: "nested/name")

        #expect(!succeeded)
        #expect(fixture.model.banner?.isError == true)
        #expect(await transport.requestCount == 0)
    }

    @Test func invalidFolderRenameReportsFailureWithoutSendingARequest() async {
        let transport = RenameResultTransport(steps: [])
        let fixture = Self.renameModel(transport: transport)

        let succeeded = await fixture.model.renameFolder(
            OSSFolder(prefix: "folder/"),
            to: "nested/name"
        )

        #expect(!succeeded)
        #expect(fixture.model.banner?.isError == true)
        #expect(await transport.requestCount == 0)
    }

    @Test func objectRenameConflictKeepsSourceSelectionAndEditSession() async {
        var steps = Self.objectSnapshotSteps(etag: "old", versionID: "source-v1")
        steps.append(.response(status: 200, data: Data()))
        let transport = RenameResultTransport(steps: steps)
        let fixture = Self.renameModel(transport: transport)
        fixture.model.browser.replaceSelection([fixture.object.key])
        #expect(fixture.model.browser.beginRenaming())
        fixture.model.browser.updateRenameDraft("new.txt")

        let succeeded = await fixture.model.rename(fixture.object, to: "new.txt")

        #expect(!succeeded)
        #expect(fixture.model.browser.selectedKeys == [fixture.object.key])
        #expect(fixture.model.browser.renameSession?.draft == "new.txt")
        #expect(fixture.model.lastCloudUndoOperation == nil)
        #expect(await transport.methods == ["HEAD", "GET", "GET", "HEAD"])
    }

    @Test func successfulObjectRenameReturnsSuccessAndSelectsNewKey() async {
        let listing = Data("""
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <Contents>
            <Key>new.txt</Key><Size>1</Size><ETag>new</ETag><StorageClass>Standard</StorageClass>
          </Contents>
        </ListBucketResult>
        """.utf8)
        let transport = RenameResultTransport(
            steps: Self.successfulObjectRenameSteps(listing: listing)
        )
        let fixture = Self.renameModel(transport: transport)
        fixture.model.browser.replaceSelection([fixture.object.key])

        let succeeded = await fixture.model.rename(fixture.object, to: "new.txt")

        #expect(succeeded)
        #expect(fixture.model.browser.selectedKeys == ["new.txt"])
        let undo = fixture.model.lastCloudUndoOperation
        #expect(undo?.accountID == fixture.model.selectedAccountID!)
        #expect(undo?.bucketName == "bucket")
        #expect(undo?.title == "撤销重命名")
        #expect(undo?.mappings == [
            CloudObjectMapping(sourceKey: "old.txt", destinationKey: "new.txt")
        ])
        #expect(undo?.favoriteMoves == [])
        #expect(undo?.sourceSelection == ["old.txt"])
        #expect(undo?.destinationSelection == ["new.txt"])
        #expect(undo?.hasCompleteDestinationIdentities == true)
        #expect(fixture.model.banner?.action == .undoCloudOperation)
        #expect(await transport.methods == [
            "HEAD", "GET", "GET", "HEAD", "PUT", "HEAD",
            "HEAD", "GET", "GET", "DELETE", "GET"
        ])
    }

    @Test func successfulFolderRenameRecordsExactMappingsAndFavoriteMove() async {
        let sourceListing = Data("""
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <Contents>
            <Key>folder/素材 2x.png</Key><Size>1</Size><ETag>old</ETag><StorageClass>Standard</StorageClass>
          </Contents>
        </ListBucketResult>
        """.utf8)
        let refreshedListing = Data("""
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <CommonPrefixes><Prefix>renamed/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """.utf8)
        var steps: [RenameResultTransport.Step] = [
            .response(status: 200, data: sourceListing),
            .response(status: 404, data: Data())
        ]
        steps.append(contentsOf: Self.objectSnapshotSteps(etag: "old", versionID: "folder-source-v1"))
        steps.append(contentsOf: Self.committedCopySteps(etag: "folder-moved", versionID: "folder-destination-v1"))
        steps.append(contentsOf: Self.objectSnapshotSteps(etag: "old", versionID: "folder-source-v1"))
        steps.append(.response(status: 204, data: Data()))
        steps.append(.response(status: 200, data: refreshedListing))
        let transport = RenameResultTransport(steps: steps)
        let fixture = Self.renameModel(transport: transport)
        let accountID = fixture.model.selectedAccountID!
        fixture.model.browser.folders = [OSSFolder(prefix: "folder/")]
        fixture.model.favorites.add(FavoriteLocation(
            accountID: accountID,
            bucketName: "bucket",
            prefix: "folder/nested/",
            name: "nested"
        ))

        let succeeded = await fixture.model.renameFolder(
            OSSFolder(prefix: "folder/"),
            to: "renamed"
        )

        #expect(succeeded)
        #expect(fixture.model.browser.selectedKeys == ["renamed/"])
        #expect(fixture.model.favorites.items.first?.prefix == "renamed/nested/")
        let undo = fixture.model.lastCloudUndoOperation
        #expect(undo?.accountID == accountID)
        #expect(undo?.bucketName == "bucket")
        #expect(undo?.title == "撤销重命名")
        #expect(undo?.mappings == [
            CloudObjectMapping(
                sourceKey: "folder/素材 2x.png",
                destinationKey: "renamed/素材 2x.png"
            )
        ])
        #expect(undo?.favoriteMoves == [
            CloudFavoriteMove(sourcePrefix: "folder/", destinationPrefix: "renamed/")
        ])
        #expect(undo?.sourceSelection == ["folder/"])
        #expect(undo?.destinationSelection == ["renamed/"])
        #expect(undo?.hasCompleteDestinationIdentities == true)
        #expect(fixture.model.banner?.action == .undoCloudOperation)
        #expect(await transport.methods == [
            "GET", "HEAD", "HEAD", "GET", "GET", "PUT", "HEAD",
            "HEAD", "GET", "GET", "DELETE", "GET"
        ])
    }

    @Test func successfulMoveRecordsExactScopeMappingAndSelections() async {
        var steps: [RenameResultTransport.Step] = [
            .response(status: 404, data: Data()),
            .response(status: 404, data: Data())
        ]
        steps.append(contentsOf: Self.objectSnapshotSteps(etag: "old", versionID: "source-v1"))
        steps.append(contentsOf: Self.committedCopySteps(etag: "moved", versionID: "destination-v1"))
        steps.append(contentsOf: Self.objectSnapshotSteps(etag: "old", versionID: "source-v1"))
        steps.append(.response(status: 204, data: Data()))
        steps.append(.response(status: 200, data: Self.listingXML(key: "archive/old.txt")))
        let transport = RenameResultTransport(steps: steps)
        let fixture = Self.renameModel(transport: transport)
        let accountID = fixture.model.selectedAccountID!
        fixture.model.browser.prefix = "archive/"
        let payload = CloudDragPayload(
            accountID: accountID,
            bucketName: "bucket",
            objectKeys: ["old.txt"],
            folderPrefixes: []
        )

        await fixture.model.organizeCloud(payload, to: "archive/", mode: .move)

        let undo = fixture.model.lastCloudUndoOperation
        #expect(undo?.accountID == accountID)
        #expect(undo?.bucketName == "bucket")
        #expect(undo?.title == "撤销移动")
        #expect(undo?.mappings == [
            CloudObjectMapping(sourceKey: "old.txt", destinationKey: "archive/old.txt")
        ])
        #expect(undo?.favoriteMoves == [])
        #expect(undo?.sourceSelection == ["old.txt"])
        #expect(undo?.destinationSelection == ["archive/old.txt"])
        #expect(undo?.hasCompleteDestinationIdentities == true)
        #expect(fixture.model.browser.selectedKeys == ["archive/old.txt"])
        #expect(fixture.model.banner?.action == .undoCloudOperation)
        #expect(await transport.methods == [
            "HEAD", "HEAD", "HEAD", "GET", "GET", "PUT", "HEAD",
            "HEAD", "GET", "GET", "DELETE", "GET"
        ])
    }

    @Test func successfulCopyDoesNotReplaceTheLastReversibleOperation() async {
        var steps = Self.successfulObjectRenameSteps(
            listing: Self.listingXML(key: "new.txt")
        )
        steps.append(.response(status: 404, data: Data()))
        steps.append(.response(status: 404, data: Data()))
        steps.append(contentsOf: Self.objectSnapshotSteps(etag: "moved", versionID: "destination-v1"))
        steps.append(contentsOf: Self.committedCopySteps(etag: "copied", versionID: "copy-v1"))
        steps.append(.response(status: 200, data: Self.listingXML(key: "copies/new.txt")))
        let transport = RenameResultTransport(steps: steps)
        let fixture = Self.renameModel(transport: transport)
        #expect(await fixture.model.rename(fixture.object, to: "new.txt"))
        let renameUndo = fixture.model.lastCloudUndoOperation
        fixture.model.browser.prefix = "copies/"
        let payload = CloudDragPayload(
            accountID: fixture.model.selectedAccountID!,
            bucketName: "bucket",
            objectKeys: ["new.txt"],
            folderPrefixes: []
        )

        await fixture.model.organizeCloud(payload, to: "copies/", mode: .copy)

        #expect(fixture.model.lastCloudUndoOperation == renameUndo)
        #expect(fixture.model.banner?.action == nil)
        #expect(await transport.methods == [
            "HEAD", "GET", "GET", "HEAD", "PUT", "HEAD",
            "HEAD", "GET", "GET", "DELETE", "GET",
            "HEAD", "HEAD", "HEAD", "GET", "GET", "PUT", "HEAD", "GET"
        ])
    }

    @Test func replaceCopyPreservesTheOriginalDestinationWhenCopyFails() async {
        let serviceError = Data(
            "<Error><Code>AccessDenied</Code><Message>denied</Message><RequestId>r1</RequestId></Error>".utf8
        )
        let originalHead = RenameResultTransport.Step.responseWithHeaders(
            status: 200,
            headers: [
                "Content-Length": "7",
                "ETag": "\"original\"",
                "x-oss-storage-class": "Standard",
                "x-oss-version-id": "original-v1"
            ],
            data: Data()
        )
        var steps = [originalHead]
        steps.append(contentsOf: Self.objectSnapshotSteps(
            etag: "original",
            versionID: "original-v1",
            size: 7
        ))
        // The operation owns the random rollback key and writes it explicitly.
        steps.append(.responseWithHeaders(
            status: 200,
            headers: ["x-oss-version-id": "backup-v1"],
            data: Data()
        ))
        // Batch preflight still sees the exact original destination.
        steps.append(originalHead)
        steps.append(contentsOf: Self.objectSnapshotSteps(etag: "source", versionID: "source-v1"))
        // The last network operation before the replacing COPY revalidates the destination.
        steps.append(originalHead)
        steps.append(.response(status: 403, data: serviceError))
        steps.append(.response(status: 204, data: Data()))
        let transport = RenameResultTransport(steps: steps)
        let fixture = Self.renameModel(transport: transport)
        fixture.model.settings.transferConflictPolicy = .replace
        let payload = CloudDragPayload(
            accountID: fixture.model.selectedAccountID!,
            bucketName: "bucket",
            objectKeys: ["source.txt"],
            folderPrefixes: []
        )

        let succeeded = await fixture.model.organizeCloud(
            payload,
            to: "archive/",
            mode: .copy
        )

        #expect(!succeeded)
        #expect(fixture.model.banner?.text.contains("denied") == true)
        let methods = await transport.methods
        #expect(methods == [
            "HEAD", "HEAD", "GET", "GET", "PUT",
            "HEAD", "HEAD", "GET", "GET", "HEAD", "PUT", "DELETE"
        ])
        let requests = await transport.recordedRequests()
        #expect(requests.last?.url?.path.contains(".ossuno-rollback") == true)
        #expect(!requests.contains { $0.httpMethod == "DELETE" && $0.url?.path.hasSuffix("/source.txt") == true })
    }

    @Test func successfulUndoMovesTheObjectBackAndClearsTheRecord() async {
        var steps = Self.successfulObjectRenameSteps(
            listing: Self.listingXML(key: "new.txt")
        )
        steps.append(.response(status: 404, data: Data()))
        steps.append(contentsOf: Self.objectSnapshotSteps(etag: "moved", versionID: "destination-v1"))
        steps.append(contentsOf: Self.committedCopySteps(etag: "restored", versionID: "undo-v1"))
        steps.append(contentsOf: Self.objectSnapshotSteps(etag: "moved", versionID: "destination-v1"))
        steps.append(.response(status: 204, data: Data()))
        steps.append(.response(status: 200, data: Self.listingXML(key: "old.txt")))
        let transport = RenameResultTransport(steps: steps)
        let fixture = Self.renameModel(transport: transport)
        #expect(await fixture.model.rename(fixture.object, to: "new.txt"))
        #expect(fixture.model.canUndoCloudOperation)
        #expect(fixture.model.undoCloudOperationTitle == "撤销重命名")

        await fixture.model.undoLastCloudOperation()

        #expect(fixture.model.lastCloudUndoOperation == nil)
        #expect(fixture.model.browser.selectedKeys == ["old.txt"])
        #expect(!fixture.model.canUndoCloudOperation)
        #expect(await transport.methods == [
            "HEAD", "GET", "GET", "HEAD", "PUT", "HEAD",
            "HEAD", "GET", "GET", "DELETE", "GET",
            "HEAD", "HEAD", "GET", "GET", "PUT", "HEAD",
            "HEAD", "GET", "GET", "DELETE", "GET"
        ])
    }

    @Test func undoRefusesAChangedDestinationBeforeAnyCopyOrDelete() async {
        var steps = Self.successfulObjectRenameSteps(
            listing: Self.listingXML(key: "new.txt")
        )
        steps.append(.response(status: 404, data: Data()))
        steps.append(contentsOf: Self.objectSnapshotSteps(
            etag: "concurrent",
            versionID: "destination-v2"
        ))
        let transport = RenameResultTransport(steps: steps)
        let fixture = Self.renameModel(transport: transport)
        #expect(await fixture.model.rename(fixture.object, to: "new.txt"))
        let recorded = fixture.model.lastCloudUndoOperation
        let requestCountBeforeUndo = await transport.requestCount

        await fixture.model.undoLastCloudOperation()

        let allRequests = await transport.recordedRequests()
        let undoRequests = Array(allRequests.dropFirst(requestCountBeforeUndo))
        #expect(fixture.model.lastCloudUndoOperation == recorded)
        #expect(fixture.model.canUndoCloudOperation)
        #expect(fixture.model.banner?.isError == true)
        #expect(fixture.model.banner?.text.contains("发生变化") == true)
        #expect(!undoRequests.contains { request in
            request.httpMethod == "PUT" || request.httpMethod == "DELETE"
        })
        #expect(undoRequests.map { $0.httpMethod ?? "" } == ["HEAD", "HEAD", "GET", "GET"])
    }

    @Test func versionedDeleteCanUndoByRemovingTheExactDeleteMarker() async throws {
        let emptyListing = Data("<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>".utf8)
        let transport = RenameResultTransport(steps: [
            .responseWithHeaders(
                status: 204,
                headers: [
                    "x-oss-delete-marker": "true",
                    "x-oss-version-id": "marker-version-7"
                ],
                data: Data()
            ),
            .response(status: 200, data: emptyListing),
            .response(status: 204, data: Data()),
            .response(status: 200, data: Self.listingXML(key: "old.txt"))
        ])
        let fixture = Self.renameModel(transport: transport)
        fixture.model.browser.replaceSelection([fixture.object.key])

        await fixture.model.deleteSelection()

        #expect(fixture.model.lastDeleteUndoOperation == CloudDeleteUndoOperation(
            accountID: fixture.model.selectedAccountID!,
            bucketName: "bucket",
            title: "撤销删除",
            markers: [OSSDeleteMarker(key: "old.txt", versionID: "marker-version-7")],
            sourceSelection: ["old.txt"]
        ))
        #expect(fixture.model.canUndoCloudOperation)
        #expect(fixture.model.banner?.action == .undoCloudOperation)

        await fixture.model.undoLastCloudOperation()

        #expect(fixture.model.lastDeleteUndoOperation == nil)
        #expect(fixture.model.browser.selectedKeys == ["old.txt"])
        let requests = await transport.recordedRequests()
        #expect(requests.map { $0.httpMethod ?? "" } == ["DELETE", "GET", "DELETE", "GET"])
        #expect(requests[2].url?.query == "versionId=marker-version-7")
    }

    @Test func partiallyCompletedDeleteKeepsExactUndoReceiptsAndRefreshes() async {
        let forbidden = Data(
            "<Error><Code>AccessDenied</Code><Message>Denied</Message><RequestId>delete</RequestId></Error>".utf8
        )
        let emptyListing = Data("<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>".utf8)
        let transport = RenameResultTransport(steps: [
            .responseWithHeaders(
                status: 204,
                headers: [
                    "x-oss-delete-marker": "true",
                    "x-oss-version-id": "partial-marker-1"
                ],
                data: Data()
            ),
            .response(status: 403, data: forbidden),
            .response(status: 200, data: emptyListing)
        ])
        let fixture = Self.renameModel(transport: transport)
        let untouched = OSSObject(
            key: "untouched.txt",
            size: 1,
            etag: "untouched",
            lastModified: nil,
            storageClass: "Standard"
        )
        fixture.model.browser.objects.append(untouched)
        fixture.model.browser.replaceSelection([fixture.object.key, untouched.key])

        await fixture.model.deleteSelection()

        #expect(fixture.model.lastDeleteUndoOperation?.markers == [
            OSSDeleteMarker(key: fixture.object.key, versionID: "partial-marker-1")
        ])
        #expect(fixture.model.lastDeleteUndoOperation?.sourceSelection == [fixture.object.key])
        #expect(fixture.model.banner?.isError == true)
        #expect(fixture.model.banner?.action == .undoCloudOperation)
        #expect(fixture.model.banner?.text.contains("已删除 1 个对象") == true)
        #expect(await transport.methods == ["DELETE", "DELETE", "GET"])
    }

    @Test func failedDeleteKeepsThePreviousUndoRecord() async {
        var steps = Self.successfulObjectRenameSteps(
            listing: Self.listingXML(key: "new.txt")
        )
        steps.append(.response(status: 403, data: Data(
            "<Error><Code>AccessDenied</Code><Message>Denied</Message><RequestId>delete</RequestId></Error>".utf8
        )))
        let transport = RenameResultTransport(steps: steps)
        let fixture = Self.renameModel(transport: transport)
        #expect(await fixture.model.rename(fixture.object, to: "new.txt"))
        let recorded = fixture.model.lastCloudUndoOperation
        fixture.model.browser.replaceSelection(["new.txt"])

        await fixture.model.deleteSelection()

        #expect(fixture.model.lastCloudUndoOperation == recorded)
        #expect(fixture.model.lastDeleteUndoOperation == nil)
        #expect(fixture.model.canUndoCloudOperation)
        #expect(fixture.model.banner?.isError == true)
        #expect(await transport.methods == [
            "HEAD", "GET", "GET", "HEAD", "PUT", "HEAD",
            "HEAD", "GET", "GET", "DELETE", "GET", "DELETE"
        ])
    }

    @Test func switchingAccountDuringOpenFavoriteDoesNotRemoveTheFavorite() async throws {
        let accountA = OSSAccount(
            id: UUID(),
            name: "A",
            accessKeyId: "a",
            regionID: "cn-hangzhou",
            endpointOverride: "",
            cdnDomain: "",
            defaultACL: .default,
            prefixTemplate: "",
            useTransferAccelerate: false,
            createdAt: .now
        )
        let accountB = OSSAccount(
            id: UUID(),
            name: "B",
            accessKeyId: "b",
            regionID: "cn-hangzhou",
            endpointOverride: "",
            cdnDomain: "",
            defaultACL: .default,
            prefixTemplate: "",
            useTransferAccelerate: false,
            createdAt: .now
        )
        let transport = DelayedBrowserTransport()
        let services = AppServices(
            accounts: [accountA, accountB],
            favorites: FavoriteStore(defaults: Self.defaults())
        )
        let model = AppModel(kind: .settings, services: services) { _, selectedBucket in
            OSSClient(
                credentials: OSSCredentials(
                    accessKeyId: "test",
                    accessKeySecret: "secret",
                    securityToken: nil
                ),
                region: "cn-hangzhou",
                endpointHost: "oss-cn-hangzhou.aliyuncs.com",
                bucket: selectedBucket?.name,
                transport: transport,
                testingVersioningStatusOverride: .disabled
            )
        }
        model.selectedAccountID = accountA.id
        model.buckets = []
        let favorite = FavoriteLocation(
            accountID: accountA.id,
            bucketName: "photos",
            prefix: "art/",
            name: "艺术"
        )
        model.favorites.add(favorite)

        model.openFavorite(favorite)
        try await Self.waitForRequests(1, transport: transport)
        model.selectedAccountID = accountB.id
        model.buckets = [
            OSSBucket(
                name: "other",
                regionID: "cn-hangzhou",
                location: "oss-cn-hangzhou",
                extranetEndpoint: "oss-cn-hangzhou.aliyuncs.com",
                createdAt: nil
            )
        ]
        await transport.resume(
            index: 0,
            data: Data("""
            <ListAllMyBucketsResult><Buckets>
              <Bucket><Name>photos</Name><Location>oss-cn-hangzhou</Location></Bucket>
            </Buckets></ListAllMyBucketsResult>
            """.utf8)
        )
        try await Task.sleep(for: .milliseconds(40))

        #expect(model.favorites.items.contains(where: { $0.id == favorite.id }))
        #expect(model.selectedAccountID == accountB.id)
    }

    @Test func undoConflictKeepsTheRecordAvailableForRetry() async {
        var steps = Self.successfulObjectRenameSteps(
            listing: Self.listingXML(key: "new.txt")
        )
        steps.append(.response(status: 200, data: Data()))
        let transport = RenameResultTransport(steps: steps)
        let fixture = Self.renameModel(transport: transport)
        #expect(await fixture.model.rename(fixture.object, to: "new.txt"))
        let recorded = fixture.model.lastCloudUndoOperation

        await fixture.model.undoLastCloudOperation()

        #expect(fixture.model.lastCloudUndoOperation == recorded)
        #expect(fixture.model.canUndoCloudOperation)
        #expect(fixture.model.banner?.isError == true)
        #expect(await transport.methods == [
            "HEAD", "GET", "GET", "HEAD", "PUT", "HEAD",
            "HEAD", "GET", "GET", "DELETE", "GET", "HEAD"
        ])
    }

    @Test func undoOutsideItsBucketPerformsNoRequestAndBecomesDisabled() async {
        let transport = RenameResultTransport(
            steps: Self.successfulObjectRenameSteps(
                listing: Self.listingXML(key: "new.txt")
            )
        )
        let fixture = Self.renameModel(transport: transport)
        #expect(await fixture.model.rename(fixture.object, to: "new.txt"))
        let recorded = fixture.model.lastCloudUndoOperation
        fixture.model.buckets.append(OSSBucket(
            name: "another-bucket",
            regionID: "cn-hangzhou",
            location: "oss-cn-hangzhou",
            extranetEndpoint: "oss-cn-hangzhou.aliyuncs.com",
            createdAt: nil
        ))
        fixture.model.selectedBucketName = "another-bucket"

        #expect(!fixture.model.canUndoCloudOperation)
        #expect(fixture.model.undoCloudOperationTitle == "撤销")
        await fixture.model.undoLastCloudOperation()

        #expect(fixture.model.lastCloudUndoOperation == recorded)
        #expect(await transport.methods == [
            "HEAD", "GET", "GET", "HEAD", "PUT", "HEAD",
            "HEAD", "GET", "GET", "DELETE", "GET"
        ])
    }

    @Test func undoFolderRenameRestoresNestedFavoriteLocations() async {
        let sourceListing = Data("""
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <Contents>
            <Key>folder/item.txt</Key><Size>1</Size><ETag>old</ETag><StorageClass>Standard</StorageClass>
          </Contents>
        </ListBucketResult>
        """.utf8)
        let renamedListing = Data("""
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <CommonPrefixes><Prefix>renamed/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """.utf8)
        let restoredListing = Data("""
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <CommonPrefixes><Prefix>folder/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """.utf8)
        var steps: [RenameResultTransport.Step] = [
            .response(status: 200, data: sourceListing),
            .response(status: 404, data: Data())
        ]
        steps.append(contentsOf: Self.objectSnapshotSteps(etag: "old", versionID: "folder-source-v1"))
        steps.append(contentsOf: Self.committedCopySteps(etag: "folder-moved", versionID: "folder-destination-v1"))
        steps.append(contentsOf: Self.objectSnapshotSteps(etag: "old", versionID: "folder-source-v1"))
        steps.append(.response(status: 204, data: Data()))
        steps.append(.response(status: 200, data: renamedListing))
        steps.append(.response(status: 404, data: Data()))
        steps.append(contentsOf: Self.objectSnapshotSteps(
            etag: "folder-moved",
            versionID: "folder-destination-v1"
        ))
        steps.append(contentsOf: Self.committedCopySteps(
            etag: "folder-restored",
            versionID: "folder-undo-v1"
        ))
        steps.append(contentsOf: Self.objectSnapshotSteps(
            etag: "folder-moved",
            versionID: "folder-destination-v1"
        ))
        steps.append(.response(status: 204, data: Data()))
        steps.append(.response(status: 200, data: restoredListing))
        let transport = RenameResultTransport(steps: steps)
        let fixture = Self.renameModel(transport: transport)
        let accountID = fixture.model.selectedAccountID!
        fixture.model.browser.folders = [OSSFolder(prefix: "folder/")]
        fixture.model.favorites.add(FavoriteLocation(
            accountID: accountID,
            bucketName: "bucket",
            prefix: "folder/nested/",
            name: "nested"
        ))
        #expect(await fixture.model.renameFolder(OSSFolder(prefix: "folder/"), to: "renamed"))
        #expect(fixture.model.lastCloudUndoOperation?.favoriteMoves == [
            CloudFavoriteMove(sourcePrefix: "folder/", destinationPrefix: "renamed/")
        ])
        #expect(fixture.model.lastCloudUndoOperation?.inverseFavoriteMoves == [
            CloudFavoriteMove(sourcePrefix: "renamed/", destinationPrefix: "folder/")
        ])
        #expect(fixture.model.favorites.contains(
            accountID: accountID,
            bucketName: "bucket",
            prefix: "renamed/nested/"
        ))

        await fixture.model.undoLastCloudOperation()

        #expect(fixture.model.favorites.contains(
            accountID: accountID,
            bucketName: "bucket",
            prefix: "folder/nested/"
        ))
        #expect(!fixture.model.favorites.contains(
            accountID: accountID,
            bucketName: "bucket",
            prefix: "renamed/nested/"
        ))
        #expect(fixture.model.browser.selectedKeys == ["folder/"])
        #expect(await transport.methods == [
            "GET", "HEAD", "HEAD", "GET", "GET", "PUT", "HEAD",
            "HEAD", "GET", "GET", "DELETE", "GET",
            "HEAD", "HEAD", "GET", "GET", "PUT", "HEAD",
            "HEAD", "GET", "GET", "DELETE", "GET"
        ])
    }

    private static func model() -> BrowserModel {
        let model = BrowserModel(defaults: defaults())
        model.folders = [OSSFolder(prefix: "folder/")]
        model.objects = [
            OSSObject(key: "a.txt", size: 1, etag: "a", lastModified: nil, storageClass: "Standard"),
            OSSObject(key: "b.txt", size: 1, etag: "b", lastModified: nil, storageClass: "Standard"),
            OSSObject(key: "c.txt", size: 1, etag: "c", lastModified: nil, storageClass: "Standard")
        ]
        model.imagesOnly = false
        return model
    }

    private static func defaults() -> UserDefaults {
        let suite = "OssunoTests.BrowserModel.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private static func renameModel(
        transport: RenameResultTransport
    ) -> (model: AppModel, object: OSSObject) {
        let account = OSSAccount(
            id: UUID(),
            name: "Rename Test",
            accessKeyId: "test",
            regionID: "cn-hangzhou",
            endpointOverride: "",
            cdnDomain: "",
            defaultACL: .private,
            prefixTemplate: "",
            useTransferAccelerate: false,
            createdAt: .now
        )
        let bucket = OSSBucket(
            name: "bucket",
            regionID: "cn-hangzhou",
            location: "oss-cn-hangzhou",
            extranetEndpoint: "oss-cn-hangzhou.aliyuncs.com",
            createdAt: nil
        )
        let object = OSSObject(
            key: "old.txt",
            size: 1,
            etag: "old",
            lastModified: nil,
            storageClass: "Standard"
        )
        let services = AppServices(
            accounts: [account],
            favorites: FavoriteStore(defaults: defaults())
        )
        let model = AppModel(kind: .settings, services: services) { _, selectedBucket in
            OSSClient(
                credentials: OSSCredentials(
                    accessKeyId: "test",
                    accessKeySecret: "secret",
                    securityToken: nil
                ),
                region: "cn-hangzhou",
                endpointHost: "oss-cn-hangzhou.aliyuncs.com",
                bucket: selectedBucket?.name,
                transport: transport,
                testingVersioningStatusOverride: .enabled
            )
        }
        model.selectedAccountID = account.id
        model.buckets = [bucket]
        model.selectedBucketName = bucket.name
        model.browser.objects = [object]
        model.browser.imagesOnly = false
        return (model, object)
    }

    private static func waitForRequests(
        _ count: Int,
        transport: DelayedBrowserTransport
    ) async throws {
        for _ in 0..<100 {
            if await transport.requestCount == count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(count) requests")
    }

    private static func listingXML(key: String) -> Data {
        Data("""
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <Contents>
            <Key>\(key)</Key><Size>1</Size><ETag>etag</ETag><StorageClass>Standard</StorageClass>
          </Contents>
        </ListBucketResult>
        """.utf8)
    }

    private static func objectSnapshotSteps(
        etag: String,
        versionID: String,
        size: Int64 = 1
    ) -> [RenameResultTransport.Step] {
        [
            .responseWithHeaders(
                status: 200,
                headers: [
                    "Content-Length": String(size),
                    "ETag": "\"\(etag)\"",
                    "x-oss-storage-class": "Standard",
                    "x-oss-version-id": versionID
                ],
                data: Data()
            ),
            .response(
                status: 200,
                data: Data("""
                <AccessControlPolicy>
                  <AccessControlList><Grant>private</Grant></AccessControlList>
                </AccessControlPolicy>
                """.utf8)
            ),
            .response(
                status: 200,
                data: Data("<Tagging><TagSet></TagSet></Tagging>".utf8)
            )
        ]
    }

    private static func committedCopySteps(
        etag: String,
        versionID: String,
        size: Int64 = 1
    ) -> [RenameResultTransport.Step] {
        [
            .responseWithHeaders(
                status: 200,
                headers: ["x-oss-version-id": versionID],
                data: Data()
            ),
            .responseWithHeaders(
                status: 200,
                headers: [
                    "Content-Length": String(size),
                    "ETag": "\"\(etag)\"",
                    "x-oss-storage-class": "Standard",
                    "x-oss-version-id": versionID
                ],
                data: Data()
            )
        ]
    }

    private static func successfulObjectRenameSteps(
        listing: Data,
        sourceETag: String = "old",
        sourceVersionID: String = "source-v1",
        destinationETag: String = "moved",
        destinationVersionID: String = "destination-v1"
    ) -> [RenameResultTransport.Step] {
        var steps = objectSnapshotSteps(etag: sourceETag, versionID: sourceVersionID)
        steps.append(.response(status: 404, data: Data()))
        steps.append(contentsOf: committedCopySteps(
            etag: destinationETag,
            versionID: destinationVersionID
        ))
        steps.append(contentsOf: objectSnapshotSteps(
            etag: sourceETag,
            versionID: sourceVersionID
        ))
        steps.append(.response(status: 204, data: Data()))
        steps.append(.response(status: 200, data: listing))
        return steps
    }
}

private actor RenameResultTransport: OSSHTTPTransport {
    enum Step: Sendable {
        case response(status: Int, data: Data)
        case responseWithHeaders(status: Int, headers: [String: String], data: Data)
    }

    private var steps: [Step]
    private var requests: [URLRequest] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    var requestCount: Int { requests.count }
    var methods: [String] { requests.map { $0.httpMethod ?? "" } }

    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        requests.append(request)
        guard !steps.isEmpty else {
            throw OSSServiceError(
                statusCode: 0,
                code: "MissingStub",
                message: "Missing rename response",
                requestId: ""
            )
        }
        switch steps.removeFirst() {
        case .response(let status, let data):
            return OSSHTTPResult(
                status: status,
                headers: [:],
                data: data,
                temporaryDownloadURL: nil
            )
        case .responseWithHeaders(let status, let headers, let data):
            return OSSHTTPResult(
                status: status,
                headers: headers,
                data: data,
                temporaryDownloadURL: nil
            )
        }
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

private actor DelayedBrowserTransport: OSSHTTPTransport {
    private var continuations: [CheckedContinuation<OSSHTTPResult, Never>] = []

    var requestCount: Int { continuations.count }

    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resume(index: Int, data: Data) {
        continuations[index].resume(
            returning: OSSHTTPResult(
                status: 200,
                headers: [:],
                data: data,
                temporaryDownloadURL: nil
            )
        )
    }
}
