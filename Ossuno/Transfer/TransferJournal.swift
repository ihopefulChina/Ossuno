import Foundation

protocol TransferJournaling: Sendable {
    func load() throws -> [PersistedTransfer]
    func save(_ records: [PersistedTransfer]) throws
}

struct NoopTransferJournal: TransferJournaling {
    func load() throws -> [PersistedTransfer] { [] }
    func save(_ records: [PersistedTransfer]) throws {}
}

struct FileTransferJournal: TransferJournaling {
    private struct Envelope: Codable {
        var version: Int
        var transfers: [PersistedTransfer]
    }

    let url: URL

    static var live: FileTransferJournal {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return FileTransferJournal(
            url: base
                .appending(path: "studio.ossuno.oss", directoryHint: .isDirectory)
                .appending(path: "transfers.json")
        )
    }

    func load() throws -> [PersistedTransfer] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Envelope.self, from: data).transfers
    }

    func save(_ records: [PersistedTransfer]) throws {
        let sanitized = records.map { record in
            var copy = record
            copy.job.localURL = nil
            copy.job.publicURL = nil
            return copy
        }
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(version: 1, transfers: sanitized))
        try data.write(to: url, options: .atomic)
    }
}

struct PersistedTransfer: Codable, Equatable, Sendable {
    var job: TransferJob
    var retry: PersistedTransferRetry?
    var checkpoint: TransferCheckpoint? = nil
}

enum PersistedTransferRetry: Codable, Equatable, Sendable {
    case upload(PersistedUploadRetry)
    case download(PersistedDownloadRetry)
}

struct PersistedUploadRetry: Codable, Equatable, Sendable {
    var accountID: UUID
    var bucket: OSSBucket?
    var sourceBookmark: Data
    var objectKey: String
    var imagesOnly: Bool
    var convertHEIC: Bool
    var playSound: Bool
    var allowOverwrite: Bool? = nil
    var preparedBookmark: Data? = nil
}

struct PersistedDownloadRetry: Codable, Equatable, Sendable {
    var accountID: UUID
    var bucket: OSSBucket?
    var rootBookmark: Data
    var object: OSSObject
    var relativeDestination: String
    var allowOverwrite: Bool? = nil
    var overwriteIdentity: TransferEngine.LocalFileIdentity? = nil
}

protocol TransferBookmarking: Sendable {
    func makeBookmark(for url: URL) throws -> Data
    func resolve(_ bookmark: Data) throws -> URL
}

enum TransferBookmarkError: Error {
    case stale
}

struct SecurityScopedTransferBookmarks: TransferBookmarking {
    func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func resolve(_ bookmark: Data) throws -> URL {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard !stale else { throw TransferBookmarkError.stale }
        return url
    }
}
