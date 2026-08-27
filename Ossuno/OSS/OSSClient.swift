import CryptoKit
import Foundation

struct OSSUploadReceipt: Equatable, Sendable {
    var integrityVerified: Bool
    var versionID: String?
    var matchedExisting: Bool
}

struct OSSClient: Sendable {
    var credentials: OSSCredentials
    var region: String
    var endpointHost: String
    var bucket: String?
    var transport: any OSSHTTPTransport
    var retryPolicy: OSSRetryPolicy
    var retrySleeper: any OSSRetrySleeping
    private var testingVersioningStatusOverride: OSSBucketVersioningStatus?

    static let multipartThreshold: Int64 = 8 * 1024 * 1024
    static let partSize: Int64 = 8 * 1024 * 1024
    static let downloadChunkSize: Int64 = 8 * 1024 * 1024
    static let maxListPages = 30
    static let maximumSingleCopyBytes: Int64 = 5 * 1_024 * 1_024 * 1_024
    private static let minimumMultipartPartSize: Int64 = 100 * 1024
    private static let maximumMultipartParts: Int64 = 10_000
    private static let maximumRetryAfter: TimeInterval = 60

    init(
        credentials: OSSCredentials,
        region: String,
        endpointHost: String,
        bucket: String?,
        transport: any OSSHTTPTransport = URLSessionOSSHTTPTransport(),
        retryPolicy: OSSRetryPolicy = OSSRetryPolicy(),
        retrySleeper: any OSSRetrySleeping = TaskOSSRetrySleeper(),
        testingVersioningStatusOverride: OSSBucketVersioningStatus? = nil
    ) {
        self.credentials = credentials
        self.region = region
        self.endpointHost = endpointHost
        self.bucket = bucket
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.retrySleeper = retrySleeper
        self.testingVersioningStatusOverride = testingVersioningStatusOverride
    }

    var requestHost: String {
        let endpoint = OSSEndpoint.parse(endpointHost)
        guard let bucket, !bucket.isEmpty else { return endpoint.host }
        return OSSEndpoint.objectHost(endpoint: endpoint.host, bucketName: bucket)
    }

    func scoped(to bucket: OSSBucket, account: OSSAccount) -> OSSClient {
        var copy = self
        copy.bucket = bucket.name
        copy.region = account.signingRegion(for: bucket)
        copy.endpointHost = account.apiHost(for: bucket)
        return copy
    }

    func listBuckets() async throws -> [OSSBucket] {
        let response = try await perform(method: "GET", bucket: nil, key: nil)
        return try OSSXML.buckets(from: response.data)
    }

    func bucketVersioningStatus() async throws -> OSSBucketVersioningStatus {
        try await resolvedVersioningStatus()
    }

    private func resolvedVersioningStatus() async throws -> OSSBucketVersioningStatus {
        if let testingVersioningStatusOverride {
            return testingVersioningStatusOverride
        }
        guard let bucket else { throw Self.missingBucket }
        let response = try await perform(
            method: "GET",
            bucket: bucket,
            key: nil,
            query: [("versioning", "")]
        )
        return try OSSXML.bucketVersioningStatus(from: response.data)
    }

    private func requireWriteSafety(
        overwrite: Bool,
        knownStatus: OSSBucketVersioningStatus? = nil,
        allowVersionedCreate: Bool = false
    ) async throws -> OSSBucketVersioningStatus {
        let status = if let knownStatus {
            knownStatus
        } else {
            try await resolvedVersioningStatus()
        }
        let allowed = overwrite
            ? status.supportsRecoverableReplace
            : status.supportsCreateOnlyWrites || (allowVersionedCreate && status == .enabled)
        guard allowed else {
            throw OSSVersioningSafetyError(
                operation: overwrite ? .replace : .createOnly,
                status: status
            )
        }
        return status
    }

    private func requireDirectDeleteSafety(
        knownStatus: OSSBucketVersioningStatus? = nil
    ) async throws -> OSSBucketVersioningStatus {
        let status: OSSBucketVersioningStatus
        if let knownStatus {
            status = knownStatus
        } else {
            status = try await resolvedVersioningStatus()
        }
        guard status.supportsDirectDelete else {
            throw OSSVersioningSafetyError(operation: .delete, status: status)
        }
        return status
    }

    private func requireMoveSafety(
        knownStatus: OSSBucketVersioningStatus? = nil
    ) async throws -> OSSBucketVersioningStatus {
        let status = if let knownStatus {
            knownStatus
        } else {
            try await resolvedVersioningStatus()
        }
        guard status.supportsSafeMove else {
            throw OSSVersioningSafetyError(operation: .move, status: status)
        }
        return status
    }

    func listFolder(prefix: String, token: String? = nil) async throws -> ObjectListing {
        guard let bucket else { throw Self.missingBucket }
        var query: [(String, String)] = [
            ("delimiter", "/"),
            ("list-type", "2"),
            ("max-keys", "1000")
        ]
        if !prefix.isEmpty { query.append(("prefix", prefix)) }
        if let token, !token.isEmpty { query.append(("continuation-token", token)) }
        let response = try await perform(method: "GET", bucket: bucket, key: nil, query: query)
        var listing = try OSSXML.listing(from: response.data)
        listing.objects.removeAll { $0.isFolderPlaceholder }
        return listing
    }

    func listAll(prefix: String) async throws -> ObjectListing {
        var folders: [OSSFolder] = []
        var objects: [OSSObject] = []
        var token: String?
        var pages = 0
        var seenTokens = Set<String>()
        var incomplete = false
        repeat {
            pages += 1
            let page = try await listFolder(prefix: prefix, token: token)
            folders.append(contentsOf: page.folders)
            objects.append(contentsOf: page.objects)
            if page.isTruncated {
                guard let next = page.nextToken, !next.isEmpty, seenTokens.insert(next).inserted else {
                    incomplete = true
                    token = nil
                    break
                }
                token = next
            } else {
                token = nil
            }
        } while token != nil && pages < Self.maxListPages
        if token != nil { incomplete = true }
        return ObjectListing(folders: folders, objects: objects, isTruncated: incomplete, nextToken: token)
    }

    /// One recursive page of objects under `prefix`. Unlike `listFolder`, this
    /// request intentionally omits a delimiter so nested keys are returned.
    func listObjectPage(prefix: String, token: String? = nil) async throws -> ObjectListing {
        guard let bucket else { throw Self.missingBucket }
        var query: [(String, String)] = [
            ("list-type", "2"),
            ("max-keys", "1000")
        ]
        if !prefix.isEmpty { query.append(("prefix", prefix)) }
        if let token, !token.isEmpty { query.append(("continuation-token", token)) }
        let response = try await perform(method: "GET", bucket: bucket, key: nil, query: query)
        return try OSSXML.listing(from: response.data)
    }

    /// All objects under `prefix`, including nested keys. No delimiter.
    func listAllObjects(prefix: String, includePlaceholders: Bool = false) async throws -> (objects: [OSSObject], truncated: Bool) {
        var objects: [OSSObject] = []
        var token: String?
        var pages = 0
        var seenTokens = Set<String>()
        var incomplete = false
        repeat {
            pages += 1
            let listing = try await listObjectPage(prefix: prefix, token: token)
            objects.append(contentsOf: listing.objects.filter { object in
                if object.key == prefix {
                    return includePlaceholders && object.isFolderPlaceholder
                }
                if object.isFolderPlaceholder { return includePlaceholders }
                return true
            })
            if listing.isTruncated {
                guard let next = listing.nextToken, !next.isEmpty, seenTokens.insert(next).inserted else {
                    incomplete = true
                    token = nil
                    break
                }
                token = next
            } else {
                token = nil
            }
        } while token != nil && pages < Self.maxListPages
        if token != nil { incomplete = true }
        return (objects, incomplete)
    }

    func objectExists(key: String) async throws -> Bool {
        do {
            _ = try await head(key: key)
            return true
        } catch let error as OSSServiceError where error.statusCode == 404 {
            return false
        }
    }

    private func requireDestinationIdentity(
        key: String,
        expected: OSSObjectIdentity
    ) async throws {
        do {
            let current = try await head(key: key)
            guard Self.matchesObjectIdentity(current, expected: expected)
            else { throw Self.destinationChanged(key: key) }
        } catch let error as OSSServiceError where error.statusCode == 404 {
            throw Self.destinationChanged(key: key)
        }
    }

    func head(key: String, versionID: String? = nil) async throws -> ObjectHead {
        guard let bucket else { throw Self.missingBucket }
        var result = try await objectHead(bucket: bucket, key: key, versionID: versionID)
        if let versionID = versionID.flatMap(Self.exactVersionID),
           result.versionID == nil {
            // Compatible endpoints may omit the response header for an exact
            // version request. The query still supplies the immutable ID.
            result.versionID = versionID
        }
        return result
    }

    private func objectHead(
        bucket: String,
        key: String,
        versionID: String? = nil
    ) async throws -> ObjectHead {
        let query = versionID.flatMap { $0.isEmpty ? nil : [("versionId", $0)] } ?? []
        let response = try await perform(
            method: "HEAD",
            bucket: bucket,
            key: key,
            query: query
        )
        let headers = response.headers
        var metadata: [String: String] = [:]
        for (key, value) in headers {
            let lower = key.lowercased()
            guard lower.hasPrefix("x-oss-meta-") else { continue }
            metadata[String(lower.dropFirst("x-oss-meta-".count))] = value
        }
        return ObjectHead(
            contentType: headers.value("Content-Type"),
            contentLength: headers.value("Content-Length").flatMap(Int64.init),
            lastModified: headers.value("Last-Modified").flatMap(OSSSigner.rfc822Date(from:)),
            etag: Self.normalizedETag(headers.value("ETag")),
            acl: headers.value("x-oss-object-acl"),
            storageClass: headers.value("x-oss-storage-class"),
            crc64: headers.value("x-oss-hash-crc64ecma").flatMap(UInt64.init),
            cacheControl: headers.value("Cache-Control"),
            contentDisposition: headers.value("Content-Disposition"),
            contentEncoding: headers.value("Content-Encoding"),
            contentLanguage: headers.value("Content-Language"),
            expires: headers.value("Expires"),
            serverSideEncryption: headers.value("x-oss-server-side-encryption"),
            serverSideEncryptionKeyID: headers.value("x-oss-server-side-encryption-key-id"),
            serverSideDataEncryption: headers.value("x-oss-server-side-data-encryption"),
            userMetadata: metadata,
            versionID: headers.value("x-oss-version-id")
        )
    }

    func getObjectACL(key: String, versionID: String? = nil) async throws -> ObjectACL {
        guard let bucket else { throw Self.missingBucket }
        var query = [("acl", "")]
        if let versionID, !versionID.isEmpty {
            query.append(("versionId", versionID))
        }
        let response = try await perform(
            method: "GET",
            bucket: bucket,
            key: key,
            query: query
        )
        // Do not fall back to a bucket/default ACL when this request is denied
        // or malformed: silently doing so would downgrade copied objects.
        return try OSSXML.objectACL(from: response.data)
    }

    func getObjectTags(key: String, versionID: String? = nil) async throws -> [OSSObjectTag] {
        guard let bucket else { throw Self.missingBucket }
        var query = [("tagging", "")]
        if let versionID, !versionID.isEmpty {
            query.append(("versionId", versionID))
        }
        let response = try await perform(
            method: "GET",
            bucket: bucket,
            key: key,
            query: query
        )
        return try OSSXML.tags(from: response.data)
    }

