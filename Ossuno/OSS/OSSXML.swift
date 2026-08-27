import Foundation

struct XMLNode: Sendable {
    var name: String
    var text: String
    var children: [XMLNode]

    func child(_ name: String) -> XMLNode? {
        children.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func children(_ name: String) -> [XMLNode] {
        children.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    var string: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Object keys, prefixes, and continuation tokens are opaque and may
    /// contain leading or trailing spaces. Strip only pretty-print newlines.
    var ossText: String { text.trimmingCharacters(in: .newlines) }
}

enum OSSXML {
    static func parse(_ data: Data) throws -> XMLNode {
        let parser = TreeParser()
        let xml = XMLParser(data: data)
        xml.shouldResolveExternalEntities = false
        xml.delegate = parser
        guard xml.parse(), let root = parser.root else {
            throw OSSServiceError(statusCode: 0, code: "InvalidXML", message: parser.errorMessage ?? "无法解析响应", requestId: "")
        }
        return root
    }

    static func parseError(_ data: Data, status: Int) -> OSSServiceError {
        guard let root = try? parse(data) else {
            let snippet = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return OSSServiceError(statusCode: status, code: "HTTPError", message: snippet.isEmpty ? "请求失败（\(status)）" : snippet, requestId: "")
        }
        return OSSServiceError(
            statusCode: status,
            code: root.child("Code")?.string ?? "HTTPError",
            message: root.child("Message")?.string ?? "请求失败（\(status)）",
            requestId: root.child("RequestId")?.string ?? ""
        )
    }

    static func buckets(from data: Data) throws -> [OSSBucket] {
        let root = try parse(data)
        let list = root.child("Buckets") ?? root
        return list.children("Bucket").compactMap { node in
            guard let name = node.child("Name")?.string, !name.isEmpty else { return nil }
            let location = node.child("Location")?.string ?? ""
            let region = node.child("Region")?.string ?? location.strippingOSSPrefix()
            return OSSBucket(
                name: name,
                regionID: region.strippingOSSPrefix(),
                location: location,
                extranetEndpoint: node.child("ExtranetEndpoint")?.string ?? "",
                createdAt: ISO8601DateParser.date(node.child("CreationDate")?.string)
            )
        }
    }

    static func listing(from data: Data) throws -> ObjectListing {
        let root = try parse(data)
        let folders = root.children("CommonPrefixes").compactMap { node -> OSSFolder? in
            guard let prefix = node.child("Prefix")?.ossText, !prefix.isEmpty else { return nil }
            return OSSFolder(prefix: prefix)
        }
        let objects = root.children("Contents").compactMap { node -> OSSObject? in
            guard let key = node.child("Key")?.ossText, !key.isEmpty else { return nil }
            return OSSObject(
                key: key,
                size: Int64(node.child("Size")?.string ?? "0") ?? 0,
                etag: (node.child("ETag")?.string ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
                lastModified: ISO8601DateParser.date(node.child("LastModified")?.string),
                storageClass: node.child("StorageClass")?.string ?? ""
            )
        }
        let truncated = (root.child("IsTruncated")?.string ?? "false").lowercased() == "true"
        return ObjectListing(
            folders: folders,
            objects: objects,
            isTruncated: truncated,
            nextToken: root.child("NextContinuationToken")?.ossText
        )
    }

    static func uploadId(from data: Data) throws -> String {
        let root = try parse(data)
        guard let id = root.child("UploadId")?.string, !id.isEmpty else {
            throw OSSServiceError(statusCode: 200, code: "MissingUploadId", message: "未返回分片上传 ID", requestId: "")
        }
        return id
    }

    static func objectACL(from data: Data) throws -> ObjectACL {
        let root = try parse(data)
        let accessControlList: XMLNode?
        if root.name.caseInsensitiveCompare("AccessControlList") == .orderedSame {
            accessControlList = root
        } else {
            accessControlList = root.child("AccessControlList")
        }

        guard let accessControlList else {
            throw OSSServiceError(
                statusCode: 200,
                code: "MissingObjectACL",
                message: "对象 ACL 响应缺少 AccessControlList",
                requestId: ""
            )
        }

        let grants = accessControlList.children("Grant")
        guard grants.count == 1 else {
            throw OSSServiceError(
                statusCode: 200,
                code: grants.isEmpty ? "MissingObjectACL" : "InvalidObjectACL",
                message: grants.isEmpty ? "对象 ACL 响应缺少 Grant" : "对象 ACL 响应包含多个 Grant",
                requestId: ""
            )
        }

        let grant = grants[0].string
        guard !grant.isEmpty else {
            throw OSSServiceError(
                statusCode: 200,
                code: "MissingObjectACL",
                message: "对象 ACL 响应的 Grant 为空",
                requestId: ""
            )
        }
        guard let acl = ObjectACL(rawValue: grant) else {
            throw OSSServiceError(
                statusCode: 200,
                code: "InvalidObjectACL",
                message: "对象 ACL 响应包含未知 Grant：\(grant)",
                requestId: ""
            )
        }
        return acl
    }

    static func bucketVersioningStatus(from data: Data) throws -> OSSBucketVersioningStatus {
        let root = try parse(data)
        guard root.name.caseInsensitiveCompare("VersioningConfiguration") == .orderedSame else {
            throw OSSServiceError(
                statusCode: 200,
                code: "InvalidVersioningConfiguration",
                message: "Bucket 版本控制响应根节点无效",
                requestId: ""
            )
        }
        let statuses = root.children("Status")
        guard statuses.count <= 1 else {
            throw OSSServiceError(
                statusCode: 200,
                code: "InvalidVersioningConfiguration",
                message: "Bucket 版本控制响应包含多个 Status",
                requestId: ""
            )
        }
        guard let status = statuses.first else { return .disabled }
        let value = status.string
        guard !value.isEmpty else {
            throw OSSServiceError(
                statusCode: 200,
                code: "InvalidVersioningConfiguration",
                message: "Bucket 版本控制响应的 Status 为空",
                requestId: ""
            )
        }
        return OSSBucketVersioningStatus(rawValue: value) ?? .unknown
    }

    static func tags(from data: Data) throws -> [OSSObjectTag] {
        let root = try parse(data)
        let set: XMLNode?
        if root.name.caseInsensitiveCompare("TagSet") == .orderedSame {
            set = root
        } else if root.name.caseInsensitiveCompare("Tagging") == .orderedSame {
            let sets = root.children("TagSet")
            set = sets.count == 1 ? sets[0] : nil
        } else {
            set = nil
        }
        guard let set else {
            throw OSSServiceError(statusCode: 0, code: "InvalidTags", message: "对象标签格式无效", requestId: "")
        }

        var tags: [OSSObjectTag] = []
        for node in set.children("Tag") {
            let keys = node.children("Key")
            let values = node.children("Value")
            guard keys.count == 1, values.count <= 1 else {
                throw OSSServiceError(statusCode: 0, code: "InvalidTags", message: "对象标签格式无效", requestId: "")
            }
            let tag = OSSObjectTag(
                // Leading/trailing ASCII spaces are legal OSS tag content and
                // therefore must not be normalized while parsing a snapshot.
                key: keys[0].text,
                value: values.first?.text ?? ""
            )
            guard tag.isValidForOSS else {
                throw OSSServiceError(statusCode: 0, code: "InvalidTags", message: "对象标签格式无效", requestId: "")
            }
            tags.append(tag)
        }
        guard tags.count <= 10, Set(tags.map(\.key)).count == tags.count else {
            throw OSSServiceError(statusCode: 0, code: "InvalidTags", message: "对象标签格式无效", requestId: "")
        }
        return tags
    }

    static func taggingData(_ tags: [OSSObjectTag]) -> Data {
        var xml = "<Tagging><TagSet>"
        for tag in tags {
            xml += "<Tag><Key>\(escape(tag.key))</Key><Value>\(escape(tag.value))</Value></Tag>"
        }
        xml += "</TagSet></Tagging>"
        return Data(xml.utf8)
    }

    static func completeMultipartUploadXML(parts: [(number: Int, etag: String)]) -> Data {
        var xml = "<CompleteMultipartUpload>"
        for (number, etag) in parts.sorted(by: { $0.number < $1.number }) {
            xml += "<Part><PartNumber>\(number)</PartNumber><ETag>\"\(escape(etag))\"</ETag></Part>"
        }
        xml += "</CompleteMultipartUpload>"
        return Data(xml.utf8)
    }

    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

enum ISO8601DateParser {
    private static let cache = ISO8601FormatterCache()

    static func date(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return cache.date(from: string)
    }
}

private final class ISO8601FormatterCache: @unchecked Sendable {
    private let lock = NSLock()
    private let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let standard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    func date(from string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        if let date = fractional.date(from: string) { return date }
        return standard.date(from: string)
    }
}

private final class TreeParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    var root: XMLNode?
    var errorMessage: String?
    private var stack: [XMLNode] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        stack.append(XMLNode(name: elementName, text: "", children: []))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        guard let finished = stack.popLast() else { return }
        if stack.isEmpty {
            root = finished
        } else {
            stack[stack.count - 1].children.append(finished)
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        errorMessage = parseError.localizedDescription
    }
}
