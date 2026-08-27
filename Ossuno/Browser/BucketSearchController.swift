import Foundation
import Observation

@MainActor
@Observable
final class BucketSearchController {
    private struct CacheEntry {
        var snapshot: BucketSearchSnapshot
        var lastAccess: UInt64
    }

    private static let maximumPages = 30
    private static let maximumObjects = 30_000
    private static let maximumCacheEntries = 8

    private(set) var results: [OSSObject] = []
    private(set) var progress = BucketSearchProgress(scanned: 0, matched: 0, pages: 0)
    private(set) var isSearching = false
    private(set) var errorMessage: String?
    private(set) var activeQuery: BucketSearchQuery?
    private(set) var snapshot: BucketSearchSnapshot?

    private var generation = 0
    private var accessCounter: UInt64 = 0
    private var cache: [BucketSearchQuery: CacheEntry] = [:]
    private var searchTask: Task<Void, Never>?

    func search(
        query: BucketSearchQuery,
        now: Date = .now,
        pageLoader: @escaping @Sendable (String?) async throws -> ObjectListing
    ) async {
        generation += 1
        let requestGeneration = generation
        activeQuery = query
        errorMessage = nil

        if let cached = cachedSnapshot(for: query) {
            apply(cached)
            isSearching = false
            return
        }

        results = []
        progress = BucketSearchProgress(scanned: 0, matched: 0, pages: 0)
        snapshot = nil
        isSearching = true

        searchTask?.cancel()
        let task = Task { [weak self] in
            await self?.performSearch(
                query: query,
                now: now,
                generation: requestGeneration,
                pageLoader: pageLoader
            )
            return ()
        }
        searchTask = task
        await task.value
    }

    func cancel() {
        generation += 1
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    private func performSearch(
        query: BucketSearchQuery,
        now: Date,
        generation requestGeneration: Int,
        pageLoader: @escaping @Sendable (String?) async throws -> ObjectListing
    ) async {
        var token: String?
        var seenTokens = Set<String>()
        var matches: [String: OSSObject] = [:]
        var scanned = 0
        var pages = 0
        var incomplete = false

        do {
            repeat {
                try Task.checkCancellation()
                let page = try await pageLoader(token)
                guard requestGeneration == generation else { return }

                pages += 1
                scanned += page.objects.count
                for object in page.objects where query.matches(object, now: now) {
                    matches[object.key] = object
                }
                let ordered = Self.order(Array(matches.values), for: query)
                results = ordered
                progress = BucketSearchProgress(
                    scanned: scanned,
                    matched: ordered.count,
                    pages: pages
                )

                if scanned >= Self.maximumObjects {
                    incomplete = page.isTruncated
                    token = nil
                } else if page.isTruncated {
                    guard let next = page.nextToken,
                          !next.isEmpty,
                          seenTokens.insert(next).inserted
                    else {
                        incomplete = true
                        token = nil
                        break
                    }
                    token = next
                } else {
                    token = nil
                }
            } while token != nil && pages < Self.maximumPages

            if token != nil { incomplete = true }
            guard requestGeneration == generation else { return }
            let completed = BucketSearchSnapshot(
                query: query,
                objects: Self.order(Array(matches.values), for: query),
                progress: BucketSearchProgress(
                    scanned: scanned,
                    matched: matches.count,
                    pages: pages
                ),
                isIncomplete: incomplete
            )
            store(completed)
            apply(completed)
            isSearching = false
        } catch is CancellationError {
            guard requestGeneration == generation else { return }
            isSearching = false
        } catch {
            guard requestGeneration == generation else { return }
            isSearching = false
            errorMessage = error.localizedDescription
        }
    }

    func clear() {
        cancel()
        activeQuery = nil
        results = []
        progress = BucketSearchProgress(scanned: 0, matched: 0, pages: 0)
        errorMessage = nil
        snapshot = nil
    }

    func invalidate(accountID: UUID, bucketName: String) {
        cache = cache.filter { query, _ in
            query.accountID != accountID || query.bucketName != bucketName
        }
        if activeQuery?.accountID == accountID,
           activeQuery?.bucketName == bucketName {
            clear()
        }
    }

    #if DEBUG
    func seedForScreenshot(_ snapshot: BucketSearchSnapshot) {
        apply(snapshot)
        isSearching = false
    }
    #endif

    private func apply(_ snapshot: BucketSearchSnapshot) {
        activeQuery = snapshot.query
        results = snapshot.objects
        progress = snapshot.progress
        self.snapshot = snapshot
        errorMessage = nil
    }

    private func cachedSnapshot(for query: BucketSearchQuery) -> BucketSearchSnapshot? {
        // Date-relative filters (最近 N 天) depend on the current date, so a
        // cached snapshot from earlier would silently return stale results.
        guard query.filter.modified == .any else { return nil }
        guard var entry = cache[query] else { return nil }
        accessCounter &+= 1
        entry.lastAccess = accessCounter
        cache[query] = entry
        return entry.snapshot
    }

    private func store(_ snapshot: BucketSearchSnapshot) {
        // Incomplete scans (page/object caps, repeated tokens) must not be
        // reused: a later identical query should try the bucket again.
        guard !snapshot.isIncomplete else { return }
        accessCounter &+= 1
        cache[snapshot.query] = CacheEntry(snapshot: snapshot, lastAccess: accessCounter)
        guard cache.count > Self.maximumCacheEntries,
              let oldest = cache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key
        else { return }
        cache[oldest] = nil
    }

    private static func order(_ objects: [OSSObject], for query: BucketSearchQuery) -> [OSSObject] {
        switch query.filter.modified {
        case .lastDays:
            return objects.sorted {
                ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast)
            }
        default:
            // Only the dedicated "大文件" view (a pure minimum-size filter) is
            // size-descending; any other filter combination keeps name order
            // so ordering stays predictable.
            let isPureSizeFloor = query.filter.kind == .any
                && query.filter.modified == .any
                && query.filter.minimumSize != nil
                && query.filter.maximumSize == nil
                && query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isPureSizeFloor {
                return objects.sorted {
                    $0.size == $1.size
                        ? $0.key.localizedStandardCompare($1.key) == .orderedAscending
                        : $0.size > $1.size
                }
            }
            return objects.sorted {
                $0.key.localizedStandardCompare($1.key) == .orderedAscending
            }
        }
    }
}