    func putObjectTags(
        key: String,
        tags: [OSSObjectTag],
        versionID: String? = nil
    ) async throws {
        guard let bucket else { throw Self.missingBucket }
        guard tags.count <= 10,
              tags.allSatisfy(\.isValidForOSS),
              Set(tags.map(\.key)).count == tags.count
        else {
            throw OSSServiceError(statusCode: 0, code: "InvalidTags", message: "对象标签格式无效", requestId: "")
        }
        var query = [("tagging", "")]
        let pinnedVersionID = versionID.flatMap { $0.isEmpty ? nil : $0 }
        if let pinnedVersionID { query.append(("versionId", pinnedVersionID)) }
        do {
            _ = try await perform(
                method: "PUT",
                bucket: bucket,
                key: key,
                query: query,
                headers: ["Content-Type": "application/xml"],
                body: OSSXML.taggingData(tags),
                retryMode: pinnedVersionID == nil ? .never : .idempotent
            )
        } catch {
            guard Self.isAmbiguousWriteFailure(error) else { throw error }
            throw Self.writeOutcomeUncertain(key: key, underlying: error)
        }
    }

    @discardableResult
    func replaceMetadata(
        key: String,
        properties: OSSObjectProperties,
        expected: OSSObjectSnapshot? = nil
    ) async throws -> String? {
        guard let bucket else { throw Self.missingBucket }
        let source: OSSObjectSnapshot
        if let expected {
            guard try await objectMatchesSnapshot(key: key, expected: expected) else {
                throw Self.destinationChanged(key: key)
            }
            source = expected
        } else {
            source = try await objectSnapshot(key: key)
        }
        var headers: [String: String] = [:]
        if !properties.contentType.isEmpty {
            headers["Content-Type"] = properties.contentType
        } else if let contentType = source.head.contentType, !contentType.isEmpty {
            headers["Content-Type"] = contentType
        }
        if !properties.cacheControl.isEmpty { headers["Cache-Control"] = properties.cacheControl }
        if !properties.contentDisposition.isEmpty { headers["Content-Disposition"] = properties.contentDisposition }
        let contentLanguage = properties.contentLanguage.isEmpty
            ? source.head.contentLanguage
            : properties.contentLanguage
        if let contentLanguage, !contentLanguage.isEmpty {
            headers["Content-Language"] = contentLanguage
        }
        let expires = properties.expires.isEmpty ? source.head.expires : properties.expires
        if let expires, !expires.isEmpty { headers["Expires"] = expires }
        if let contentEncoding = source.head.contentEncoding, !contentEncoding.isEmpty {
            headers["Content-Encoding"] = contentEncoding
        }
        for (key, value) in properties.userMetadata {
            let normalized = key.lowercased().hasPrefix("x-oss-meta-")
                ? key.lowercased()
                : "x-oss-meta-\(key.lowercased())"
            headers[normalized] = value
        }
        return try await copyObject(
            fromBucket: bucket,
            sourceKey: key,
            to: key,
            acl: source.acl,
            sourceETag: source.etag,
            sourceVersionID: source.head.versionID,
            storageClass: source.head.storageClass,
            serverSideEncryption: source.head.serverSideEncryption,
            serverSideEncryptionKeyID: source.head.serverSideEncryptionKeyID,
            serverSideDataEncryption: source.head.serverSideDataEncryption,
            requireCommittedVersionID: true,
            replacingTags: source.tags,
            replacingMetadata: headers,
            expectedDestination: source.head.identity
        )
    }

