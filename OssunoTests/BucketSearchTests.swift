import Foundation
import Testing
@testable import Ossuno

struct BucketSearchTests {
    private let accountID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func queryMatchesTheFullKeyCaseInsensitivelyAndAppliesFilters() {
        let query = BucketSearchQuery(
            accountID: accountID,
            bucketName: "demo",
            text: "hero",
            filter: BucketSearchFilter(
                kind: .images,
                minimumSize: 100,
                maximumSize: nil,
                modified: .any
            )
        )
        let object = OSSObject(
            key: "assets/Hero.PNG",
            size: 200,
            etag: "etag",
            lastModified: now,
            storageClass: "Standard"
        )

        #expect(query.matches(object, now: now))
    }

    @Test func largeQueryUsesTheExactOneHundredMegabyteBoundary() {
        let query = BucketSearchQuery(
            accountID: accountID,
            bucketName: "demo",
            text: "",
            filter: .largeObjects
        )

        #expect(query.matches(object(key: "large.bin", size: 104_857_600), now: now))
        #expect(!query.matches(object(key: "small.bin", size: 104_857_599), now: now))
    }

    @Test func recentQueryRejectsObjectsOlderThanSevenDaysAndUnknownDates() {
        let query = BucketSearchQuery(
            accountID: accountID,
            bucketName: "demo",
            text: "",
            filter: .recentObjects(days: 7)
        )
        let recent = object(key: "recent.txt", modified: now.addingTimeInterval(-6 * 86_400))
        let old = object(key: "old.txt", modified: now.addingTimeInterval(-8 * 86_400))
        let unknown = object(key: "unknown.txt", modified: nil)

        #expect(query.matches(recent, now: now))
        #expect(!query.matches(old, now: now))
        #expect(!query.matches(unknown, now: now))
    }

    @Test func folderPlaceholdersNeverAppearAsFileResults() {
        let query = BucketSearchQuery(
            accountID: accountID,
            bucketName: "demo",
            text: "folder",
            filter: .all
        )

        #expect(!query.matches(object(key: "folder/"), now: now))
    }

    @Test func cacheIdentityIncludesBucketAndEveryFilterBoundary() {
        let base = BucketSearchQuery(
            accountID: accountID,
            bucketName: "one",
            text: "hero",
            filter: .all
        )
        let otherBucket = BucketSearchQuery(
            accountID: accountID,
            bucketName: "two",
            text: "hero",
            filter: .all
        )
        let sized = BucketSearchQuery(
            accountID: accountID,
            bucketName: "one",
            text: "hero",
            filter: BucketSearchFilter(
                kind: .any,
                minimumSize: 1,
                maximumSize: 10,
                modified: .any
            )
        )

        #expect(base != otherBucket)
        #expect(base != sized)
        #expect(Set([base, otherBucket, sized]).count == 3)
    }

    @Test @MainActor func controllerPaginatesFiltersAndReportsProgress() async {
        let pages = SearchPageSequence(pages: [
            ObjectListing(
                folders: [],
                objects: [
                    object(key: "hero.png", size: 10),
                    object(key: "notes.txt", size: 20)
                ],
                isTruncated: true,
                nextToken: "page-2"
            ),
            ObjectListing(
                folders: [],
                objects: [object(key: "nested/hero-dark.png", size: 30)],
                isTruncated: false,
                nextToken: nil
            )
        ])
        let controller = BucketSearchController()
        let query = BucketSearchQuery(
            accountID: accountID,
            bucketName: "demo",
            text: "hero",
            filter: .all
        )

        await controller.search(query: query, now: now) { token in
            try await pages.load(token: token)
        }

        #expect(controller.results.map(\.key) == ["hero.png", "nested/hero-dark.png"])
        #expect(controller.progress == BucketSearchProgress(scanned: 3, matched: 2, pages: 2))
        #expect(controller.snapshot?.isIncomplete == false)
        #expect(!controller.isSearching)
        #expect(await pages.requestedTokens() == [nil, "page-2"])
    }

