import AppKit
import Foundation
import UniformTypeIdentifiers

struct FinderExportEntry: Equatable, Sendable {
    var objectKey: String
    var expectedSize: Int64
    var relativePath: String
}

struct FinderExportPlan: Equatable, Sendable {
    var rootName: String
    var entries: [FinderExportEntry]
    var representsDirectory: Bool

    static func make(
        payload: CloudDragPayload,
        objects: [OSSObject],
        folderListings: [String: [OSSObject]]
    ) throws -> FinderExportPlan {
        let selectionCount = payload.objectKeys.count + payload.folderPrefixes.count
        guard selectionCount > 0 else { throw FinderExportError.emptySelection }
        let wrapsSelection = selectionCount > 1
        let rootName = wrapsSelection ? "Ossuno 下载" : ""
        // Overlapping payloads (an object key that also appears in a dragged
        // folder's listing) must not trap on duplicate keys.
        var objectMap: [String: OSSObject] = [:]
        for object in objects {
            objectMap[object.key] = object
        }
        var reservedNames = Set<String>()
        var entries: [FinderExportEntry] = []

        for key in payload.objectKeys {
            guard let object = objectMap[key] else {
                throw FinderExportError.missingObject(key)
            }
            let leaf = try safeLeaf(PathTemplate.lastComponent(key))
            let exportName = uniqueName(leaf, reserved: &reservedNames, isFolder: false)
            let relativePath = wrapsSelection ? "\(rootName)/\(exportName)" : exportName
            try validatePath(relativePath)
            entries.append(
                FinderExportEntry(
                    objectKey: key,
                    expectedSize: object.size,
                    relativePath: relativePath
                )
            )
        }

        for prefix in payload.folderPrefixes {
            guard prefix.hasSuffix("/"), !prefix.isEmpty else {
                throw FinderExportError.invalidFolderPrefix(prefix)
            }
            let folderName = try safeLeaf(PathTemplate.lastComponent(String(prefix.dropLast())))
            let exportName = uniqueName(folderName, reserved: &reservedNames, isFolder: true)
            let folderRoot = wrapsSelection ? "\(rootName)/\(exportName)" : exportName
            try validatePath(folderRoot)
            guard let listing = folderListings[prefix] else {
                throw FinderExportError.missingFolderListing(prefix)
            }
            for object in listing.sorted(by: { $0.key < $1.key }) {
                guard object.key.hasPrefix(prefix) else {
                    throw FinderExportError.objectOutsideFolder(object.key)
                }
                let relative = String(object.key.dropFirst(prefix.count))
                if relative.isEmpty || object.isFolderPlaceholder { continue }
                try validatePath(relative)
                entries.append(
                    FinderExportEntry(
                        objectKey: object.key,
                        expectedSize: object.size,
                        relativePath: "\(folderRoot)/\(relative)"
                    )
                )
            }
        }

        let finalRoot: String
        if wrapsSelection {
            finalRoot = rootName
        } else if let first = entries.first?.relativePath.components(separatedBy: "/").first {
            finalRoot = first
        } else {
            finalRoot = try singleFolderName(payload.folderPrefixes)
        }
        return FinderExportPlan(
            rootName: finalRoot,
            entries: entries,
            representsDirectory: wrapsSelection || !payload.folderPrefixes.isEmpty
        )
    }

    private static func safeLeaf(_ value: String) throws -> String {
        do {
            return try ObjectNameValidator.validate(value)
        } catch {
            throw FinderExportError.unsafePath(value)
        }
    }

    private static func validatePath(_ value: String) throws {
        do {
            _ = try FileSafety.relativeComponents(value)
        } catch {
            throw FinderExportError.unsafePath(value)
        }
    }

    private static func singleFolderName(_ prefixes: [String]) throws -> String {
        guard let prefix = prefixes.first else { throw FinderExportError.emptySelection }
        return try safeLeaf(PathTemplate.lastComponent(String(prefix.dropLast())))
    }

    private static func uniqueName(
        _ name: String,
        reserved: inout Set<String>,
        isFolder: Bool
    ) -> String {
        // APFS cannot host a file and a directory with the same leaf name.
        // Reserve both spellings so `photo` and `photo/` cannot collide.
        var occupied = reserved
        if reserved.contains(name) { occupied.insert(name + "/") }
        if reserved.contains(name + "/") { occupied.insert(name) }
        let seed = isFolder ? name + "/" : name
        let uniqueKey = TransferConflictPlanner.availableKey(for: seed, existing: occupied)
        if uniqueKey.hasSuffix("/") {
            let leaf = String(uniqueKey.dropLast())
            reserved.insert(uniqueKey)
            reserved.insert(leaf)
            return leaf
        }
        reserved.insert(uniqueKey)
        reserved.insert(uniqueKey + "/")
        return uniqueKey
    }
}

