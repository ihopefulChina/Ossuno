import Foundation

/// Thin OSS REST client for the MCP server. Single-request operations only —
/// uploads stream the file via URLSession upload; large-file multipart stays
/// in the GUI app.
final class MCPOSSClient: @unchecked Sendable {
    let profile: MCPOSSProfile
    private let redirectDelegate: OSSRedirectRejectingDelegate
    private let session: URLSession

    init(profile: MCPOSSProfile, configuration: URLSessionConfiguration? = nil) {
        self.profile = profile
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 3600
        let redirectDelegate = OSSRedirectRejectingDelegate()
        self.redirectDelegate = redirectDelegate
        self.session = URLSession(
            configuration: config,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

    // MARK: - URL construction (byte-compatible with Ossuno's OSSClient.makeURL)

    private func makeURL(bucket: String?, key: String? = nil, query: [(String, String)] = []) throws -> URL {
        var components = URLComponents()
        let endpoint = OSSEndpoint.parse(profile.apiEndpoint)
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
        guard let url = components.url else {
            throw OSSServiceError(statusCode: 0, code: "InvalidURL", message: "无法构造请求 URL", requestId: "")
        }
        return url
    }

    // MARK: - Core request

    private func makeSignedRequest(
        method: String,
        bucket: String?,
        key: String? = nil,
        query: [(String, String)] = [],
        headers extraHeaders: [String: String] = [:]
    ) throws -> URLRequest {
        let url = try makeURL(bucket: bucket, key: key, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method.uppercased()
        let signed = OSSSigner.signedHeaders(
            method: method,
            bucket: bucket,
            key: key,
            region: profile.signingRegion,
            credentials: profile.credentials,
            query: query,
            extraHeaders: extraHeaders
        )
        for (name, value) in signed {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func perform(
        method: String,
        bucket: String?,
        key: String? = nil,
        query: [(String, String)] = [],
        headers extraHeaders: [String: String] = [:],
        body: Data? = nil,
        fileURL: URL? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let request = try makeSignedRequest(
            method: method,
            bucket: bucket,
            key: key,
            query: query,
            headers: extraHeaders
        )

        let data: Data
        let response: URLResponse
        do {
            if let fileURL {
                (data, response) = try await session.upload(for: request, fromFile: fileURL)
            } else if let body {
                (data, response) = try await session.upload(for: request, from: body)
            } else {
                (data, response) = try await session.data(for: request)
            }
        } catch let urlError as URLError {
            throw OSSServiceError(
                statusCode: 0,
                code: "NetworkError",
                message: "网络请求失败：\(urlError.localizedDescription)",
                requestId: ""
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw OSSServiceError(statusCode: 0, code: "InvalidResponse", message: "非 HTTP 响应", requestId: "")
        }
        if (300...399).contains(http.statusCode) {
            let location = http.value(forHTTPHeaderField: "Location") ?? "（未提供 Location）"
            throw OSSServiceError(
                statusCode: http.statusCode,
                code: "RedirectRejected",
                message: "OSS 签名请求拒绝自动重定向：\(location)。请直接配置最终 Endpoint。",
                requestId: ""
            )
        }
        guard (200...299).contains(http.statusCode) else {
            throw OSSXML.parseError(data, status: http.statusCode)
        }
        return (data, http)
    }

    // MARK: - Operations

    func listBuckets() async throws -> [OSSBucket] {
        let (data, _) = try await perform(method: "GET", bucket: nil)
        return try OSSXML.buckets(from: data)
    }

    func listObjects(
        bucket: String,
        prefix: String? = nil,
        delimiter: String? = "/",
        maxKeys: Int = 200,
        token: String? = nil
    ) async throws -> ObjectListing {
        var query: [(String, String)] = [
            ("list-type", "2"),
            ("max-keys", String(max(min(maxKeys, 1000), 1))),
        ]
        if let prefix, !prefix.isEmpty { query.append(("prefix", prefix)) }
        if let delimiter, !delimiter.isEmpty { query.append(("delimiter", delimiter)) }
        if let token, !token.isEmpty { query.append(("continuation-token", token)) }
        let (data, _) = try await perform(method: "GET", bucket: bucket, query: query)
        var listing = try OSSXML.listing(from: data)
        // Hierarchical mode shows folders separately; drop the "folder/"
        // placeholder objects so AI doesn't see them twice (matches the GUI).
        if delimiter != nil {
            listing.objects.removeAll { $0.isFolderPlaceholder }
        }
        return listing
    }

    func bucketVersioningStatus(bucket: String) async throws -> OSSBucketVersioningStatus {
        let (data, _) = try await perform(
            method: "GET",
            bucket: bucket,
            query: [("versioning", "")]
        )
        return try OSSXML.bucketVersioningStatus(from: data)
    }

    struct UploadResult: Sendable {
        var bucket: String
        var key: String
        var size: Int64
        var etag: String
        var url: URL
    }

    func uploadFile(
        bucket: String,
        key: String,
        fileURL: URL,
        contentType: String?,
        overwrite: Bool = false
    ) async throws -> UploadResult {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        var headers: [String: String] = [:]
        if let contentType = try MCPHTTPSafety.validatedContentType(contentType) {
            headers["Content-Type"] = contentType
        }
        if !overwrite {
            let versioningStatus: OSSBucketVersioningStatus
            do {
                versioningStatus = try await bucketVersioningStatus(bucket: bucket)
            } catch let error as OSSServiceError {
                throw OSSServiceError(
                    statusCode: error.statusCode,
                    code: "VersioningStatusUnavailable",
                    message: "无法确认 Bucket 版本控制状态，已安全拒绝上传。请授予 oss:GetBucketVersioning 权限后重试；只有用户明确授权覆盖时才能传 overwrite=true。原始错误：\(error.message.isEmpty ? error.code : error.message)",
                    requestId: error.requestId
                )
            } catch {
                throw OSSServiceError(
                    statusCode: 0,
                    code: "VersioningStatusUnavailable",
                    message: "无法确认 Bucket 版本控制状态，已安全拒绝上传：\(error.localizedDescription)",
                    requestId: ""
                )
            }
            guard versioningStatus == .unconfigured else {
                let statusName = versioningStatus == .enabled ? "Enabled" : "Suspended"
                throw OSSServiceError(
                    statusCode: 409,
                    code: "BucketVersioningUnsafe",
                    message: "Bucket 的版本控制处于 \(statusName)，OSS 会忽略禁止覆盖请求头；为避免竞态覆盖，默认拒绝上传。请关闭版本控制，或在用户明确授权后传 overwrite=true。",
                    requestId: ""
                )
            }
            // Only an unconfigured (non-versioned) bucket reaches this point.
            // HEAD is a fail-closed preflight and the request header below is
            // the atomic guard against a concurrent creator.
            do {
                _ = try await perform(method: "HEAD", bucket: bucket, key: key)
                throw OSSServiceError(
                    statusCode: 409,
                    code: "ObjectAlreadyExists",
                    message: "远端对象已存在，默认未覆盖：\(bucket)/\(key)。请先获得用户明确确认，再传 overwrite=true。",
                    requestId: ""
                )
            } catch let error as OSSServiceError where error.statusCode == 404 || error.code == "NoSuchKey" {
                // Absent: continue to the guarded upload.
            }
            headers["x-oss-forbid-overwrite"] = "true"
        }
        let (data, http) = try await perform(
            method: "PUT",
            bucket: bucket,
            key: key,
            headers: headers,
            fileURL: fileURL
        )
        _ = data
        let etag = http.value(forHTTPHeaderField: "ETag")?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? ""
        return UploadResult(
            bucket: bucket,
            key: key,
            size: size,
            etag: etag,
            url: try publicURL(bucket: bucket, key: key)
        )
    }

    struct DownloadResult: Sendable {
        var bucket: String
        var key: String
        var localPath: String
        var size: Int64
    }

    func downloadFile(
        bucket: String,
        key: String,
        to target: MCPPathPolicy.DownloadTarget
    ) async throws -> DownloadResult {
        let destination = target.destination
        let request = try makeSignedRequest(method: "GET", bucket: bucket, key: key)
        // Download task streams to a temp file — memory stays flat for huge objects.
        let (tempURL, response): (URL, URLResponse)
        do {
            (tempURL, response) = try await session.download(for: request)
        } catch let urlError as URLError {
            throw OSSServiceError(
                statusCode: 0,
                code: "NetworkError",
                message: "网络请求失败：\(urlError.localizedDescription)",
                requestId: ""
            )
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: tempURL)
            throw OSSServiceError(statusCode: 0, code: "InvalidResponse", message: "非 HTTP 响应", requestId: "")
        }
        if (300...399).contains(http.statusCode) {
            let location = http.value(forHTTPHeaderField: "Location") ?? "（未提供 Location）"
            try? FileManager.default.removeItem(at: tempURL)
            throw OSSServiceError(
                statusCode: http.statusCode,
                code: "RedirectRejected",
                message: "OSS 签名请求拒绝自动重定向：\(location)。请直接配置最终 Endpoint。",
                requestId: ""
            )
        }
        guard (200...299).contains(http.statusCode) else {
            let body = (try? Data(contentsOf: tempURL)) ?? Data()
            try? FileManager.default.removeItem(at: tempURL)
            throw OSSXML.parseError(body, status: http.statusCode)
        }
        let size = try target.publish(tempURL)
        return DownloadResult(
            bucket: bucket,
            key: key,
            localPath: destination.path,
            size: size
        )
    }

    /// Shared URL components for object addresses (virtual-host or path style,
    /// preserving a custom endpoint's port).
    private func objectComponents(bucket: String, key: String) throws -> URLComponents {
        var components = URLComponents()
        let endpoint = OSSEndpoint.parse(profile.apiEndpoint)
        components.scheme = endpoint.scheme
        components.host = OSSEndpoint.objectHost(endpoint: endpoint.host, bucketName: bucket)
        components.port = endpoint.port
        let encodedKey = OSSSigner.uriEncode(key, encodeSlash: false)
        if components.host == endpoint.host {
            components.percentEncodedPath = "/" + OSSSigner.uriEncode(bucket, encodeSlash: true) + "/" + encodedKey
        } else {
            components.percentEncodedPath = "/" + encodedKey
        }
        return components
    }

    private static func invalidObjectURL() -> OSSServiceError {
        OSSServiceError(
            statusCode: 0,
            code: "InvalidURL",
            message: "无法构造对象 URL（Bucket 名称或 Key 含非法字符）",
            requestId: ""
        )
    }

    func presignedURL(bucket: String, key: String, expires: Int) throws -> URL {
        let query = OSSSigner.presignedQuery(
            method: "GET",
            bucket: bucket,
            key: key,
            region: profile.signingRegion,
            credentials: profile.credentials,
            expires: expires
        )
        var components = try objectComponents(bucket: bucket, key: key)
        components.percentEncodedQuery = query
            .map { name, value in
                let encodedName = OSSSigner.uriEncode(name, encodeSlash: true)
                if value.isEmpty { return encodedName }
                return encodedName + "=" + OSSSigner.uriEncode(value, encodeSlash: true)
            }
            .joined(separator: "&")
        guard let url = components.url else {
            throw Self.invalidObjectURL()
        }
        return url
    }

    func publicURL(bucket: String, key: String) throws -> URL {
        let components = try objectComponents(bucket: bucket, key: key)
        guard let url = components.url else {
            throw Self.invalidObjectURL()
        }
        return url
    }

    /// Cheap credential check used by `ossuno-mcp auth --test`.
    func verifyCredentials() async throws -> Int {
        let buckets = try await listBuckets()
        return buckets.count
    }
}
