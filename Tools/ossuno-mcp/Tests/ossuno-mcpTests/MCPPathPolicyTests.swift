import Foundation
import XCTest
@testable import ossuno_mcp

final class MCPPathPolicyTests: XCTestCase, @unchecked Sendable {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ossuno-mcp-path-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testUploadAllowsRegularFileInsideRoot() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("asset.txt")
        try Data("hello".utf8).write(to: file)

        let policy = try MCPPathPolicy(paths: [root.path])
        XCTAssertEqual(try policy.validateUploadPath(file.path).path, file.path)
    }

    func testUploadRejectsOutsideRootAndSymbolicLink() throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let outsideFile = outside.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: outsideFile)
        let link = root.appendingPathComponent("linked.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideFile)
        let policy = try MCPPathPolicy(paths: [root.path])

        XCTAssertThrowsError(try policy.validateUploadPath(outsideFile.path)) { error in
            guard case MCPPathPolicyError.outsideAllowedRoots = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try policy.validateUploadPath(link.path)) { error in
            guard case MCPPathPolicyError.symbolicLink = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testDownloadAllowsNewNestedPathButRejectsSymlinkTraversal() throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let policy = try MCPPathPolicy(paths: [root.path])
        let destination = root.appendingPathComponent("new/folder/object.bin")
        XCTAssertEqual(try policy.validateDownloadPath(destination.path).path, destination.path)

        let linkedDirectory = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: outside)
        XCTAssertThrowsError(
            try policy.validateDownloadPath(linkedDirectory.appendingPathComponent("object.bin").path)
        ) { error in
            guard case MCPPathPolicyError.symbolicLink = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testDownloadRejectsAnExistingDestinationBeforeNetworkWork() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("existing.bin")
        try Data("keep".utf8).write(to: destination)
        let policy = try MCPPathPolicy(paths: [root.path])

        XCTAssertThrowsError(try policy.prepareDownloadPath(destination.path)) { error in
            XCTAssertEqual(error as? MCPPathPolicyError, .localFileExists(destination.path))
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("keep".utf8))
    }

    func testEnvironmentAcceptsJSONRootsAndRejectsFilesystemRoot() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let json = String(data: try JSONEncoder().encode([root.path]), encoding: .utf8)!
        let policy = try MCPPathPolicy(environment: [MCPPathPolicy.environmentKey: json])
        XCTAssertTrue(policy.allowedRootsDescription.contains(root.path))

        XCTAssertThrowsError(try MCPPathPolicy(paths: ["/"])) { error in
            XCTAssertEqual(error as? MCPPathPolicyError, .invalidRoot("/"))
        }
    }

    func testDefaultRootsIncludeSystemTemporaryDirectory() throws {
        let policy = try MCPPathPolicy(environment: [:])
        let temp = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let file = temp.appendingPathComponent("ossuno-mcp-default-temp-\(UUID().uuidString).txt")
        try Data("temp".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try policy.validateUploadPath(file.path).path, file.path)
    }

    func testUploadRejectsHardLink() throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let secret = outside.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: secret)
        let link = root.appendingPathComponent("alias.txt")
        try FileManager.default.linkItem(at: secret, to: link)
        let policy = try MCPPathPolicy(paths: [root.path])
        XCTAssertThrowsError(try policy.validateUploadPath(link.path)) { error in
            guard case MCPPathPolicyError.hardLink = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testStagedUploadKeepsValidatedBytesAfterSourcePathIsReplaced() throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let source = root.appendingPathComponent("asset.txt")
        let outsideFile = outside.appendingPathComponent("secret.txt")
        try Data("approved".utf8).write(to: source)
        try Data("secret".utf8).write(to: outsideFile)
        let policy = try MCPPathPolicy(paths: [root.path])

        let staged = try policy.stageUploadPath(source.path)
        defer { try? FileManager.default.removeItem(at: staged.fileURL) }
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outsideFile)

        XCTAssertEqual(try Data(contentsOf: staged.fileURL), Data("approved".utf8))
        XCTAssertEqual(staged.size, 8)
    }

    func testDownloadPublishRejectsParentSwappedToOutsideSymlink() throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let parent = root.appendingPathComponent("slot", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let destination = parent.appendingPathComponent("object.bin")
        let policy = try MCPPathPolicy(paths: [root.path])
        let target = try policy.prepareDownloadPath(destination.path)
        let movedParent = root.appendingPathComponent("slot-before-swap", isDirectory: true)
        try FileManager.default.moveItem(at: parent, to: movedParent)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
        let downloaded = root.appendingPathComponent("downloaded.tmp")
        try Data("downloaded".utf8).write(to: downloaded)

        XCTAssertThrowsError(try target.publish(downloaded)) { error in
            guard case MCPPathPolicyError.symbolicLink = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("object.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: movedParent.appendingPathComponent("object.bin").path))
    }
}
