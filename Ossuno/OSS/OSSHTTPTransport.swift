import Foundation

enum OSSHTTPBody: Sendable {
    case none
    case data(Data)
    case file(URL)
}

struct OSSHTTPResult: Sendable {
    var status: Int
    var headers: [String: String]
    var data: Data
    var temporaryDownloadURL: URL?
}

protocol OSSHTTPTransport: Sendable {
    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult
}

struct URLSessionOSSHTTPTransport: OSSHTTPTransport {
    var session: URLSession

    init(session: URLSession = URLSessionOSSHTTPTransport.liveSession) {
        self.session = session
    }

    /// Signed OSS requests must not be forwarded. A redirect can change the
    /// signed host or path and leak `Authorization` / `x-oss-security-token`.
    static func makeSession(
        configuration: URLSessionConfiguration = liveConfiguration
    ) -> URLSession {
        URLSession(
            configuration: configuration,
            delegate: OSSRedirectRejectingDelegate(),
            delegateQueue: nil
        )
    }

    private static var liveConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return configuration
    }

    private static let liveSession = makeSession()

    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        let monitor = onProgress.map(OSSProgressMonitor.init)
        if download {
            let (temporaryURL, response) = try await session.download(for: request, delegate: monitor)
            let status = try Self.status(response)
            let data = (200...299).contains(status) ? Data() : (try Data(contentsOf: temporaryURL))
            return OSSHTTPResult(
                status: status,
                headers: Self.headers(response),
                data: data,
                temporaryDownloadURL: temporaryURL
            )
        }

        let data: Data
        let response: URLResponse
        switch body {
        case .none:
            (data, response) = try await session.data(for: request, delegate: monitor)
        case .data(let bodyData):
            (data, response) = try await session.upload(for: request, from: bodyData, delegate: monitor)
        case .file(let fileURL):
            (data, response) = try await session.upload(for: request, fromFile: fileURL, delegate: monitor)
        }
        return OSSHTTPResult(
            status: try Self.status(response),
            headers: Self.headers(response),
            data: data,
            temporaryDownloadURL: nil
        )
    }

    private static func status(_ response: URLResponse) throws -> Int {
        guard let http = response as? HTTPURLResponse else {
            throw OSSServiceError(statusCode: 0, code: "InvalidResponse", message: "响应无效", requestId: "")
        }
        return http.statusCode
    }

    private static func headers(_ response: URLResponse) -> [String: String] {
        guard let http = response as? HTTPURLResponse else { return [:] }
        // allHeaderFields can contain duplicate names in rare cases; merge
        // instead of trapping with uniqueKeysWithValues.
        var merged: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            merged["\(key)"] = "\(value)"
        }
        return merged
    }
}

/// Task-level `data(for:delegate:)` / `download(for:delegate:)` replace the
/// session delegate for that request, so progress monitors must reject
/// redirects themselves.
class OSSRedirectRejectingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private final class OSSProgressMonitor: OSSRedirectRejectingDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    let handler: @Sendable (Int64, Int64) -> Void

    init(_ handler: @escaping @Sendable (Int64, Int64) -> Void) {
        self.handler = handler
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        handler(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        handler(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