    @discardableResult
    func putObject(
        key: String,
        fileURL: URL,
        contentType: String,
        acl: ObjectACL,
        properties: OSSObjectProperties? = nil,
        contentEncoding: String? = nil,
        storageClass: String? = nil,
        serverSideEncryption: String? = nil,
        serverSideEncryptionKeyID: String? = nil,
        serverSideDataEncryption: String? = nil,
        expectedDestination: OSSObjectIdentity? = nil,
        allowVersionedCreate: Bool = false,
        overwrite: Bool = false,
        speedLimit: TransferSpeedLimit = .unlimited,
        checkpoint: MultipartUploadCheckpoint? = nil,
        onCheckpoint: (@Sendable (MultipartUploadCheckpoint?) -> Void)? = nil,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> Bool {
        try await putObjectWithReceipt(
            key: key,
            fileURL: fileURL,
            contentType: contentType,
            acl: acl,
            properties: properties,
            contentEncoding: contentEncoding,
            storageClass: storageClass,
            serverSideEncryption: serverSideEncryption,
            serverSideEncryptionKeyID: serverSideEncryptionKeyID,
            serverSideDataEncryption: serverSideDataEncryption,
            expectedDestination: expectedDestination,
            allowVersionedCreate: allowVersionedCreate,
            overwrite: overwrite,
            speedLimit: speedLimit,
            checkpoint: checkpoint,
            onCheckpoint: onCheckpoint,
            onProgress: onProgress
        ).integrityVerified
    }

    func putObjectWithReceipt(
        key: String,
        fileURL: URL,
        contentType: String,
        acl: ObjectACL,
        properties: OSSObjectProperties? = nil,
        contentEncoding: String? = nil,
        storageClass: String? = nil,
        serverSideEncryption: String? = nil,
        serverSideEncryptionKeyID: String? = nil,
        serverSideDataEncryption: String? = nil,
        expectedDestination: OSSObjectIdentity? = nil,
        allowVersionedCreate: Bool = false,
        overwrite: Bool = false,
        speedLimit: TransferSpeedLimit = .unlimited,
        checkpoint: MultipartUploadCheckpoint? = nil,
        onCheckpoint: (@Sendable (MultipartUploadCheckpoint?) -> Void)? = nil,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> OSSUploadReceipt {
        guard let bucket else { throw Self.missingBucket }
        guard overwrite || expectedDestination == nil else {
            throw Self.invalidDestinationCondition
        }
        _ = try await requireWriteSafety(
            overwrite: overwrite,
            allowVersionedCreate: allowVersionedCreate
        )
        let sourceSnapshot = try sourceFileSnapshot(fileURL)
        let size = sourceSnapshot.size
        let adaptivePartSize = Self.transferChunkSize(
            totalBytes: size,
            defaultSize: Self.partSize,
            speedLimit: speedLimit,
            minimumSize: Self.minimumMultipartPartSize
        )
        let shouldUseMultipart = size >= Self.multipartThreshold
            || (speedLimit.bytesPerSecond != nil && size > adaptivePartSize)
        if shouldUseMultipart {
            let localCRC64 = try CRC64XZ.checksum(fileURL: fileURL)
            try ensureSourceUnchanged(fileURL, expected: sourceSnapshot)
            return try await multipartUpload(
                key: key,
                fileURL: fileURL,
                size: size,
                contentType: contentType,
                acl: acl,
                properties: properties,
                contentEncoding: contentEncoding,
                storageClass: storageClass,
                serverSideEncryption: serverSideEncryption,
                serverSideEncryptionKeyID: serverSideEncryptionKeyID,
                serverSideDataEncryption: serverSideDataEncryption,
                expectedDestination: expectedDestination,
                allowVersionedCreate: allowVersionedCreate,
                localCRC64: localCRC64,
                overwrite: overwrite,
                speedLimit: speedLimit,
                partSize: adaptivePartSize,
                sourceSnapshot: sourceSnapshot,
                checkpoint: checkpoint,
                onCheckpoint: onCheckpoint,
                onProgress: onProgress
            )
        }

        // A simple upload is bounded to less than the multipart threshold.
        // Materializing those bytes before starting URLSession prevents an
        // editor from changing the file underneath an in-flight request.
        let data = try Data(contentsOf: fileURL)
        guard data.count == size else { throw Self.sourceFileChanged }
        try ensureSourceUnchanged(fileURL, expected: sourceSnapshot)
        let localCRC64 = CRC64XZ.checksum(data)
        if !overwrite, try await objectExists(key: key) {
            throw Self.objectAlreadyExists
        }
        let commitVersioningStatus = try await requireWriteSafety(
            overwrite: overwrite,
            allowVersionedCreate: allowVersionedCreate
        )
        if let expectedDestination {
            try await requireDestinationIdentity(key: key, expected: expectedDestination)
        }
        var headers = try uploadHeaders(
            contentType: contentType,
            acl: acl,
            properties: properties,
            contentEncoding: contentEncoding,
            storageClass: storageClass,
            serverSideEncryption: serverSideEncryption,
            serverSideEncryptionKeyID: serverSideEncryptionKeyID,
            serverSideDataEncryption: serverSideDataEncryption,
            overwrite: overwrite
        )
        headers["Content-MD5"] = Self.contentMD5(data)
        let startedAt = Date()
        do {
            let response = try await perform(
                method: "PUT",
                bucket: bucket,
                key: key,
                headers: headers,
                body: data,
                onProgress: onProgress
            )
            try await TransferThrottle.wait(bytes: size, startedAt: startedAt, limit: speedLimit)
            return try await verifiedUploadReceipt(
                response: response,
                key: key,
                localCRC64: localCRC64,
                requireVersionID: commitVersioningStatus == .enabled
            )
        } catch let error as OSSServiceError where !overwrite && Self.isForbiddenOverwrite(error) {
            var conflict = Self.objectAlreadyExists
            conflict.requestId = error.requestId
            throw conflict
        } catch {
            guard Self.isAmbiguousWriteFailure(error) else { throw error }
            throw Self.writeOutcomeUncertain(key: key, underlying: error)
        }
    }

    @discardableResult
    func putData(
        key: String,
        data: Data,
        contentType: String,
        acl: ObjectACL,
        expectedDestination: OSSObjectIdentity? = nil,
        allowVersionedCreate: Bool = false,
        overwrite: Bool = false
    ) async throws -> Bool {
        guard let bucket else { throw Self.missingBucket }
        guard overwrite || expectedDestination == nil else {
            throw Self.invalidDestinationCondition
        }
        _ = try await requireWriteSafety(
            overwrite: overwrite,
            allowVersionedCreate: allowVersionedCreate
        )
        let localCRC64 = CRC64XZ.checksum(data)
        if !overwrite, try await objectExists(key: key) {
            throw Self.objectAlreadyExists
        }
        let commitVersioningStatus = try await requireWriteSafety(
            overwrite: overwrite,
            allowVersionedCreate: allowVersionedCreate
        )
        if let expectedDestination {
            try await requireDestinationIdentity(key: key, expected: expectedDestination)
        }
        var headers = ["Content-Type": contentType]
        if acl != .default {
            headers["x-oss-object-acl"] = acl.rawValue
        }
        if !overwrite {
            headers["x-oss-forbid-overwrite"] = "true"
        }
        headers["Content-MD5"] = Self.contentMD5(data)
        do {
            let response = try await perform(method: "PUT", bucket: bucket, key: key, headers: headers, body: data)
            return try await verifiedUploadReceipt(
                response: response,
                key: key,
                localCRC64: localCRC64,
                requireVersionID: commitVersioningStatus == .enabled
            ).integrityVerified
        } catch let error as OSSServiceError where !overwrite && Self.isForbiddenOverwrite(error) {
            var conflict = Self.objectAlreadyExists
            conflict.requestId = error.requestId
            throw conflict
        } catch {
            guard Self.isAmbiguousWriteFailure(error) else { throw error }
            throw Self.writeOutcomeUncertain(key: key, underlying: error)
        }
    }

    @discardableResult
    func deleteObject(
        key: String,
        versionID: String? = nil,
        versioningStatus: OSSBucketVersioningStatus? = nil
    ) async throws -> OSSDeleteReceipt {
        guard let bucket else { throw Self.missingBucket }
        if let suppliedVersionID = versionID,
           !suppliedVersionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let versionID = Self.exactVersionID(suppliedVersionID) else {
                throw Self.invalidExactVersionID(key: key)
            }
            let response = try await deleteExactVersion(
                bucket: bucket,
                key: key,
                versionID: versionID,
                checksCancellation: true
            )
            return OSSDeleteReceipt(
                key: key,
                isDeleteMarker: response?.headers.value("x-oss-delete-marker")?.lowercased() == "true",
                versionID: response?.headers.value("x-oss-version-id")
            )
        }
        if let versioningStatus {
            _ = try await requireDirectDeleteSafety(knownStatus: versioningStatus)
        }
        // Re-read immediately before a key-scoped DELETE. A cached Disabled
        // status can become Suspended, where deleting the null version is not
        // safely recoverable.
        _ = try await requireDirectDeleteSafety()
        let response: HTTPResponse
        do {
            response = try await perform(
                method: "DELETE",
                bucket: bucket,
                key: key,
                retryMode: .never
            )
        } catch {
            guard Self.isAmbiguousWriteFailure(error) else { throw error }
            throw Self.deleteOutcomeUncertain(key: key, versionID: nil, underlying: error)
        }
        return OSSDeleteReceipt(
            key: key,
            isDeleteMarker: response.headers.value("x-oss-delete-marker")?.lowercased() == "true",
            versionID: response.headers.value("x-oss-version-id")
        )
    }

    @discardableResult
    func copyObject(
        from sourceKey: String,
        to destKey: String,
        overwrite: Bool = true,
        acl: ObjectACL = .default,
        sourceETag: String? = nil,
        sourceVersionID: String? = nil,
        storageClass: String? = nil,
        serverSideEncryption: String? = nil,
        serverSideEncryptionKeyID: String? = nil,
        serverSideDataEncryption: String? = nil,
        allowVersionedCreate: Bool = false,
        requireCommittedVersionID: Bool = false,
        replacingTags: [OSSObjectTag]? = nil,
        expectedDestination: OSSObjectIdentity? = nil,
        versioningStatus: OSSBucketVersioningStatus? = nil,
        preflightDestination: Bool = true
    ) async throws -> String? {
        guard let bucket else { throw Self.missingBucket }
        return try await copyObject(
            fromBucket: bucket,
            sourceKey: sourceKey,
            to: destKey,
            overwrite: overwrite,
            acl: acl,
            sourceETag: sourceETag,
            sourceVersionID: sourceVersionID,
            storageClass: storageClass,
            serverSideEncryption: serverSideEncryption,
            serverSideEncryptionKeyID: serverSideEncryptionKeyID,
            serverSideDataEncryption: serverSideDataEncryption,
            allowVersionedCreate: allowVersionedCreate,
            requireCommittedVersionID: requireCommittedVersionID,
            replacingTags: replacingTags,
            expectedDestination: expectedDestination,
            versioningStatus: versioningStatus,
            preflightDestination: preflightDestination
        )
    }

    @discardableResult
    func copyObject(
        fromBucket sourceBucket: String,
        sourceKey: String,
        to destKey: String,
        overwrite: Bool = true,
        acl: ObjectACL = .default,
        sourceETag: String? = nil,
        sourceVersionID: String? = nil,
        storageClass: String? = nil,
        serverSideEncryption: String? = nil,
        serverSideEncryptionKeyID: String? = nil,
        serverSideDataEncryption: String? = nil,
        allowVersionedCreate: Bool = false,
        requireCommittedVersionID: Bool = false,
        replacingTags: [OSSObjectTag]? = nil,
        replacingMetadata headersToReplace: [String: String]? = nil,
        expectedDestination: OSSObjectIdentity? = nil,
        versioningStatus: OSSBucketVersioningStatus? = nil,
        preflightDestination: Bool = true
    ) async throws -> String? {
        guard let bucket else { throw Self.missingBucket }
        guard overwrite || expectedDestination == nil else {
            throw Self.invalidDestinationCondition
        }
        _ = try await requireWriteSafety(
            overwrite: overwrite,
            knownStatus: versioningStatus,
            allowVersionedCreate: allowVersionedCreate
        )
        if !overwrite, preflightDestination, try await objectExists(key: destKey) {
            throw Self.objectAlreadyExists
        }
        var source = "/" + OSSSigner.uriEncode(sourceBucket, encodeSlash: true)
            + "/" + OSSSigner.uriEncode(sourceKey, encodeSlash: false)
        if let sourceVersionID, !sourceVersionID.isEmpty {
            source += "?versionId=" + OSSSigner.uriEncode(sourceVersionID, encodeSlash: true)
        }
        var headers = [
            "x-oss-copy-source": source,
            "x-oss-metadata-directive": "COPY",
            "x-oss-tagging-directive": "Copy"
        ]
        if !overwrite {
            headers["x-oss-forbid-overwrite"] = "true"
        }
        if acl != .default {
            headers["x-oss-object-acl"] = acl.rawValue
        }
        if let sourceETag, !sourceETag.isEmpty {
            guard let sourceETag = Self.normalizedETag(sourceETag) else {
                throw Self.invalidETag
            }
            headers["x-oss-copy-source-if-match"] = Self.quotedETag(sourceETag)
        }
        if let storageClass, !storageClass.isEmpty {
            headers["x-oss-storage-class"] = storageClass
        }
        if let serverSideEncryption, !serverSideEncryption.isEmpty {
            headers["x-oss-server-side-encryption"] = serverSideEncryption
        }
        if let serverSideEncryptionKeyID, !serverSideEncryptionKeyID.isEmpty {
            headers["x-oss-server-side-encryption-key-id"] = serverSideEncryptionKeyID
        }
        if let serverSideDataEncryption, !serverSideDataEncryption.isEmpty {
            headers["x-oss-server-side-data-encryption"] = serverSideDataEncryption
        }
        if let replacingTags {
            guard replacingTags.count <= 10,
                  replacingTags.allSatisfy(\.isValidForOSS),
                  Set(replacingTags.map(\.key)).count == replacingTags.count
            else {
                throw OSSServiceError(
                    statusCode: 0,
                    code: "InvalidTags",
                    message: "对象标签格式无效",
                    requestId: ""
                )
            }
            headers["x-oss-tagging-directive"] = "Replace"
            headers["x-oss-tagging"] = Self.taggingHeader(replacingTags)
        }
        if let headersToReplace {
            headers["x-oss-metadata-directive"] = "REPLACE"
            headers.merge(headersToReplace) { _, replacement in replacement }
        }
        guard headers.allSatisfy({ name, value in
            !name.contains("\r") && !name.contains("\n")
                && !value.contains("\r") && !value.contains("\n")
        }) else {
            throw OSSServiceError(
                statusCode: 0,
                code: "InvalidHeaders",
                message: "复制对象属性不能包含换行",
                requestId: ""
            )
        }
        let commitVersioningStatus = try await requireWriteSafety(
            overwrite: overwrite,
            allowVersionedCreate: allowVersionedCreate
        )
        if let expectedDestination {
            // This HEAD is intentionally the last network operation before the
            // mutating COPY. OSS has no destination If-Match for CopyObject.
            try await requireDestinationIdentity(key: destKey, expected: expectedDestination)
        }
        do {
            let response = try await perform(
                method: "PUT",
                bucket: bucket,
                key: destKey,
                headers: headers
            )
            let versionID = Self.exactVersionID(response.headers.value("x-oss-version-id"))
            let versionRequired = requireCommittedVersionID
                || (allowVersionedCreate && commitVersioningStatus == .enabled)
            guard !versionRequired || versionID != nil
            else {
                throw CloudObjectOperationError.copyOutcomeUncertain(destination: destKey)
            }
            return versionID
        } catch {
            guard Self.isAmbiguousWriteFailure(error) else { throw error }
            // Matching only size/CRC cannot distinguish a newly committed copy
            // from an older same-content object with different ACL, tags, or
            // metadata. Preserve both source and destination and make the
            // uncertain outcome explicit instead of guessing or repeating PUT.
            throw CloudObjectOperationError.copyOutcomeUncertain(destination: destKey)
        }
    }

    @discardableResult
    func renameObject(
        from sourceKey: String,
        to destKey: String,
        overwrite: Bool
    ) async throws -> OSSObjectIdentity {
        let versioningStatus = try await requireMoveSafety()
        let sourceSnapshot = try await objectSnapshot(key: sourceKey)
        guard let sourceVersionID = sourceSnapshot.head.versionID,
              !sourceVersionID.isEmpty,
              sourceVersionID.caseInsensitiveCompare("null") != .orderedSame
        else { throw Self.missingSourceIdentity(key: sourceKey) }
        guard let sourceSize = sourceSnapshot.head.contentLength else {
            throw Self.missingSourceIdentity(key: sourceKey)
        }
        guard sourceSize <= Self.maximumSingleCopyBytes else {
            throw Self.copyObjectTooLarge(key: sourceKey)
        }
        let destinationVersionID = try await copyObject(
            from: sourceKey,
            to: destKey,
            overwrite: overwrite,
            acl: sourceSnapshot.acl,
            sourceETag: sourceSnapshot.etag,
            sourceVersionID: sourceVersionID,
            storageClass: sourceSnapshot.head.storageClass,
            serverSideEncryption: sourceSnapshot.head.serverSideEncryption,
            serverSideEncryptionKeyID: sourceSnapshot.head.serverSideEncryptionKeyID,
            serverSideDataEncryption: sourceSnapshot.head.serverSideDataEncryption,
            allowVersionedCreate: true,
            requireCommittedVersionID: true,
            versioningStatus: versioningStatus
        )
        guard let destinationVersionID = Self.exactVersionID(destinationVersionID) else {
            throw CloudObjectOperationError.copyOutcomeUncertain(destination: destKey)
        }
        let destinationHead = try await head(key: destKey, versionID: destinationVersionID)
        guard let destinationIdentity = destinationHead.identity,
              destinationIdentity.versionID == destinationVersionID
        else {
            throw CloudObjectOperationError.copyOutcomeUncertain(destination: destKey)
        }
        do {
            try await removeMovedSource(
                sourceSnapshot,
                key: sourceKey,
                versioningStatus: versioningStatus
            )
        } catch {
            // Once source deletion starts, never remove the committed
            // destination: a lost DELETE response may mean the source is
            // already gone, and rolling back would lose the only live copy.
            let uncertainSources: Set<String> = Self.isAmbiguousWriteFailure(error)
                ? [sourceKey]
                : []
            throw CloudObjectOperationError.sourceCleanupFailed(
                failedSource: sourceKey,
                removedSources: [],
                uncertainSources: uncertainSources,
                residualDestinations: [destKey]
            )
        }
        return destinationIdentity
    }

    func copyPrefix(from sourcePrefix: String, to destinationPrefix: String) async throws {
        let mappings = try await prefixMappings(from: sourcePrefix, to: destinationPrefix)
        try await performCloudOperation(mappings, mode: .copy)
    }

    func movePrefix(from sourcePrefix: String, to destinationPrefix: String) async throws {
        let mappings = try await prefixMappings(from: sourcePrefix, to: destinationPrefix)
        try await performCloudOperation(mappings, mode: .move)
    }

    func prefixMappings(from sourcePrefix: String, to destinationPrefix: String) async throws -> [CloudObjectMapping] {
        let listing = try await listAllObjects(prefix: sourcePrefix, includePlaceholders: true)
        guard !listing.truncated else {
            throw CloudObjectOperationError.incompleteListing
        }
        guard !listing.objects.isEmpty else {
            throw CloudObjectOperationError.emptySource
        }
        return try CloudObjectOperation.planPrefix(
            source: sourcePrefix,
            destination: destinationPrefix,
            keys: listing.objects.map(\.key)
        )
    }

    @discardableResult
    func performCloudOperation(
        _ mappings: [CloudObjectMapping],
        mode: CloudOperationMode,
        overwrite: Bool = false,
        overwriteDestinations: Set<String>? = nil,
        expectedDestinations: [String: OSSObjectIdentity] = [:],
        expectedSources: [String: OSSObjectIdentity] = [:]
    ) async throws -> [String: OSSObjectIdentity] {
        guard !mappings.isEmpty else { throw CloudObjectOperationError.emptySource }
        try CloudObjectOperation.validate(mappings)

        // An explicit allowlist takes precedence over the compatibility Bool.
        // This lets a caller authorize only destinations it has backed up;
        // another destination appearing between the caller's scan and this
        // lower-level preflight remains protected from overwrite.
        func canOverwrite(_ mapping: CloudObjectMapping) -> Bool {
            expectedDestinations[mapping.destinationKey] != nil
                || (overwriteDestinations?.contains(mapping.destinationKey) ?? overwrite)
        }

        let versioningStatus = try await resolvedVersioningStatus()
        if mode == .move {
            _ = try await requireMoveSafety(knownStatus: versioningStatus)
        }
        for overwriteIntent in Set(mappings.map(canOverwrite)) {
            _ = try await requireWriteSafety(
                overwrite: overwriteIntent,
                knownStatus: versioningStatus,
                // This batch records every response version and only ever
                // rolls back that exact version, so an Enabled-bucket create
                // is recoverable for both copy and move.
                allowVersionedCreate: true
            )
        }

        var initiallyExisting = Set<String>()
        var destinationIdentities: [String: OSSObjectIdentity] = [:]
        for mapping in mappings {
            try Task.checkCancellation()
            do {
                let current = try await head(key: mapping.destinationKey)
                initiallyExisting.insert(mapping.destinationKey)
                if !canOverwrite(mapping) {
                    throw CloudObjectOperationError.destinationExists(mapping.destinationKey)
                }
                guard let currentIdentity = current.identity else {
                    throw Self.destinationChanged(key: mapping.destinationKey)
                }
                if let expected = expectedDestinations[mapping.destinationKey] {
                    guard Self.matchesObjectIdentity(current, expected: expected) else {
                        throw Self.destinationChanged(key: mapping.destinationKey)
                    }
                    destinationIdentities[mapping.destinationKey] = expected
                } else {
                    destinationIdentities[mapping.destinationKey] = currentIdentity
                }
            } catch let error as OSSServiceError where error.statusCode == 404 {
                guard expectedDestinations[mapping.destinationKey] == nil else {
                    throw Self.destinationChanged(key: mapping.destinationKey)
                }
            }
        }

        // Bind every server-side copy to a concrete source snapshot before the
        // first PUT. Besides preventing mixed-version batches, this also keeps
        // ACL, storage class, and server-side encryption stable across moves.
        var sourceSnapshots: [String: OSSObjectSnapshot] = [:]
        for mapping in mappings where sourceSnapshots[mapping.sourceKey] == nil {
            try Task.checkCancellation()
            let snapshot = try await objectSnapshot(
                key: mapping.sourceKey
            )
            if mode == .move {
                guard let versionID = snapshot.head.versionID,
                      !versionID.isEmpty,
                      versionID.caseInsensitiveCompare("null") != .orderedSame
                else { throw Self.missingSourceIdentity(key: mapping.sourceKey) }
            }
            sourceSnapshots[mapping.sourceKey] = snapshot
        }

        for mapping in mappings {
            guard let expected = expectedSources[mapping.sourceKey] else { continue }
            guard let snapshot = sourceSnapshots[mapping.sourceKey],
                  Self.matchesObjectIdentity(snapshot.head, expected: expected)
            else {
                throw Self.sourceObjectChanged(key: mapping.sourceKey)
            }
        }

        for mapping in mappings {
            guard let size = sourceSnapshots[mapping.sourceKey]?.head.contentLength else {
                throw Self.missingSourceIdentity(key: mapping.sourceKey)
            }
            guard size <= Self.maximumSingleCopyBytes else {
                throw Self.copyObjectTooLarge(key: mapping.sourceKey)
            }
        }

        // A destination may also be a later source (A→B, B→C). Since all
        // source snapshots are captured before the first PUT, the plan is safe
        // only when that later source is pinned to an immutable version.
        let sourceKeys = Set(mappings.map(\.sourceKey))
        for mapping in mappings where sourceKeys.contains(mapping.destinationKey) {
            guard let overlap = sourceSnapshots[mapping.destinationKey],
                  Self.exactVersionID(overlap.head.versionID) != nil
            else {
                throw Self.mutableSourceOverlap(key: mapping.destinationKey)
            }
        }

        var copied: [CloudObjectMapping] = []
        var destinationVersions: [String: String] = [:]
        var committedDestinationIdentities: [String: OSSObjectIdentity] = [:]
        var attemptedMapping: CloudObjectMapping?
        do {
            for mapping in mappings {
                try Task.checkCancellation()
                attemptedMapping = mapping
                guard let sourceSnapshot = sourceSnapshots[mapping.sourceKey] else {
                    throw Self.missingSourceIdentity(key: mapping.sourceKey)
                }
                let versionID = try await copyObject(
                    from: mapping.sourceKey,
                    to: mapping.destinationKey,
                    overwrite: canOverwrite(mapping),
                    acl: sourceSnapshot.acl,
                    sourceETag: sourceSnapshot.etag,
                    sourceVersionID: sourceSnapshot.head.versionID,
                    storageClass: sourceSnapshot.head.storageClass,
                    serverSideEncryption: sourceSnapshot.head.serverSideEncryption,
                    serverSideEncryptionKeyID: sourceSnapshot.head.serverSideEncryptionKeyID,
                    serverSideDataEncryption: sourceSnapshot.head.serverSideDataEncryption,
                    allowVersionedCreate: true,
                    requireCommittedVersionID: versioningStatus == .enabled,
                    expectedDestination: destinationIdentities[mapping.destinationKey],
                    versioningStatus: versioningStatus,
                    preflightDestination: false
                )
                if mode == .move, Self.exactVersionID(versionID) == nil {
                    throw CloudObjectOperationError.copyOutcomeUncertain(
                        destination: mapping.destinationKey
                    )
                }
                copied.append(mapping)
                if let versionID = Self.exactVersionID(versionID) {
                    destinationVersions[mapping.destinationKey] = versionID
                    let committedHead = try await head(
                        key: mapping.destinationKey,
                        versionID: versionID
                    )
                    guard let identity = committedHead.identity,
                          identity.versionID == versionID
                    else {
                        throw CloudObjectOperationError.copyOutcomeUncertain(
                            destination: mapping.destinationKey
                        )
                    }
                    committedDestinationIdentities[mapping.destinationKey] = identity
                }
                attemptedMapping = nil
            }
        } catch {
            let residualDestinations = await rollbackCreatedDestinations(
                copied.reversed(),
                destinationVersions: destinationVersions
            )
            // A committed version with an exact response version ID is rolled
            // back by deleting only that version, even when the key existed
            // before the operation. Report an existing destination as modified
            // only when exact rollback was impossible or failed.
            let modifiedExistingDestinations = residualDestinations.intersection(
                initiallyExisting
            )
            var uncertainDestinations = Set<String>()
            if let cloudError = error as? CloudObjectOperationError,
               case .copyOutcomeUncertain(let destination) = cloudError {
                uncertainDestinations.insert(destination)
            } else if Self.isAmbiguousWriteFailure(error), let attemptedMapping {
                uncertainDestinations.insert(attemptedMapping.destinationKey)
            }
            throw CloudObjectOperationError.copyPhaseFailed(
                operation: error.localizedDescription,
                modifiedExistingDestinations: modifiedExistingDestinations,
                residualDestinations: residualDestinations,
                uncertainDestinations: uncertainDestinations
            )
        }

        guard mode == .move else { return committedDestinationIdentities }
        var removedSources: Set<String> = []
        for mapping in mappings.sorted(by: { $0.sourceKey.count > $1.sourceKey.count }) {
            do {
                guard let sourceSnapshot = sourceSnapshots[mapping.sourceKey] else {
                    throw Self.missingSourceIdentity(key: mapping.sourceKey)
                }
                try await removeMovedSource(
                    sourceSnapshot,
                    key: mapping.sourceKey,
                    versioningStatus: versioningStatus
                )
                removedSources.insert(mapping.sourceKey)
            } catch {
                let unfinished = mappings.filter { !removedSources.contains($0.sourceKey) }
                let uncertainSources: Set<String> = Self.isAmbiguousWriteFailure(error)
                    ? [mapping.sourceKey]
                    : []
                throw CloudObjectOperationError.sourceCleanupFailed(
                    failedSource: mapping.sourceKey,
                    removedSources: removedSources,
                    uncertainSources: uncertainSources,
                    residualDestinations: Set(unfinished.map(\.destinationKey))
                )
            }
        }
        return committedDestinationIdentities
    }

    /// Rollback must never issue an unversioned DELETE. A nil version means a
    /// concurrent writer could already own the current key, so preserve it and
    /// surface that destination as residual state for explicit user recovery.
    /// Exact version deletion is safe for both new and previously existing keys:
    /// it removes only the version committed by this operation and cannot erase
    /// a newer concurrent version.
    private func rollbackCreatedDestinations<S: Sequence>(
        _ mappings: S,
        destinationVersions: [String: String]
    ) async -> Set<String> where S.Element == CloudObjectMapping {
        var residualDestinations = Set<String>()
        for mapping in mappings {
            guard let versionID = Self.exactVersionID(
                destinationVersions[mapping.destinationKey]
            ) else {
                residualDestinations.insert(mapping.destinationKey)
                continue
            }
            do {
                try await deleteCommittedVersion(
                    key: mapping.destinationKey,
                    versionID: versionID
                )
            } catch {
                residualDestinations.insert(mapping.destinationKey)
            }
        }
        return residualDestinations
    }

    private func deleteCommittedVersion(key: String, versionID: String) async throws {
        guard let bucket else { throw Self.missingBucket }
        guard let versionID = Self.exactVersionID(versionID) else {
            throw Self.invalidExactVersionID(key: key)
        }
        _ = try await deleteExactVersion(
            bucket: bucket,
            key: key,
            versionID: versionID,
            checksCancellation: false
        )
    }

    /// An immutable version ID makes DELETE idempotent. If a lost first
    /// response is followed by 404, the requested version is confirmed absent.
    private func deleteExactVersion(
        bucket: String,
        key: String,
        versionID: String,
        checksCancellation: Bool
    ) async throws -> HTTPResponse? {
        do {
            return try await perform(
                method: "DELETE",
                bucket: bucket,
                key: key,
                query: [("versionId", versionID)],
                checksCancellation: checksCancellation,
                retryMode: .idempotent
            )
        } catch let error as OSSServiceError where error.statusCode == 404 {
            return nil
        } catch {
            guard Self.isAmbiguousWriteFailure(error) else { throw error }
            throw Self.deleteOutcomeUncertain(
                key: key,
                versionID: versionID,
                underlying: error
            )
        }
    }

    @discardableResult
    func download(
        key: String,
        to destination: URL,
        within root: URL? = nil,
        process: String? = nil,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> Bool {
        guard let bucket else { throw Self.missingBucket }
        if let root {
            try FileSafety.validate(destination: destination, root: root)
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw OSSServiceError(
                statusCode: 0,
                code: "LocalFileExists",
                message: "本地已有同名文件，未覆盖",
                requestId: ""
            )
        }
        var query: [(String, String)] = []
        if let process, !process.isEmpty {
            query.append(("x-oss-process", process))
        }
        let response = try await perform(
            method: "GET",
            bucket: bucket,
            key: key,
            query: query,
            downloadTo: destination,
            downloadRoot: root,
            onProgress: onProgress,
            // The server's CRC64 header describes the ORIGINAL object, not the
            // processed result, so integrity checks would always fail here.
            verifyDownloadIntegrity: (process ?? "").isEmpty
        )
        return response.headers.value("x-oss-hash-crc64ecma") != nil
    }

    @discardableResult
    func downloadResumable(
        key: String,
        to destination: URL,
        within root: URL,
        expectedSize: Int64,
        expectedETag: String? = nil,
        expectedVersionID: String? = nil,
        overwrite: Bool = false,
        speedLimit: TransferSpeedLimit = .unlimited,
        checkpoint suppliedCheckpoint: RangeDownloadCheckpoint? = nil,
        beforeReplacingExisting: (@Sendable () throws -> Void)? = nil,
        onCheckpoint: (@Sendable (RangeDownloadCheckpoint?) -> Void)? = nil,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> Bool {
        guard let bucket else { throw Self.missingBucket }
        try FileSafety.validate(destination: destination, root: root)
        let destinationExists = FileManager.default.fileExists(atPath: destination.path)
        if destinationExists, !overwrite {
            throw OSSServiceError(
                statusCode: 0,
                code: "LocalFileExists",
                message: "本地已有同名文件，未覆盖",
                requestId: ""
            )
        }
        let remote = try await head(key: key)
        let total = remote.contentLength ?? expectedSize
        guard let remoteETag = remote.etag, !remoteETag.isEmpty,
              let remoteCRC64 = remote.crc64
        else {
            throw OSSServiceError(
                statusCode: 0,
                code: "MissingRemoteIdentity",
                message: "OSS 未返回 ETag/CRC64，无法安全执行分片下载",
                requestId: ""
            )
        }
        if let expectedETag, !Self.matchesETag(remoteETag, expected: expectedETag) {
            throw Self.remoteObjectChanged
        }
        if let expectedVersionID,
           !expectedVersionID.isEmpty,
           remote.versionID != expectedVersionID {
            throw Self.remoteObjectChanged
        }
        guard total >= 0, expectedSize <= 0 || total == expectedSize else {
            throw OSSServiceError(
                statusCode: 0,
                code: "RemoteObjectChanged",
                message: "云端文件已发生变化，请重新开始下载",
                requestId: ""
            )
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let transferChunkSize = Self.transferChunkSize(
            totalBytes: total,
            defaultSize: Self.downloadChunkSize,
            speedLimit: speedLimit,
            minimumSize: 64 * 1024
        )

        let partialDirectory = destination.deletingLastPathComponent()
        let suppliedName = suppliedCheckpoint?.partialFileName ?? ""
        let suppliedURL = partialDirectory.appending(path: suppliedName)
        let suppliedSize = (try? suppliedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        var state: RangeDownloadCheckpoint
        if let suppliedCheckpoint,
           suppliedCheckpoint.bucketName == bucket,
           suppliedCheckpoint.objectKey == key,
           suppliedCheckpoint.expectedSize == total,
           suppliedCheckpoint.etag == remote.etag,
           suppliedCheckpoint.chunkSize == transferChunkSize,
           suppliedCheckpoint.completedBytes >= 0,
           suppliedCheckpoint.completedBytes <= total,
           suppliedCheckpoint.completedBytes == total || suppliedCheckpoint.completedBytes % transferChunkSize == 0,
           Self.isOwnedPartialFileName(suppliedCheckpoint.partialFileName),
           suppliedSize == suppliedCheckpoint.completedBytes {
            state = suppliedCheckpoint
        } else {
            // The old checkpoint is unusable (etag/size changed, partial
            // missing). Remove its stale .partial file so it doesn't leak
            // next to the fresh one.
            if let suppliedCheckpoint, Self.isOwnedPartialFileName(suppliedCheckpoint.partialFileName) {
                try? FileManager.default.removeItem(
                    at: partialDirectory.appending(path: suppliedCheckpoint.partialFileName)
                )
            }
            state = RangeDownloadCheckpoint(
                bucketName: bucket,
                objectKey: key,
                expectedSize: total,
                etag: remote.etag,
                chunkSize: transferChunkSize,
                completedBytes: 0,
                partialFileName: ".ossuno-\(UUID().uuidString).partial"
            )
            let partial = partialDirectory.appending(path: state.partialFileName)
            guard FileManager.default.createFile(atPath: partial.path, contents: Data()) else {
                throw OSSServiceError(statusCode: 0, code: "PartialFile", message: "无法创建下载临时文件", requestId: "")
            }
        }

        let partial = partialDirectory.appending(path: state.partialFileName)
        onCheckpoint?(state)
        onProgress?(state.completedBytes, total)
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.seekToEnd()
        while state.completedBytes < total {
            try Task.checkCancellation()
            let start = state.completedBytes
            let end = min(total - 1, start + state.chunkSize - 1)
            let startedAt = Date()
            let rangeHeaders = [
                "Range": "bytes=\(start)-\(end)",
                "If-Match": Self.quotedETag(remoteETag)
            ]
            let response: HTTPResponse
            do {
                response = try await perform(
                    method: "GET",
                    bucket: bucket,
                    key: key,
                    query: remote.versionID.map { [("versionId", $0)] } ?? [],
                    headers: rangeHeaders
                )
            } catch let error as OSSServiceError where error.statusCode == 412 {
                throw Self.remoteObjectChanged
            }
            let expectedCount = Int(end - start + 1)
            guard response.status == 206,
                  response.data.count == expectedCount,
                  Self.matchesContentRange(
                    response.headers.value("Content-Range"),
                    start: start,
                    end: end,
                    total: total
                  ),
                  Self.matchesETag(response.headers.value("ETag"), expected: remoteETag)
            else {
                throw OSSServiceError(
                    statusCode: response.status,
                    code: "InvalidRangeResponse",
                    message: "下载分片范围或版本不一致，请重新开始下载",
                    requestId: response.headers.value("x-oss-request-id") ?? ""
                )
            }
            try handle.write(contentsOf: response.data)
            try handle.synchronize()
            try await TransferThrottle.wait(
                bytes: Int64(response.data.count),
                startedAt: startedAt,
                limit: speedLimit
            )
            state.completedBytes = end + 1
            onCheckpoint?(state)
            onProgress?(state.completedBytes, total)
        }
        try handle.close()

        let local = try CRC64XZ.checksum(fileURL: partial)
        guard local == remoteCRC64 else {
            throw OSSIntegrityError(localCRC64: local, serverValue: String(remoteCRC64))
        }
        try FileSafety.validate(destination: destination, root: root)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard overwrite else {
                throw OSSServiceError(statusCode: 0, code: "LocalFileExists", message: "本地已有同名文件，未覆盖", requestId: "")
            }
            try beforeReplacingExisting?()
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: destination)
        }
        onCheckpoint?(nil)
        return true
    }

    func removePartialDownload(
        checkpoint: RangeDownloadCheckpoint,
        destination: URL,
        within root: URL
    ) throws {
        try FileSafety.validate(destination: destination, root: root)
        guard Self.isOwnedPartialFileName(checkpoint.partialFileName) else { return }
        let partial = destination.deletingLastPathComponent().appending(path: checkpoint.partialFileName)
        if FileManager.default.fileExists(atPath: partial.path) {
            try FileManager.default.removeItem(at: partial)
        }
    }

    func objectData(key: String, process: String? = nil) async throws -> Data {
        guard let bucket else { throw Self.missingBucket }
        var query: [(String, String)] = []
        if let process, !process.isEmpty {
            query.append(("x-oss-process", process))
        }
        let response = try await perform(method: "GET", bucket: bucket, key: key, query: query)
        if (process ?? "").isEmpty {
            _ = try Self.verifyCRC64(
                local: CRC64XZ.checksum(response.data),
                headers: response.headers
            )
        }
        return response.data
    }

    func presignedURL(key: String, process: String? = nil, expires: Int = 3600) -> URL? {
        guard let bucket else { return nil }
        var extra: [(String, String)] = []
        if let process, !process.isEmpty {
            extra.append(("x-oss-process", process))
        }
        let query = OSSSigner.presignedQuery(
            method: "GET",
            bucket: bucket,
            key: key,
            region: region,
            credentials: credentials,
            extraQuery: extra,
            expires: expires
        )
        var items = URLComponents()
        let endpoint = OSSEndpoint.parse(endpointHost)
        items.scheme = endpoint.scheme
        items.host = requestHost
        items.port = endpoint.port
        if requestHost == endpoint.host {
            items.percentEncodedPath = "/" + OSSSigner.uriEncode(bucket, encodeSlash: true)
                + "/" + OSSSigner.uriEncode(key, encodeSlash: false)
        } else {
            items.percentEncodedPath = "/" + OSSSigner.uriEncode(key, encodeSlash: false)
        }
        items.percentEncodedQuery = query
            .map { name, value in
                OSSSigner.uriEncode(name, encodeSlash: true) + "=" + OSSSigner.uriEncode(value, encodeSlash: true)
            }
            .joined(separator: "&")
        return items.url
    }

    // MARK: - Multipart

    private func multipartUpload(
        key: String,
        fileURL: URL,
        size: Int64,
        contentType: String,
        acl: ObjectACL,
        properties: OSSObjectProperties?,
        contentEncoding: String?,
        storageClass: String?,
        serverSideEncryption: String?,
        serverSideEncryptionKeyID: String?,
        serverSideDataEncryption: String?,
        expectedDestination: OSSObjectIdentity?,
        allowVersionedCreate: Bool,
        localCRC64: UInt64,
        overwrite: Bool,
        speedLimit: TransferSpeedLimit,
        partSize: Int64,
        sourceSnapshot: SourceFileSnapshot,
        checkpoint suppliedCheckpoint: MultipartUploadCheckpoint?,
        onCheckpoint: (@Sendable (MultipartUploadCheckpoint?) -> Void)?,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSUploadReceipt {
        guard let bucket else { throw Self.missingBucket }
        if !overwrite, try await objectExists(key: key) {
            throw Self.objectAlreadyExists
        }
        let modifiedAt = sourceSnapshot.modifiedAt
        let totalParts = Int((size + partSize - 1) / partSize)

        var state: MultipartUploadCheckpoint
        if let suppliedCheckpoint,
           suppliedCheckpoint.bucketName == bucket,
           suppliedCheckpoint.objectKey == key,
           suppliedCheckpoint.sourceSize == size,
           abs(suppliedCheckpoint.sourceModifiedAt.timeIntervalSince(modifiedAt)) < 0.001,
           suppliedCheckpoint.partSize == partSize,
           !suppliedCheckpoint.uploadID.isEmpty,
           Set(suppliedCheckpoint.completedParts.map(\.number)).count == suppliedCheckpoint.completedParts.count,
           suppliedCheckpoint.completedParts.allSatisfy({
               (1...totalParts).contains($0.number) && Self.normalizedETag($0.etag) != nil
           }) {
            state = suppliedCheckpoint
        } else {
            // The checkpoint no longer matches the source file. Abort the old
            // multipart upload best-effort so its parts don't linger on OSS.
            if let suppliedCheckpoint, !suppliedCheckpoint.uploadID.isEmpty {
                try? await abortMultipartUpload(suppliedCheckpoint)
            }
            do {
                state = try await initiateMultipartUpload(
                    key: key,
                    bucket: bucket,
                    contentType: contentType,
                    acl: acl,
                    properties: properties,
                    contentEncoding: contentEncoding,
                    storageClass: storageClass,
                    serverSideEncryption: serverSideEncryption,
                    serverSideEncryptionKeyID: serverSideEncryptionKeyID,
                    serverSideDataEncryption: serverSideDataEncryption,
                    allowVersionedCreate: allowVersionedCreate,
                    overwrite: overwrite,
                    sourceSize: size,
                    sourceModifiedAt: modifiedAt,
                    partSize: partSize
                )
            } catch let error as OSSServiceError where !overwrite && Self.isForbiddenOverwrite(error) {
                var conflict = Self.objectAlreadyExists
                conflict.requestId = error.requestId
                throw conflict
            } catch {
                guard Self.isAmbiguousWriteFailure(error) else { throw error }
                throw Self.writeOutcomeUncertain(key: key, underlying: error)
            }
        }
        onCheckpoint?(state)

        var parts: [Int: MultipartCompletedPart] = [:]
        for part in state.completedParts {
            parts[part.number] = part
        }
        var transferred = parts.keys.reduce(Int64(0)) { result, number in
            let offset = Int64(number - 1) * state.partSize
            return result + min(state.partSize, max(0, size - offset))
        }
        onProgress?(transferred, size)
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var partNumber = 1
        while partNumber <= totalParts {
            if parts[partNumber] != nil {
                partNumber += 1
                continue
            }
            try Task.checkCancellation()
            try ensureSourceUnchanged(fileURL, expected: sourceSnapshot)
            let offset = Int64(partNumber - 1) * state.partSize
            let thisSize = min(state.partSize, size - offset)
            try handle.seek(toOffset: UInt64(offset))
            let chunk = try handle.read(upToCount: Int(thisSize)) ?? Data()
            guard chunk.count == Int(thisSize) else {
                throw OSSServiceError(statusCode: 0, code: "ShortRead", message: "读取上传分片失败", requestId: "")
            }
            let startedAt = Date()
            let response: HTTPResponse
            do {
                response = try await perform(
                    method: "PUT",
                    bucket: bucket,
                    key: key,
                    query: [("partNumber", String(partNumber)), ("uploadId", state.uploadID)],
                    headers: [
                        "Content-Type": contentType,
                        "Content-MD5": Self.contentMD5(chunk)
                    ],
                    body: chunk,
                    retryMode: .idempotent
                )
            } catch let error as OSSServiceError where Self.isMissingUpload(error) {
                // The upload was aborted server-side (expired lifecycle, long
                // offline). Restart from a fresh initiate instead of failing.
                try? await abortMultipartUpload(state)
                do {
                    state = try await initiateMultipartUpload(
                        key: key,
                        bucket: bucket,
                        contentType: contentType,
                        acl: acl,
                        properties: properties,
                        contentEncoding: contentEncoding,
                        storageClass: storageClass,
                        serverSideEncryption: serverSideEncryption,
                        serverSideEncryptionKeyID: serverSideEncryptionKeyID,
                        serverSideDataEncryption: serverSideDataEncryption,
                        allowVersionedCreate: allowVersionedCreate,
                        overwrite: overwrite,
                        sourceSize: size,
                        sourceModifiedAt: modifiedAt,
                        partSize: partSize
                    )
                } catch let initiateError as OSSServiceError where !overwrite && Self.isForbiddenOverwrite(initiateError) {
                    var conflict = Self.objectAlreadyExists
                    conflict.requestId = initiateError.requestId
                    throw conflict
                }
                parts = [:]
                transferred = 0
                onCheckpoint?(state)
                onProgress?(transferred, size)
                partNumber = 1
                continue
            }
            try ensureSourceUnchanged(fileURL, expected: sourceSnapshot)
            try await TransferThrottle.wait(bytes: thisSize, startedAt: startedAt, limit: speedLimit)
            _ = try Self.verifyCRC64(
                local: CRC64XZ.checksum(chunk),
                headers: response.headers
            )
            guard let etag = Self.normalizedETag(response.headers.value("ETag")) else {
                throw OSSServiceError(statusCode: response.status, code: "MissingETag", message: "分片未返回 ETag", requestId: "")
            }
            parts[partNumber] = MultipartCompletedPart(number: partNumber, etag: etag)
            state.completedParts = parts.values.sorted { $0.number < $1.number }
            onCheckpoint?(state)
            transferred += thisSize
            onProgress?(transferred, size)
            partNumber += 1
        }

        try ensureSourceUnchanged(fileURL, expected: sourceSnapshot)
        // Re-read versioning immediately before commit. The Bucket may have
        // switched to Enabled/Suspended while parts were uploading, in which
        // case OSS ignores x-oss-forbid-overwrite.
        let commitVersioningStatus = try await requireWriteSafety(
            overwrite: overwrite,
            allowVersionedCreate: allowVersionedCreate
        )
        if let expectedDestination {
            try await requireDestinationIdentity(key: key, expected: expectedDestination)
        }
        let completionBody = completeXML(parts: state.completedParts)
        var completionHeaders = [
            "Content-Type": "application/xml",
            "Content-MD5": Self.contentMD5(completionBody)
        ]
        if !overwrite {
            // OSS requires the no-overwrite guard on BOTH Initiate and
            // Complete; an object may appear while parts are uploading.
            completionHeaders["x-oss-forbid-overwrite"] = "true"
        }
        do {
            let completed = try await perform(
                method: "POST",
                bucket: bucket,
                key: key,
                query: [("uploadId", state.uploadID)],
                headers: completionHeaders,
                body: completionBody
            )
            let receipt = try await verifiedUploadReceipt(
                response: completed,
                key: key,
                localCRC64: localCRC64,
                requireVersionID: commitVersioningStatus == .enabled
            )
            onCheckpoint?(nil)
            return receipt
        } catch let error as OSSServiceError where !overwrite && Self.isForbiddenOverwrite(error) {
            // A destination appeared after Initiate. Never infer idempotence
            // from equal bytes; the existing object's ACL/metadata/tags may be
            // different. Keep the checkpoint and surface a real conflict.
            var conflict = Self.objectAlreadyExists
            conflict.requestId = error.requestId
            throw conflict
        } catch {
            guard Self.isAmbiguousCompletionFailure(error) else { throw error }
            // Complete may have committed even though its response was lost.
            // A HEAD match cannot prove this request created the object, so do
            // not clear the checkpoint or guess success.
            throw Self.writeOutcomeUncertain(key: key, underlying: error)
        }
    }

    func abortMultipartUpload(_ checkpoint: MultipartUploadCheckpoint) async throws {
        guard let bucket else { throw Self.missingBucket }
        guard checkpoint.bucketName == bucket else {
            throw OSSServiceError(statusCode: 0, code: "CheckpointBucketMismatch", message: "上传检查点不属于当前存储空间", requestId: "")
        }
        _ = try await perform(
            method: "DELETE",
            bucket: bucket,
            key: checkpoint.objectKey,
            query: [("uploadId", checkpoint.uploadID)],
            checksCancellation: false
        )
    }

    private func initiateMultipartUpload(
        key: String,
        bucket: String,
        contentType: String,
        acl: ObjectACL,
        properties: OSSObjectProperties?,
        contentEncoding: String?,
        storageClass: String?,
        serverSideEncryption: String?,
        serverSideEncryptionKeyID: String?,
        serverSideDataEncryption: String?,
        allowVersionedCreate: Bool,
        overwrite: Bool,
        sourceSize: Int64,
        sourceModifiedAt: Date,
        partSize: Int64
    ) async throws -> MultipartUploadCheckpoint {
        _ = try await requireWriteSafety(
            overwrite: overwrite,
            allowVersionedCreate: allowVersionedCreate
        )
        let initiateHeaders = try uploadHeaders(
            contentType: contentType,
            acl: acl,
            properties: properties,
            contentEncoding: contentEncoding,
            storageClass: storageClass,
            serverSideEncryption: serverSideEncryption,
            serverSideEncryptionKeyID: serverSideEncryptionKeyID,
            serverSideDataEncryption: serverSideDataEncryption,
            overwrite: overwrite
        )
        let initiated = try await perform(
            method: "POST",
            bucket: bucket,
            key: key,
            query: [("uploads", "")],
            headers: initiateHeaders
        )
        return MultipartUploadCheckpoint(
            bucketName: bucket,
            objectKey: key,
            sourceSize: sourceSize,
            sourceModifiedAt: sourceModifiedAt,
            partSize: partSize,
            uploadID: try OSSXML.uploadId(from: initiated.data),
            completedParts: []
        )
    }

    private static func isMissingUpload(_ error: OSSServiceError) -> Bool {
        error.statusCode == 404 || error.code == "NoSuchUpload"
    }

    private func completeXML(parts: [MultipartCompletedPart]) -> Data {
        OSSXML.completeMultipartUploadXML(parts: parts.map { (number: $0.number, etag: $0.etag) })
    }

    // MARK: - Transport

    private typealias HTTPResponse = OSSHTTPResult

    private enum RequestRetryMode {
        case automatic
        case idempotent
        case never

        func allowsRetry(method: String) -> Bool {
            switch self {
            case .automatic:
                method == "GET" || method == "HEAD"
            case .idempotent:
                true
            case .never:
                false
            }
        }
    }

    private static let missingBucket = OSSServiceError(
        statusCode: 0,
        code: "NoBucket",
        message: "还没有选择存储空间",
        requestId: ""
    )

    private static let objectAlreadyExists = OSSServiceError(
        statusCode: 409,
        code: "ObjectAlreadyExists",
        message: "目标已有同名对象，未覆盖",
        requestId: ""
    )

    private static let sourceFileChanged = OSSServiceError(
        statusCode: 0,
        code: "SourceFileChanged",
        message: "本地文件在上传期间发生变化，请重新上传",
        requestId: ""
    )

    private static let remoteObjectChanged = OSSServiceError(
        statusCode: 0,
        code: "RemoteObjectChanged",
        message: "云端文件已发生变化，请重新开始下载",
        requestId: ""
    )

    private static let invalidETag = OSSServiceError(
        statusCode: 0,
        code: "InvalidETag",
        message: "OSS 返回的 ETag 格式无效，已取消操作",
        requestId: ""
    )

    private static let invalidDestinationCondition = OSSServiceError(
        statusCode: 0,
        code: "InvalidDestinationCondition",
        message: "仅在明确替换对象时才能绑定目标版本",
        requestId: ""
    )

    private static func destinationChanged(key: String) -> OSSServiceError {
        OSSServiceError(
            statusCode: 0,
            code: "DestinationChanged",
            message: "目标对象在排队或传输期间发生变化，已取消提交：\(key)",
            requestId: ""
        )
    }

    private static func copyObjectTooLarge(key: String) -> OSSServiceError {
        OSSServiceError(
            statusCode: 0,
            code: "CopyObjectTooLarge",
            message: "对象超过 CopyObject 的 5 GiB 上限，已在提交前取消：\(key)",
            requestId: ""
        )
    }

    private static func mutableSourceOverlap(key: String) -> OSSServiceError {
        OSSServiceError(
            statusCode: 0,
            code: "MutableSourceOverlap",
            message: "目标会覆盖尚未复制且没有固定版本的源对象，已在提交前取消：\(key)",
            requestId: ""
        )
    }

    private func perform(
        method: String,
        bucket: String?,
        key: String?,
        query: [(String, String)] = [],
        headers extra: [String: String] = [:],
        body: Data? = nil,
        fileURL: URL? = nil,
        downloadTo: URL? = nil,
        downloadRoot: URL? = nil,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil,
        checksCancellation: Bool = true,
        verifyDownloadIntegrity: Bool = true,
        retryMode: RequestRetryMode = .automatic
    ) async throws -> HTTPResponse {
        guard let url = makeURL(bucket: bucket, key: key, query: query) else {
            throw OSSServiceError(statusCode: 0, code: "InvalidURL", message: "无法构造请求地址", requestId: "")
        }

        let httpBody: OSSHTTPBody
        if let fileURL {
            httpBody = .file(fileURL)
        } else if let body {
            httpBody = .data(body)
        } else {
            httpBody = .none
        }

        var attempt = 1
        while true {
            if checksCancellation {
                try Task.checkCancellation()
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = body != nil || fileURL != nil ? 60 * 30 : 60
            let signed = OSSSigner.signedHeaders(
                method: method,
                bucket: bucket,
                key: key,
                region: region,
                credentials: credentials,
                query: query,
                extraHeaders: extra
            )
            for (name, value) in signed {
                request.setValue(value, forHTTPHeaderField: name)
            }

            do {
                let result = try await transport.send(
                    request,
                    body: httpBody,
                    download: downloadTo != nil,
                    onProgress: onProgress
                )
                if retryMode.allowsRetry(method: method), let delay = retryPolicy.delay(
                    afterAttempt: attempt,
                    outcome: .httpStatus(result.status),
                    retryAfter: Self.retryAfterDelay(headers: result.headers)
                ) {
                    if let temporaryURL = result.temporaryDownloadURL {
                        try? FileManager.default.removeItem(at: temporaryURL)
                    }
                    try await retrySleeper.sleep(for: delay)
                    attempt += 1
                    continue
                }

                if (300...399).contains(result.status) {
                    if let temporaryURL = result.temporaryDownloadURL {
                        try? FileManager.default.removeItem(at: temporaryURL)
                    }
                    let location = result.headers.value("Location") ?? "（未提供 Location）"
                    throw OSSServiceError(
                        statusCode: result.status,
                        code: "RedirectRejected",
                        message: "OSS 签名请求拒绝自动重定向：\(location)。请直接配置最终 Endpoint。",
                        requestId: result.headers.value("x-oss-request-id") ?? ""
                    )
                }

                let http: HTTPResponse
                do {
                    http = try validated(result)
                } catch {
                    if let temporaryURL = result.temporaryDownloadURL {
                        try? FileManager.default.removeItem(at: temporaryURL)
                    }
                    throw error
                }

                if let downloadTo {
                    guard let temp = http.temporaryDownloadURL else {
                        throw OSSServiceError(statusCode: 0, code: "MissingDownload", message: "下载没有返回文件", requestId: "")
                    }
                    do {
                        if let downloadRoot {
                            try FileSafety.validate(destination: downloadTo, root: downloadRoot)
                        }
                        guard !FileManager.default.fileExists(atPath: downloadTo.path) else {
                            throw OSSServiceError(
                                statusCode: 0,
                                code: "LocalFileExists",
                                message: "本地已有同名文件，未覆盖",
                                requestId: ""
                            )
                        }
                        let localCRC64 = try CRC64XZ.checksum(fileURL: temp)
                        if verifyDownloadIntegrity {
                            _ = try Self.verifyCRC64(local: localCRC64, headers: http.headers)
                        }
                        try FileManager.default.createDirectory(at: downloadTo.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if let downloadRoot {
                            try FileSafety.validate(destination: downloadTo, root: downloadRoot)
                        }
                        // The temp file lives on the system volume while the
                        // destination can be on another one (external drive,
                        // network share); moveItem would fail with EXDEV, so
                        // copy and then delete instead.
                        try FileManager.default.copyItem(at: temp, to: downloadTo)
                        try? FileManager.default.removeItem(at: temp)
                    } catch {
                        try? FileManager.default.removeItem(at: temp)
                        throw error
                    }
                }
                return http
            } catch {
                if error is CancellationError { throw error }
                guard retryMode.allowsRetry(method: method),
                      let outcome = retryPolicy.outcome(for: error),
                      let delay = retryPolicy.delay(afterAttempt: attempt, outcome: outcome)
                else { throw error }
                try await retrySleeper.sleep(for: delay)
                attempt += 1
            }
        }
    }

    private static func verifyCRC64(
        local: UInt64,
        headers: [String: String]
    ) throws -> Bool {
        guard let serverValue = headers.value("x-oss-hash-crc64ecma") else {
            return false
        }
        guard let remote = UInt64(serverValue), remote == local else {
            throw OSSIntegrityError(localCRC64: local, serverValue: serverValue)
        }
        return true
    }

    private static func isForbiddenOverwrite(_ error: OSSServiceError) -> Bool {
        error.code == "FileAlreadyExists"
            || error.code == "ObjectAlreadyExists"
            || (error.statusCode == 409 && error.code.isEmpty)
    }

    private static func writeOutcomeUncertain(key: String, underlying: any Error) -> OSSServiceError {
        OSSServiceError(
            statusCode: 0,
            code: "WriteOutcomeUncertain",
            message: "写入响应中断，无法确认对象是否已提交：\(key)。请刷新后人工确认，系统不会自动重试或删除。",
            requestId: (underlying as? OSSServiceError)?.requestId ?? ""
        )
    }

    private static func deleteOutcomeUncertain(
        key: String,
        versionID: String?,
        underlying: any Error
    ) -> OSSServiceError {
        let version = versionID.map { "（版本 \($0)）" } ?? ""
        return OSSServiceError(
            statusCode: 0,
            code: "DeleteOutcomeUncertain",
            message: "删除响应中断，无法确认对象是否已删除：\(key)\(version)。系统不会自动删除关联目标，请刷新后人工确认。",
            requestId: (underlying as? OSSServiceError)?.requestId ?? ""
        )
    }

    private func uploadHeaders(
        contentType: String,
        acl: ObjectACL,
        properties: OSSObjectProperties?,
        contentEncoding: String?,
        storageClass: String?,
        serverSideEncryption: String?,
        serverSideEncryptionKeyID: String?,
        serverSideDataEncryption: String?,
        overwrite: Bool
    ) throws -> [String: String] {
        let resolvedContentType = properties.flatMap { properties in
            properties.contentType.isEmpty ? nil : properties.contentType
        } ?? contentType
        var headers = ["Content-Type": resolvedContentType]
        if acl != .default { headers["x-oss-object-acl"] = acl.rawValue }
        if !overwrite { headers["x-oss-forbid-overwrite"] = "true" }
        if let properties {
            if !properties.cacheControl.isEmpty { headers["Cache-Control"] = properties.cacheControl }
            if !properties.contentDisposition.isEmpty {
                headers["Content-Disposition"] = properties.contentDisposition
            }
            if !properties.contentLanguage.isEmpty {
                headers["Content-Language"] = properties.contentLanguage
            }
            if !properties.expires.isEmpty { headers["Expires"] = properties.expires }
            for (key, value) in properties.userMetadata {
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !trimmed.isEmpty else {
                    throw OSSServiceError(statusCode: 0, code: "InvalidMetadata", message: "对象元数据键不能为空", requestId: "")
                }
                let name = trimmed.hasPrefix("x-oss-meta-") ? trimmed : "x-oss-meta-\(trimmed)"
                headers[name] = value
            }
        }
        if let contentEncoding, !contentEncoding.isEmpty { headers["Content-Encoding"] = contentEncoding }
        if let storageClass, !storageClass.isEmpty { headers["x-oss-storage-class"] = storageClass }
        if let serverSideEncryption, !serverSideEncryption.isEmpty {
            headers["x-oss-server-side-encryption"] = serverSideEncryption
        }
        if let serverSideEncryptionKeyID, !serverSideEncryptionKeyID.isEmpty {
            headers["x-oss-server-side-encryption-key-id"] = serverSideEncryptionKeyID
        }
        if let serverSideDataEncryption, !serverSideDataEncryption.isEmpty {
            headers["x-oss-server-side-data-encryption"] = serverSideDataEncryption
        }
        guard headers.allSatisfy({ !$0.key.contains("\r") && !$0.key.contains("\n")
            && !$0.value.contains("\r") && !$0.value.contains("\n") })
        else {
            throw OSSServiceError(statusCode: 0, code: "InvalidHeaders", message: "对象属性不能包含换行", requestId: "")
        }
        return headers
    }

    /// CRC failure is discovered only after OSS has accepted the write. When
    /// versioning supplied the exact committed version, remove only that
    /// version before surfacing the integrity error. Never issue an unscoped
    /// delete: it could erase a newer concurrent write or the previous object
    /// of an overwrite in a non-versioned bucket.
    private func verifiedUploadReceipt(
        response: HTTPResponse,
        key: String,
        localCRC64: UInt64,
        requireVersionID: Bool = false
    ) async throws -> OSSUploadReceipt {
        do {
            let receipt = OSSUploadReceipt(
                integrityVerified: try Self.verifyCRC64(local: localCRC64, headers: response.headers),
                versionID: Self.exactVersionID(response.headers.value("x-oss-version-id")),
                matchedExisting: false
            )
            guard !requireVersionID || receipt.versionID != nil else {
                throw Self.writeOutcomeUncertain(
                    key: key,
                    underlying: OSSServiceError(
                        statusCode: response.status,
                        code: "MissingCommittedVersion",
                        message: "版本化写入未返回版本 ID",
                        requestId: response.headers.value("x-oss-request-id") ?? ""
                    )
                )
            }
            return receipt
        } catch let integrityError as OSSIntegrityError {
            guard let versionID = Self.exactVersionID(
                response.headers.value("x-oss-version-id")
            ) else {
                throw integrityError
            }
            do {
                _ = try await deleteObject(key: key, versionID: versionID)
            } catch {
                throw OSSServiceError(
                    statusCode: 0,
                    code: "IntegrityCleanupFailed",
                    message: "上传完整性校验失败，且无法清理已提交版本：\(error.localizedDescription)",
                    requestId: response.headers.value("x-oss-request-id") ?? ""
                )
            }
            throw integrityError
        }
    }

    func objectSnapshot(
        key: String,
        versionID requestedVersionID: String? = nil
    ) async throws -> OSSObjectSnapshot {
        var objectHead = try await head(key: key, versionID: requestedVersionID)
        if let requestedVersionID, !requestedVersionID.isEmpty {
            guard objectHead.versionID == nil || objectHead.versionID == requestedVersionID else {
                throw Self.sourceObjectChanged(key: key)
            }
            // Some compatible endpoints omit the response version header even
            // for an exact-version request. The request parameter is still the
            // immutable identity used for the ACL/tag reads and later delete.
            objectHead.versionID = requestedVersionID
        }
        guard let etag = objectHead.etag, !etag.isEmpty,
              objectHead.contentLength != nil
        else {
            throw Self.missingSourceIdentity(key: key)
        }
        let pinnedVersionID = requestedVersionID.flatMap { $0.isEmpty ? nil : $0 }
            ?? objectHead.versionID
        let acl = try await getObjectACL(key: key, versionID: pinnedVersionID)
        let tags = try await getObjectTags(key: key, versionID: pinnedVersionID)
        let snapshot = OSSObjectSnapshot(head: objectHead, acl: acl, tags: tags, etag: etag)

        // Without a version ID the ACL/tag reads address the mutable current
        // object. Re-read HEAD before accepting the snapshot so a concurrent
        // content/metadata replacement cannot silently produce a mixed record.
        if objectHead.versionID == nil || objectHead.versionID?.isEmpty == true {
            let confirmedHead = try await head(key: key)
            guard Self.matchesHead(confirmedHead, expected: objectHead) else {
                throw Self.sourceObjectChanged(key: key)
            }
        }
        return snapshot
    }

    func objectMatchesSnapshot(
        key: String,
        expected: OSSObjectSnapshot,
        versionID: String? = nil
    ) async throws -> Bool {
        let current = try await objectSnapshot(key: key, versionID: versionID)
        return Self.matchesSourceSnapshot(current, expected: expected)
    }

    private func removeMovedSource(
        _ snapshot: OSSObjectSnapshot,
        key: String,
        versioningStatus: OSSBucketVersioningStatus
    ) async throws {
        guard versioningStatus == .enabled,
              let versionID = snapshot.head.versionID,
              !versionID.isEmpty,
              versionID.caseInsensitiveCompare("null") != .orderedSame
        else { throw Self.missingSourceIdentity(key: key) }
        guard try await objectMatchesSnapshot(
            key: key,
            expected: snapshot,
            versionID: versionID
        ) else { throw Self.sourceObjectChanged(key: key) }
        _ = try await requireMoveSafety()
        _ = try await deleteObject(key: key, versionID: versionID)
    }

    private static func matchesSourceSnapshot(
        _ current: OSSObjectSnapshot,
        expected: OSSObjectSnapshot
    ) -> Bool {
        current.etag == expected.etag
            && current.acl == expected.acl
            && Set(current.tags) == Set(expected.tags)
            && matchesHead(current.head, expected: expected.head)
    }

    private static func matchesHead(_ current: ObjectHead, expected: ObjectHead) -> Bool {
        current.contentType == expected.contentType
            && current.contentLength == expected.contentLength
            && current.lastModified == expected.lastModified
            && current.etag == expected.etag
            && current.storageClass == expected.storageClass
            && current.crc64 == expected.crc64
            && current.cacheControl == expected.cacheControl
            && current.contentDisposition == expected.contentDisposition
            && current.contentEncoding == expected.contentEncoding
            && current.contentLanguage == expected.contentLanguage
            && current.expires == expected.expires
            && current.serverSideEncryption == expected.serverSideEncryption
            && current.serverSideEncryptionKeyID == expected.serverSideEncryptionKeyID
            && current.serverSideDataEncryption == expected.serverSideDataEncryption
            && current.userMetadata == expected.userMetadata
            && current.versionID == expected.versionID
    }

    private static func matchesObjectIdentity(
        _ current: ObjectHead,
        expected: OSSObjectIdentity
    ) -> Bool {
        current.contentLength == expected.size
            && current.versionID == expected.versionID
            && matchesETag(current.etag, expected: expected.etag)
    }

    private static func exactVersionID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.caseInsensitiveCompare("null") != .orderedSame
        else { return nil }
        return trimmed
    }

    private static func missingSourceIdentity(key: String) -> OSSServiceError {
        OSSServiceError(
            statusCode: 0,
            code: "MissingSourceIdentity",
            message: "OSS 未返回源对象版本标识，已取消操作以避免误删：\(key)",
            requestId: ""
        )
    }

    private static func invalidExactVersionID(key: String) -> OSSServiceError {
        OSSServiceError(
            statusCode: 0,
            code: "InvalidVersionID",
            message: "OSS 未返回可安全定位的版本 ID，已取消删除：\(key)",
            requestId: ""
        )
    }

    private static func sourceObjectChanged(key: String) -> OSSServiceError {
        OSSServiceError(
            statusCode: 0,
            code: "SourceObjectChanged",
            message: "源对象在复制期间发生变化，已保留源和目标：\(key)",
            requestId: ""
        )
    }

    private struct SourceFileSnapshot: Equatable {
        var size: Int64
        var modifiedAt: Date
        var systemNumber: UInt64?
        var fileNumber: UInt64?
    }

    private func sourceFileSnapshot(_ url: URL) throws -> SourceFileSnapshot {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value else {
            throw OSSServiceError(statusCode: 0, code: "InvalidSource", message: "无法读取本地文件大小", requestId: "")
        }
        return SourceFileSnapshot(
            size: size,
            modifiedAt: attributes[.modificationDate] as? Date ?? .distantPast,
            systemNumber: (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    private func ensureSourceUnchanged(_ url: URL, expected: SourceFileSnapshot) throws {
        let current = try sourceFileSnapshot(url)
        guard current.size == expected.size,
              abs(current.modifiedAt.timeIntervalSince(expected.modifiedAt)) < 0.001,
              current.systemNumber == expected.systemNumber,
              current.fileNumber == expected.fileNumber
        else { throw Self.sourceFileChanged }
    }

    private static func contentMD5(_ data: Data) -> String {
        Data(Insecure.MD5.hash(data: data)).base64EncodedString()
    }

    private static func taggingHeader(_ tags: [OSSObjectTag]) -> String {
        tags.map { tag in
            OSSSigner.uriEncode(tag.key, encodeSlash: true)
                + "="
                + OSSSigner.uriEncode(tag.value, encodeSlash: true)
        }.joined(separator: "&")
    }

    private static func transferChunkSize(
        totalBytes: Int64,
        defaultSize: Int64,
        speedLimit: TransferSpeedLimit,
        minimumSize: Int64
    ) -> Int64 {
        guard let bytesPerSecond = speedLimit.bytesPerSecond else { return defaultSize }
        let quarterSecondBurst = max(minimumSize, bytesPerSecond / 4)
        let requiredForPartLimit = max(
            minimumSize,
            (max(0, totalBytes) + maximumMultipartParts - 1) / maximumMultipartParts
        )
        return max(requiredForPartLimit, min(defaultSize, quarterSecondBurst))
    }

    private static func quotedETag(_ etag: String) -> String {
        "\"\(etag)\""
    }

    private static func matchesETag(_ response: String?, expected: String?) -> Bool {
        guard let response = normalizedETag(response),
              let expected = normalizedETag(expected)
        else { return false }
        return response == expected
    }

    /// OSS ETags are opaque single tags. Compatible endpoints sometimes omit
    /// the surrounding quotes, so accept either an unquoted token or exactly
    /// one matching quote pair, and reject weak/list/control/malformed forms.
    private static func normalizedETag(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("\r"),
              !trimmed.contains("\n"),
              !trimmed.hasPrefix("W/"),
              !trimmed.hasPrefix("w/"),
              !trimmed.contains(",")
        else { return nil }

        let startsQuoted = trimmed.first == "\""
        let endsQuoted = trimmed.last == "\""
        guard startsQuoted == endsQuoted else { return nil }
        let opaque: Substring
        if startsQuoted {
            guard trimmed.count >= 2 else { return nil }
            opaque = trimmed.dropFirst().dropLast()
        } else {
            opaque = Substring(trimmed)
        }
        guard !opaque.isEmpty,
              !opaque.contains("\""),
              !opaque.contains(where: { $0.isNewline })
        else { return nil }
        return String(opaque)
    }

    private static func matchesContentRange(
        _ value: String?,
        start: Int64,
        end: Int64,
        total: Int64
    ) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == "bytes \(start)-\(end)/\(total)"
    }

    private static func retryAfterDelay(headers: [String: String], now: Date = .now) -> Duration? {
        guard let raw = headers.value("Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        let seconds: TimeInterval?
        if let numeric = TimeInterval(raw), numeric >= 0 {
            seconds = numeric
        } else if let date = OSSSigner.rfc822Date(from: raw) {
            seconds = max(0, date.timeIntervalSince(now))
        } else {
            seconds = nil
        }
        guard let seconds else { return nil }
        return .milliseconds(Int64((min(maximumRetryAfter, seconds) * 1_000).rounded()))
    }

    private static func isAmbiguousWriteFailure(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if OSSRetryPolicy(maxAttempts: 1).outcome(for: error) != nil { return true }
        guard let service = error as? OSSServiceError else { return false }
        if service.code == "WriteOutcomeUncertain" || service.code == "DeleteOutcomeUncertain" {
            return true
        }
        return service.statusCode == 408
            || service.statusCode == 429
            || (500...599).contains(service.statusCode)
    }

    private static func isAmbiguousCompletionFailure(_ error: any Error) -> Bool {
        if isAmbiguousWriteFailure(error) { return true }
        return (error as? OSSServiceError).map(isMissingUpload) ?? false
    }

    private func validated(_ response: HTTPResponse) throws -> HTTPResponse {
        if !(200...299).contains(response.status) {
            var error = OSSXML.parseError(response.data, status: response.status)
            if error.requestId.isEmpty {
                error.requestId = response.headers.value("x-oss-request-id") ?? ""
            }
            throw error
        }
        return response
    }

    private func makeURL(bucket: String?, key: String?, query: [(String, String)]) -> URL? {
        var components = URLComponents()
        let endpoint = OSSEndpoint.parse(endpointHost)
        components.scheme = endpoint.scheme
        components.port = endpoint.port
        if let bucket, !bucket.isEmpty {
            let host = OSSEndpoint.objectHost(endpoint: endpoint.host, bucketName: bucket)
            components.host = host
            if host == endpoint.host {
                // Path-style endpoint (custom / OSS-compatible host): the
                // bucket goes into the path instead of the host name.
                let encodedBucket = OSSSigner.uriEncode(bucket, encodeSlash: true)
                if let key, !key.isEmpty {
                    components.percentEncodedPath = "/" + encodedBucket + "/" + OSSSigner.uriEncode(key, encodeSlash: false)
                } else {
                    components.percentEncodedPath = "/" + encodedBucket + "/"
                }
            } else if let key, !key.isEmpty {
                components.percentEncodedPath = "/" + OSSSigner.uriEncode(key, encodeSlash: false)
            } else {
                components.path = "/"
            }
        } else {
            components.host = endpoint.host
            components.path = "/"
        }
        if !query.isEmpty {
            components.percentEncodedQuery = query
                .map { name, value in
                    let encodedName = OSSSigner.uriEncode(name, encodeSlash: true)
                    if value.isEmpty { return encodedName }
                    return encodedName + "=" + OSSSigner.uriEncode(value, encodeSlash: true)
                }
                .joined(separator: "&")
        }
        return components.url
    }

    private static func isOwnedPartialFileName(_ name: String) -> Bool {
        name.hasPrefix(".ossuno-")
            && name.hasSuffix(".partial")
            && !name.contains("/")
            && !name.contains("\\")
    }
}

private extension Dictionary where Key == String, Value == String {
    func value(_ name: String) -> String? {
        let target = name.lowercased()
        return first(where: { $0.key.lowercased() == target })?.value
    }
}
