import Foundation

enum TransferConflictResolution: Equatable, Sendable {
    case useOriginal
    case skip
    case renamed(String)
    case ask
}

enum TransferConflictPlanner {
    static func plan(
        keys: [String],
        existing: Set<String>,
        policy: TransferConflictPolicy,
        folderRoots: [String] = []
    ) -> [TransferConflictResolution] {
        var workingKeys = keys
        if policy == .keepBoth {
            let roots = folderRoots
                .filter { $0.hasSuffix("/") && !$0.isEmpty }
                .sorted { $0.count > $1.count }
            var reserved = existing
            for root in roots {
                guard prefixOccupied(root, existing: reserved) else { continue }
                let renamed = availableKey(for: root, existing: reserved)
                reserved.insert(renamed)
                for index in workingKeys.indices {
                    workingKeys[index] = replacePrefix(workingKeys[index], from: root, to: renamed)
                }
            }
        }

        var reserved = existing
        var seenBatch = Set<String>()
        return zip(keys, workingKeys).map { original, working in
            let resolution = planKey(
                working,
                policy: policy,
                reserved: &reserved,
                seenBatch: &seenBatch
            )
            if working != original {
                switch resolution {
                case .skip, .ask:
                    return resolution
                case .useOriginal:
                    return .renamed(working)
                case .renamed(let key):
                    return .renamed(key)
                }
            }
            return resolution
        }
    }

    /// Top-level folders represented by keys whose relative path under the
    /// destination prefix contains a slash. A file dropped into the current
    /// folder has no slash and must not be treated as renaming that folder.
    static func folderRoots(for keys: [String], destinationPrefix: String) -> [String] {
        var roots = Set<String>()
        for key in keys {
            let relative = PathTemplate.relative(key, under: destinationPrefix)
            guard relative.contains("/") else { continue }
            guard let first = relative.split(separator: "/").first, !first.isEmpty else { continue }
            roots.insert(PathTemplate.join(destinationPrefix, key: String(first)) + "/")
        }
        return Array(roots)
    }

    /// Date templates rewrite the first path segment, so they must not be
    /// treated as a dropped Finder folder. An empty template still keeps the
    /// dropped folder name, including uploads to the bucket root.
    static func folderRoots(
        for keys: [String],
        destinationPrefix: String,
        applyTemplate: Bool,
        template: String
    ) -> [String] {
        if applyTemplate, !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return []
        }
        return folderRoots(for: keys, destinationPrefix: destinationPrefix)
    }

    /// Occupancy used when confirming a folder name after keep-both. Child
    /// destination keys in the same batch must not count: they live under this
    /// folder and would otherwise force an extra " 2".
    static func reservedForConfirmingFolder(
        occupied: Set<String>,
        otherFolderDestinations: [String]
    ) -> Set<String> {
        occupied.union(otherFolderDestinations)
    }

    private static func planKey(
        _ key: String,
        policy: TransferConflictPolicy,
        reserved: inout Set<String>,
        seenBatch: inout Set<String>
    ) -> TransferConflictResolution {
        if seenBatch.insert(key).inserted == false {
            // The same key appears twice in one batch. Under .replace the
            // first occurrence would be overwritten by the second, and
            // under .keepBoth the user wants both files, so disambiguate;
            // .ask keeps prompting and .skip keeps skipping.
            switch policy {
            case .replace, .keepBoth:
                let renamed = availableKey(for: key, existing: reserved)
                reserved.insert(renamed)
                return .renamed(renamed)
            case .ask:
                return .ask
            case .skip:
                return .skip
            }
        }
        guard reserved.contains(key) else {
            reserved.insert(key)
            return .useOriginal
        }
        switch policy {
        case .ask:
            return .ask
        case .replace:
            reserved.insert(key)
            return .useOriginal
        case .skip:
            return .skip
        case .keepBoth:
            let renamed = availableKey(for: key, existing: reserved)
            reserved.insert(renamed)
            return .renamed(renamed)
        }
    }

    static func availableKey(for key: String, existing: Set<String>) -> String {
        let isFolder = key.hasSuffix("/")
        let isTaken: (String) -> Bool = { candidate in
            isFolder ? prefixOccupied(candidate, existing: existing) : existing.contains(candidate)
        }
        guard isTaken(key) else { return key }
        let trimmed = isFolder ? String(key.dropLast()) : key
        let parent = PathTemplate.parentPrefix(trimmed)
        let leaf = PathTemplate.lastComponent(trimmed)
        let stem: String
        let suffix: String
        if isFolder {
            stem = leaf
            suffix = ""
        } else {
            let ns = leaf as NSString
            let ext = ns.pathExtension
            stem = ns.deletingPathExtension
            suffix = ext.isEmpty ? "" : ".\(ext)"
        }
        var number = 2
        while true {
            var candidate = PathTemplate.join(parent, key: "\(stem) \(number)\(suffix)")
            if isFolder { candidate += "/" }
            if !isTaken(candidate) { return candidate }
            number += 1
        }
    }

    /// A folder collides when that prefix already exists, or any child key
    /// lives under it. Finder-style keep-both then renames the whole folder.
    static func prefixOccupied(_ prefix: String, existing: Set<String>) -> Bool {
        if existing.contains(prefix) { return true }
        guard prefix.hasSuffix("/") else { return false }
        return existing.contains { key in
            key.hasPrefix(prefix)
        }
    }

    static func replacePrefix(_ key: String, from: String, to: String) -> String {
        if key == from { return to }
        guard from.hasSuffix("/"), to.hasSuffix("/"), key.hasPrefix(from) else {
            return key
        }
        return to + String(key.dropFirst(from.count))
    }

    /// Keep-both for a mixed file/folder move: rename colliding folders as a
    /// unit, then number remaining file collisions like Finder.
    static func resolveKeepBoth(
        mappings: [(source: String, destination: String)],
        folderMoves: [(source: String, destination: String)],
        existing: Set<String>
    ) -> (
        mappings: [(source: String, destination: String)],
        folderMoves: [(source: String, destination: String)]
    ) {
        var resultMappings = mappings
        var resultFolders = folderMoves

        for folderIndex in resultFolders.indices {
            let pair = resultFolders[folderIndex]
            guard prefixOccupied(pair.destination, existing: existing) else { continue }
            var nameReserved = existing
            for otherIndex in resultFolders.indices where otherIndex != folderIndex {
                nameReserved.insert(resultFolders[otherIndex].destination)
            }
            for mapping in resultMappings {
                let underFolder = mapping.source == pair.source
                    || mapping.source.hasPrefix(pair.source)
                if !underFolder {
                    nameReserved.insert(mapping.destination)
                }
            }
            let renamed = availableKey(for: pair.destination, existing: nameReserved)
            for mappingIndex in resultMappings.indices {
                let source = resultMappings[mappingIndex].source
                if source == pair.source || source.hasPrefix(pair.source) {
                    resultMappings[mappingIndex].destination = replacePrefix(
                        resultMappings[mappingIndex].destination,
                        from: pair.destination,
                        to: renamed
                    )
                }
            }
            resultFolders[folderIndex].destination = renamed
        }

        var reserved = existing.union(Set(resultMappings.map(\.destination)))
        for index in resultMappings.indices {
            let destination = resultMappings[index].destination
            guard existing.contains(destination) else { continue }
            let renamed = availableKey(for: destination, existing: reserved)
            reserved.remove(destination)
            reserved.insert(renamed)
            resultMappings[index].destination = renamed
        }
        return (resultMappings, resultFolders)
    }
}