enum FinderExportError: LocalizedError, Equatable, Sendable {
    case emptySelection
    case missingObject(String)
    case invalidFolderPrefix(String)
    case missingFolderListing(String)
    case objectOutsideFolder(String)
    case unsafePath(String)
    case incompleteListing(String)

    var errorDescription: String? {
        switch self {
        case .emptySelection: "没有可导出的项目"
        case .missingObject: "云端文件已不在当前位置"
        case .invalidFolderPrefix, .unsafePath: "云端项目包含不安全的路径"
        case .missingFolderListing, .incompleteListing: "文件夹未能完整列出，请稍后重试"
        case .objectOutsideFolder: "文件夹返回了范围外的对象，已停止导出"
        }
    }
}

enum FinderExportCoordinator {
    private static let maximumCacheAge: TimeInterval = 24 * 60 * 60

    static var cacheRoot: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appending(path: "studio.ossuno.oss", directoryHint: .isDirectory)
            .appending(path: "FinderExports", directoryHint: .isDirectory)
    }

    @MainActor
    static func itemProvider(
        for payload: CloudDragPayload,
        client: OSSClient,
        speedLimit: TransferSpeedLimit = .unlimited
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = suggestedName(for: payload)
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.ossunoCloudItems.identifier,
            visibility: .ownProcess
        ) { completion in
            do {
                completion(try JSONEncoder().encode(payload), nil)
            } catch {
                completion(nil, error)
            }
            return nil
        }
        let type = payload.objectKeys.count == 1 && payload.folderPrefixes.isEmpty
            ? (UTType(filenameExtension: (payload.objectKeys[0] as NSString).pathExtension) ?? .data)
            : .folder
        provider.registerFileRepresentation(
            forTypeIdentifier: type.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            let progress = Progress(totalUnitCount: 1)
            let task = Task {
                do {
                    let url = try await export(
                        payload: payload,
                        client: client,
                        speedLimit: speedLimit
                    )
                    progress.completedUnitCount = 1
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }
        return provider
    }

    static func export(
        payload: CloudDragPayload,
        client: OSSClient,
        speedLimit: TransferSpeedLimit = .unlimited
    ) async throws -> URL {
        try Task.checkCancellation()
        let root = cacheRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        pruneOwnedExports(in: root)
        let exportDirectory = root.appending(
            path: "export-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        do {
            var objects: [OSSObject] = []
            for key in payload.objectKeys {
                try Task.checkCancellation()
                let head = try await client.head(key: key)
                objects.append(
                    OSSObject(
                        key: key,
                        size: head.contentLength ?? 0,
                        etag: head.etag ?? "",
                        lastModified: head.lastModified,
                        storageClass: head.storageClass ?? ""
                    )
                )
            }
            var folderListings: [String: [OSSObject]] = [:]
            for prefix in payload.folderPrefixes {
                try Task.checkCancellation()
                let listing = try await client.listAllObjects(prefix: prefix)
                guard !listing.truncated else {
                    throw FinderExportError.incompleteListing(prefix)
                }
                folderListings[prefix] = listing.objects
            }
            let plan = try FinderExportPlan.make(
                payload: payload,
                objects: objects,
                folderListings: folderListings
            )
            let exportedRoot = try FileSafety.destination(
                root: exportDirectory,
                relativePath: plan.rootName
            )
            if plan.representsDirectory {
                try FileManager.default.createDirectory(at: exportedRoot, withIntermediateDirectories: true)
            }
            for entry in plan.entries {
                try Task.checkCancellation()
                let destination = try FileSafety.destination(
                    root: exportDirectory,
                    relativePath: entry.relativePath
                )
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                _ = try await client.downloadResumable(
                    key: entry.objectKey,
                    to: destination,
                    within: exportDirectory,
                    expectedSize: entry.expectedSize,
                    speedLimit: speedLimit
                )
            }
            return exportedRoot
        } catch {
            try? FileManager.default.removeItem(at: exportDirectory)
            throw error
        }
    }

    /// Best-effort cleanup: one locked or stale export directory must never
    /// abort a brand-new export.
    static func pruneOwnedExports(
        in root: URL,
        now: Date = .now,
        maximumAge: TimeInterval = maximumCacheAge
    ) {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls where url.lastPathComponent.hasPrefix("export-") {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                  values.isDirectory == true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) > maximumAge
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func suggestedName(for payload: CloudDragPayload) -> String {
        if payload.objectKeys.count + payload.folderPrefixes.count > 1 { return "Ossuno 下载" }
        if let key = payload.objectKeys.first { return PathTemplate.lastComponent(key) }
        if let prefix = payload.folderPrefixes.first {
            return PathTemplate.lastComponent(String(prefix.dropLast()))
        }
        return "Ossuno 下载"
    }
}