    @Test @MainActor func controllerMarksARepeatedContinuationTokenIncomplete() async {
        let pages = SearchPageSequence(pages: [
            ObjectListing(
                folders: [],
                objects: [object(key: "one.txt")],
                isTruncated: true,
                nextToken: "same"
            ),
            ObjectListing(
                folders: [],
                objects: [object(key: "two.txt")],
                isTruncated: true,
                nextToken: "same"
            )
        ])
        let controller = BucketSearchController()

        await controller.search(query: query(text: ""), now: now) { token in
            try await pages.load(token: token)
        }

        #expect(controller.snapshot?.isIncomplete == true)
        #expect(controller.results.map(\.key) == ["one.txt", "two.txt"])
        #expect(await pages.requestedTokens() == [nil, "same"])
    }

    @Test @MainActor func completedQueryUsesTheBoundedMemoryCache() async {
        let pages = SearchPageSequence(pages: [
            ObjectListing(
                folders: [],
                objects: [object(key: "cached.txt")],
                isTruncated: false,
                nextToken: nil
            )
        ])
        let controller = BucketSearchController()
        let query = query(text: "cached")

        await controller.search(query: query, now: now) { token in
            try await pages.load(token: token)
        }
        await controller.search(query: query, now: now) { token in
            try await pages.load(token: token)
        }

        #expect(controller.results.map(\.key) == ["cached.txt"])
        #expect(await pages.requestedTokens() == [nil])
    }

    @Test @MainActor func staleSearchCannotReplaceANewerQuery() async {
        let gate = SuspendedSearchPage()
        let controller = BucketSearchController()
        let oldQuery = query(text: "old")
        let newQuery = query(text: "new")

        let oldTask = Task { @MainActor in
            await controller.search(query: oldQuery, now: now) { _ in
                await gate.load()
            }
        }
        await gate.waitUntilStarted()
        await controller.search(query: newQuery, now: now) { _ in
            ObjectListing(
                folders: [],
                objects: [self.object(key: "new.txt")],
                isTruncated: false,
                nextToken: nil
            )
        }
        await gate.release(
            ObjectListing(
                folders: [],
                objects: [object(key: "old.txt")],
                isTruncated: false,
                nextToken: nil
            )
        )
        await oldTask.value

        #expect(controller.activeQuery == newQuery)
        #expect(controller.results.map(\.key) == ["new.txt"])
    }

    @Test @MainActor func incompleteSnapshotIsNotReusedFromCache() async {
        let pages = SearchPageSequence(pages: [
            ObjectListing(
                folders: [],
                objects: [object(key: "one.txt")],
                isTruncated: true,
                nextToken: "same"
            ),
            ObjectListing(
                folders: [],
                objects: [object(key: "two.txt")],
                isTruncated: true,
                nextToken: "same"
            ),
            ObjectListing(
                folders: [],
                objects: [object(key: "fresh.txt")],
                isTruncated: false,
                nextToken: nil
            )
        ])
        let controller = BucketSearchController()
        let query = query(text: "")

        await controller.search(query: query, now: now) { token in
            try await pages.load(token: token)
        }
        #expect(controller.snapshot?.isIncomplete == true)

        await controller.search(query: query, now: now) { token in
            try await pages.load(token: token)
        }

        #expect(controller.results.map(\.key) == ["fresh.txt"])
        #expect(controller.snapshot?.isIncomplete == false)
        #expect(await pages.requestedTokens() == [nil, "same", nil])
    }

    private func query(text: String) -> BucketSearchQuery {
        BucketSearchQuery(
            accountID: accountID,
            bucketName: "demo",
            text: text,
            filter: .all
        )
    }

    private func object(
        key: String,
        size: Int64 = 1,
        modified: Date? = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> OSSObject {
        OSSObject(
            key: key,
            size: size,
            etag: "etag",
            lastModified: modified,
            storageClass: "Standard"
        )
    }
}

private actor SearchPageSequence {
    private var pages: [ObjectListing]
    private var tokens: [String?] = []

    init(pages: [ObjectListing]) {
        self.pages = pages
    }

    func load(token: String?) throws -> ObjectListing {
        tokens.append(token)
        guard !pages.isEmpty else {
            throw OSSServiceError(statusCode: 0, code: "NoPage", message: "缺少测试分页", requestId: "")
        }
        return pages.removeFirst()
    }

    func requestedTokens() -> [String?] {
        tokens
    }
}

private actor SuspendedSearchPage {
    private var started = false
    private var continuation: CheckedContinuation<ObjectListing, Never>?

    func load() async -> ObjectListing {
        started = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func release(_ page: ObjectListing) {
        continuation?.resume(returning: page)
        continuation = nil
    }
}
