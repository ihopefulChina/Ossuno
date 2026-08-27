import Foundation

// Trimmed copy of Ossuno/OSS/OSSXML.swift — kept: parse, parseError,
// buckets, listing. Removed multipart/tag helpers the CLI never calls.

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

    static func bucketVersioningStatus(from data: Data) throws -> OSSBucketVersioningStatus {
        let root = try parse(data)
        guard root.name.caseInsensitiveCompare("VersioningConfiguration") == .orderedSame else {
            throw OSSServiceError(
                statusCode: 200,
                code: "InvalidVersioningResponse",
                message: "Bucket 版本控制响应根节点无效：\(root.name)",
                requestId: ""
            )
        }
        guard let rawStatus = root.child("Status")?.string, !rawStatus.isEmpty else {
            return .unconfigured
        }
        switch rawStatus.lowercased() {
        case "enabled": return .enabled
        case "suspended": return .suspended
        default:
            throw OSSServiceError(
                statusCode: 200,
                code: "InvalidVersioningStatus",
                message: "Bucket 返回了未知的版本控制状态：\(rawStatus)",
                requestId: ""
            )
        }
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
