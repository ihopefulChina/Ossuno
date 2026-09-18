import Foundation

struct PendingUploadBatch: Sendable {
    var urls: [URL]
    var prefix: String
    var applyTemplate: Bool
    var ownedTemporaryURLs: Set<URL>
    var client: OSSClient
    var account: OSSAccount
    var bucket: OSSBucket
}
