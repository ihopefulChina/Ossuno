import Foundation
import Testing
@testable import Ossuno

struct FinderExportTests {
    @Test func oneObjectExportsAsItsOwnFilename() throws {
        let payload = Self.payload(objects: ["reports/Q3.pdf"])
        let plan = try FinderExportPlan.make(
            payload: payload,
            objects: [Self.object("reports/Q3.pdf", size: 42)],
            folderListings: [:]
        )

        #expect(plan.rootName == "Q3.pdf")
        #expect(plan.entries == [FinderExportEntry(objectKey: "reports/Q3.pdf", expectedSize: 42, relativePath: "Q3.pdf")])
    }

    @Test func oneFolderExportsItsCompleteTreeUnderTheFolderName() throws {
        let payload = Self.payload(folders: ["Design/Assets/"])
        let plan = try FinderExportPlan.make(
            payload: payload,
            objects: [],
            folderListings: [
                "Design/Assets/": [
                    Self.object("Design/Assets/Icons/app.png"),
                    Self.object("Design/Assets/README.txt")
                ]
            ]
        )

        #expect(plan.rootName == "Assets")
        #expect(plan.entries.map(\.relativePath) == ["Assets/Icons/app.png", "Assets/README.txt"])
    }

    @Test func fileAndFolderWithTheSameLeafNameAreDisambiguated() throws {
        let payload = Self.payload(objects: ["photo"], folders: ["photo/"])
        let plan = try FinderExportPlan.make(
            payload: payload,
            objects: [Self.object("photo")],
            folderListings: [
                "photo/": [Self.object("photo/inside.txt")]
            ]
        )

        #expect(plan.rootName == "Ossuno 下载")
        let paths = Set(plan.entries.map(\.relativePath))
        #expect(paths.contains("Ossuno 下载/photo") || paths.contains("Ossuno 下载/photo 2"))
        #expect(paths.contains("Ossuno 下载/photo/inside.txt") || paths.contains("Ossuno 下载/photo 2/inside.txt"))
        let fileLeaf = plan.entries.first { $0.objectKey == "photo" }?.relativePath
        let folderLeaf = plan.entries.first { $0.objectKey == "photo/inside.txt" }?.relativePath
            .split(separator: "/").dropFirst().first
            .map(String.init)
        #expect(fileLeaf != nil)
        #expect(folderLeaf != nil)
        #expect(fileLeaf?.split(separator: "/").last.map(String.init) != folderLeaf)
    }

    @Test func multipleItemsUseAContainerAndFinderStyleDuplicateNames() throws {
        let payload = Self.payload(objects: ["a/hero.png", "b/hero.png"])
        let plan = try FinderExportPlan.make(
            payload: payload,
            objects: [Self.object("a/hero.png"), Self.object("b/hero.png")],
            folderListings: [:]
        )

        #expect(plan.rootName == "Ossuno 下载")
        #expect(plan.entries.map(\.relativePath) == ["Ossuno 下载/hero.png", "Ossuno 下载/hero 2.png"])
    }

    @Test func folderTraversalKeysAreRejected() {
        let payload = Self.payload(folders: ["safe/"])

        #expect(throws: FinderExportError.self) {
            try FinderExportPlan.make(
                payload: payload,
                objects: [],
                folderListings: ["safe/": [Self.object("safe/../secret.txt")]]
            )
        }
    }

    @Test func cachePruningRemovesOnlyStaleOwnedExports() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "FinderExportTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stale = root.appending(path: "export-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fresh = root.appending(path: "export-\(UUID().uuidString)", directoryHint: .isDirectory)
        let foreign = root.appending(path: "keep-me", directoryHint: .isDirectory)
        for url in [stale, fresh, foreign] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let now = Date(timeIntervalSince1970: 2_000_000)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-90_000)], ofItemAtPath: stale.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: fresh.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-90_000)], ofItemAtPath: foreign.path)

        FinderExportCoordinator.pruneOwnedExports(in: root, now: now)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    private static func payload(objects: [String] = [], folders: [String] = []) -> CloudDragPayload {
        CloudDragPayload(
            accountID: UUID(),
            bucketName: "assets",
            objectKeys: objects,
            folderPrefixes: folders
        )
    }

    private static func object(_ key: String, size: Int64 = 1) -> OSSObject {
        OSSObject(key: key, size: size, etag: "etag", lastModified: nil, storageClass: "Standard")
    }
}
