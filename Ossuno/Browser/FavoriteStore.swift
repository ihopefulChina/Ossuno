import Foundation
import Observation

struct FavoriteLocation: Codable, Hashable, Identifiable, Sendable {
    var accountID: UUID
    var bucketName: String
    var prefix: String
    var name: String

    var id: String {
        "\(accountID.uuidString)/\(bucketName)/\(prefix)"
    }
}

@MainActor
@Observable
final class FavoriteStore {
    private(set) var items: [FavoriteLocation]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.locations),
           let decoded = try? JSONDecoder().decode([FavoriteLocation].self, from: data) {
            self.items = decoded.uniqued(on: \FavoriteLocation.id)
        } else {
            self.items = []
        }
    }

    func contains(accountID: UUID, bucketName: String, prefix: String) -> Bool {
        items.contains { location in
            location.accountID == accountID
                && location.bucketName == bucketName
                && location.prefix == prefix
        }
    }

    func add(_ location: FavoriteLocation) {
        guard !items.contains(where: { $0.id == location.id }) else { return }
        items.append(location)
        save()
    }

    func remove(_ location: FavoriteLocation) {
        items.removeAll { $0.id == location.id }
        save()
    }

    func remove(accountID: UUID, bucketName: String, prefix: String) {
        items.removeAll { location in
            location.accountID == accountID
                && location.bucketName == bucketName
                && location.prefix == prefix
        }
        save()
    }

    /// A folder favorite should move only when every planned child under that
    /// prefix still remains after skip/conflict filtering.
    static func didMoveFolderCompletely(
        sourcePrefix: String,
        originalSourceKeys: [String],
        remainingSourceKeys: [String]
    ) -> Bool {
        let originalCount = originalSourceKeys.filter {
            $0 == sourcePrefix || $0.hasPrefix(sourcePrefix)
        }.count
        let remainingCount = remainingSourceKeys.filter {
            $0 == sourcePrefix || $0.hasPrefix(sourcePrefix)
        }.count
        return originalCount > 0 && originalCount == remainingCount
    }

    func replacePrefix(
        accountID: UUID,
        bucketName: String,
        source: String,
        destination: String,
        destinationAccountID: UUID? = nil,
        destinationBucketName: String? = nil
    ) {
        let targetAccountID = destinationAccountID ?? accountID
        let targetBucketName = destinationBucketName ?? bucketName
        var changed = false
        for index in items.indices where
            items[index].accountID == accountID
                && items[index].bucketName == bucketName
                && Self.isWithin(items[index].prefix, folder: source) {
            let relative = String(items[index].prefix.dropFirst(source.count))
            items[index].accountID = targetAccountID
            items[index].bucketName = targetBucketName
            items[index].prefix = destination + relative
            if items[index].prefix == destination {
                items[index].name = PathTemplate.lastComponent(destination)
            }
            changed = true
        }
        if changed {
            items = items.uniqued(on: \FavoriteLocation.id)
            save()
        }
    }

    /// Matches only the folder itself and prefixes at a path-component
    /// boundary, so renaming folder `a` never touches favorites under `ab/`.
    private static func isWithin(_ prefix: String, folder source: String) -> Bool {
        if prefix == source { return true }
        if source.isEmpty { return true }
        return source.hasSuffix("/")
            ? prefix.hasPrefix(source)
            : prefix.hasPrefix(source + "/")
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Keys.locations)
    }

    private enum Keys {
        static let locations = "browser.favoriteLocations"
    }
}

private extension Array {
    func uniqued<ID: Hashable>(on keyPath: KeyPath<Element, ID>) -> [Element] {
        var seen = Set<ID>()
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}
