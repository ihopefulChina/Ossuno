import Foundation

enum CrossBucketMethod: String, Equatable, Sendable {
    case serverSide
    case relay

    var title: String { self == .serverSide ? "云端直接复制" : "通过这台 Mac 中转" }
}

struct CrossBucketMapping: Equatable, Hashable, Sendable {
    var sourceKey: String
    var destinationKey: String
    var expectedSize: Int64
}

struct CrossBucketPlan: Equatable, Sendable {
    var method: CrossBucketMethod
    var mappings: [CrossBucketMapping]
    var knownBytes: Int64
}

struct CrossBucketPreflight: Identifiable, Sendable {
    var id = UUID()
    var plan: CrossBucketPlan
    var mode: CloudOperationMode
    var sourceAccount: OSSAccount
    var sourceBucket: OSSBucket
    var destinationAccount: OSSAccount
    var destinationBucket: OSSBucket
    var sourceClient: OSSClient
    var destinationClient: OSSClient
    var overwrite: Bool
    var renamedConflicts: Int
    var existingDestinations: Set<String>
    var folderMoves: [CloudFavoriteMove]
}

struct CloudDestinationBackup: Equatable, Sendable {
    var originalKey: String
    var backupKey: String
    var backupVersionID: String?
    var acl: ObjectACL
    /// Identity of the user-visible destination at the instant its private
    /// backup was created. The later replacement must still match this value.
    var originalIdentity: OSSObjectIdentity
}

struct CloudTemporaryObject: Equatable, Sendable {
    var key: String
    var versionID: String?
}

enum CloudRollbackError: LocalizedError, Sendable {
    case rollbackFailed(operation: String, failures: [String])
    case cleanupFailed(keys: [String])
    case manualInspectionRequired(operation: String, keys: [String])

    var errorDescription: String? {
        switch self {
        case .rollbackFailed(let operation, let failures):
            return "\(operation)；恢复原对象时仍有 \(failures.count) 项失败：\(failures.joined(separator: "、"))"
        case .cleanupFailed(let keys):
            return "操作已完成，但有 \(keys.count) 个临时安全备份未能清理：\(keys.joined(separator: "、"))"
        case .manualInspectionRequired(let operation, let keys):
            return "\(operation)；为避免误删或覆盖，已保留安全副本，请手动检查：\(keys.joined(separator: "、"))"
        }
    }
}

enum CrossBucketOperation {
    static let maximumSingleCopyBytes: Int64 = 5 * 1024 * 1024 * 1024

    static func method(
        sourceAccountID: UUID,
        destinationAccountID: UUID,
        sourceRegion: String,
        destinationRegion: String
    ) -> CrossBucketMethod {
        sourceAccountID == destinationAccountID && sourceRegion == destinationRegion
            ? .serverSide
            : .relay
    }

    static func plan(
        sourceAccountID: UUID,
        destinationAccountID: UUID,
        sourceRegion: String,
        destinationRegion: String,
        destinationPrefix: String,
        objectKeys: [String],
        folders: [String: [OSSObject]]
    ) throws -> CrossBucketPlan {
        var mappings = objectKeys.map {
            CrossBucketMapping(
                sourceKey: $0,
                destinationKey: PathTemplate.join(destinationPrefix, key: PathTemplate.lastComponent($0)),
                expectedSize: 0
            )
        }
        for prefix in folders.keys.sorted() {
            guard prefix.hasSuffix("/"), let objects = folders[prefix] else {
                throw CloudObjectOperationError.invalidPrefix
            }
            let rootName = PathTemplate.lastComponent(String(prefix.dropLast())) + "/"
            for object in objects.sorted(by: { $0.key < $1.key }) {
                guard object.key.hasPrefix(prefix) else {
                    throw CloudObjectOperationError.keyOutsideSource(object.key)
                }
                mappings.append(
                    CrossBucketMapping(
                        sourceKey: object.key,
                        destinationKey: destinationKey(
                            destinationPrefix: destinationPrefix,
                            sourcePrefix: prefix,
                            rootName: rootName,
                            sourceKey: object.key
                        ),
                        expectedSize: object.size
                    )
                )
            }
        }
        try CloudObjectOperation.validate(mappings.map {
            CloudObjectMapping(sourceKey: $0.sourceKey, destinationKey: $0.destinationKey)
        })
        var bytes: Int64 = 0
        for mapping in mappings {
            let (sum, overflow) = bytes.addingReportingOverflow(max(0, mapping.expectedSize))
            bytes = overflow ? Int64.max : sum
        }
        let preferredMethod = method(
                sourceAccountID: sourceAccountID,
                destinationAccountID: destinationAccountID,
                sourceRegion: sourceRegion,
                destinationRegion: destinationRegion
            )
        return CrossBucketPlan(
            method: executionMethod(preferred: preferredMethod, mappings: mappings),
            mappings: mappings,
            knownBytes: bytes
        )
    }

    static func emptyResultMessage(hadMappings: Bool) -> String {
        hadMappings ? "所有同名项目都已跳过" : "源文件夹为空，没有可复制的对象"
    }

    /// OSS CopyObject cannot copy an object larger than 5 GiB between
    /// different buckets. Fall back to the resumable Mac relay before any
    /// writes start instead of failing halfway through a mixed batch.
    static func executionMethod(
        preferred: CrossBucketMethod,
        mappings: [CrossBucketMapping]
    ) -> CrossBucketMethod {
        guard preferred == .serverSide else { return .relay }
        return mappings.contains(where: { $0.expectedSize > maximumSingleCopyBytes })
            ? .relay
            : .serverSide
    }

    static func destinationKey(
        destinationPrefix: String,
        sourcePrefix: String,
        rootName: String,
        sourceKey: String
    ) -> String {
        let relative = String(sourceKey.dropFirst(sourcePrefix.count))
        var destination = PathTemplate.join(
            PathTemplate.join(destinationPrefix, key: rootName),
            key: relative
        )
        if sourceKey.hasSuffix("/"), !destination.hasSuffix("/") {
            destination += "/"
        }
        return destination
    }

    static func rollbackDestinations(
        copied: [CrossBucketMapping],
        removedSources: Set<String>
    ) -> [CrossBucketMapping] {
        copied.reversed().filter { !removedSources.contains($0.sourceKey) }
    }
}
