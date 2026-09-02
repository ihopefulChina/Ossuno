import Foundation
import XCTest
@testable import ossuno_mcp

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        storage.append(request)
        lock.unlock()
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedHandler: Handler?

    static func setHandler(_ handler: @escaping Handler) {
        lock.lock()
        storedHandler = handler
        lock.unlock()
    }

    static func clearHandler() {
        lock.lock()
        storedHandler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.storedHandler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class MCPOSSClientTests: XCTestCase, @unchecked Sendable {
    private func makeClient() -> MCPOSSClient {
        let profile = MCPOSSProfile(
            name: "test",
            region: "cn-hangzhou",
            accessKeyId: "id",
            accessKeySecret: "secret",
            endpoint: "http://oss.example.test:9000"
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return MCPOSSClient(profile: profile, configuration: configuration)
    }

    override func tearDown() {
        MockURLProtocol.clearHandler()
        super.tearDown()
    }

    func testListObjectsSendsContinuationToken() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.setHandler { request in
            recorder.append(request)
            let xml = """
                <ListBucketResult>
                  <IsTruncated>true</IsTruncated>
                  <NextContinuationToken>next-page</NextContinuationToken>
                </ListBucketResult>
                """
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
                )!,
                Data(xml.utf8)
            )
        }

        let listing = try await makeClient().listObjects(
            bucket: "bucket", maxKeys: 20, token: "current page/+="
        )
        XCTAssertEqual(listing.nextToken, "next-page")
        let components = URLComponents(url: try XCTUnwrap(recorder.requests.first?.url), resolvingAgainstBaseURL: false)
        XCTAssertEqual(
            components?.queryItems?.first(where: { $0.name == "continuation-token" })?.value,
            "current page/+="
        )
    }

    func testUploadDefaultsToRemoteOverwriteProtection() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.setHandler { request in
            recorder.append(request)
            if request.url?.query == "versioning" {
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: nil
                    )!,
                    Data("<VersioningConfiguration/>".utf8)
                )
            }
            let status = request.httpMethod == "HEAD" ? 404 : 200
            let body = request.httpMethod == "HEAD"
                ? Data("<Error><Code>NoSuchKey</Code></Error>".utf8)
                : Data()
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: request.httpMethod == "PUT" ? ["ETag": "\"etag\""] : nil
                )!,
                body
            )
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ossuno-mcp-upload-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let result = try await makeClient().uploadFile(
            bucket: "bucket", key: "asset.txt", fileURL: file, contentType: "text/plain"
        )
        XCTAssertEqual(result.etag, "etag")
        XCTAssertEqual(recorder.requests.map(\.httpMethod), ["GET", "HEAD", "PUT"])
        XCTAssertEqual(recorder.requests.first?.url?.query, "versioning")
        XCTAssertEqual(recorder.requests.last?.value(forHTTPHeaderField: "x-oss-forbid-overwrite"), "true")
    }

    func testExplicitOverwriteSkipsAbsenceCheckAndForbidHeader() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.setHandler { request in
            recorder.append(request)
            let body = request.url?.query == "versioning"
                ? Data("<VersioningConfiguration/>".utf8)
                : Data()
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["ETag": "\"updated\""]
                )!,
                body
            )
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ossuno-mcp-overwrite-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        _ = try await makeClient().uploadFile(
            bucket: "bucket", key: "asset.txt", fileURL: file,
            contentType: "text/plain", overwrite: true
        )
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests[0].httpMethod, "PUT")
        XCTAssertNil(recorder.requests[0].value(forHTTPHeaderField: "x-oss-forbid-overwrite"))
    }

    func testDefaultUploadStopsWhenRemoteObjectExists() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.setHandler { request in
            recorder.append(request)
            let body = request.url?.query == "versioning"
                ? Data("<VersioningConfiguration/>".utf8)
                : Data()
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!,
                body
            )
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ossuno-mcp-conflict-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        do {
            _ = try await makeClient().uploadFile(
                bucket: "bucket", key: "asset.txt", fileURL: file, contentType: "text/plain"
            )
            XCTFail("expected existing-object protection")
        } catch let error as OSSServiceError {
            XCTAssertEqual(error.code, "ObjectAlreadyExists")
        }
        XCTAssertEqual(recorder.requests.map(\.httpMethod), ["GET", "HEAD"])
    }

    func testSuspendedVersioningFailsClosedBeforeHeadOrPut() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.setHandler { request in
            recorder.append(request)
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!,
                Data("<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>".utf8)
            )
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ossuno-mcp-suspended-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        do {
            _ = try await makeClient().uploadFile(
                bucket: "bucket", key: "asset.txt", fileURL: file, contentType: "text/plain"
            )
            XCTFail("expected suspended-versioning rejection")
        } catch let error as OSSServiceError {
            XCTAssertEqual(error.code, "BucketVersioningUnsafe")
        }
        XCTAssertEqual(recorder.requests.map(\.httpMethod), ["GET"])
        XCTAssertEqual(recorder.requests.first?.url?.query, "versioning")
    }

    func testEnabledVersioningAlsoFailsClosedBeforeHeadOrPut() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.setHandler { request in
            recorder.append(request)
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!,
                Data("<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>".utf8)
            )
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ossuno-mcp-enabled-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        do {
            _ = try await makeClient().uploadFile(
                bucket: "bucket", key: "asset.txt", fileURL: file, contentType: "text/plain"
            )
            XCTFail("expected enabled-versioning rejection")
        } catch let error as OSSServiceError {
            XCTAssertEqual(error.code, "BucketVersioningUnsafe")
        }
        XCTAssertEqual(recorder.requests.map(\.httpMethod), ["GET"])
        XCTAssertEqual(recorder.requests.first?.url?.query, "versioning")
    }

    func testVersioningQueryFailureFailsClosedBeforeHeadOrPut() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.setHandler { request in
            recorder.append(request)
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 403, httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!,
                Data("<Error><Code>AccessDenied</Code><Message>denied</Message></Error>".utf8)
            )
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ossuno-mcp-versioning-denied-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        do {
            _ = try await makeClient().uploadFile(
                bucket: "bucket", key: "asset.txt", fileURL: file, contentType: "text/plain"
            )
            XCTFail("expected versioning-query rejection")
        } catch let error as OSSServiceError {
            XCTAssertEqual(error.code, "VersioningStatusUnavailable")
            XCTAssertEqual(error.statusCode, 403)
        }
        XCTAssertEqual(recorder.requests.map(\.httpMethod), ["GET"])
        XCTAssertEqual(recorder.requests.first?.url?.query, "versioning")
    }

    func testUnknownVersioningResponseFailsClosedBeforeHeadOrPut() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.setHandler { request in
            recorder.append(request)
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!,
                Data("<VersioningConfiguration><Status>Future</Status></VersioningConfiguration>".utf8)
            )
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ossuno-mcp-versioning-unknown-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        do {
            _ = try await makeClient().uploadFile(
                bucket: "bucket", key: "asset.txt", fileURL: file, contentType: "text/plain"
            )
            XCTFail("expected unknown-versioning rejection")
        } catch let error as OSSServiceError {
            XCTAssertEqual(error.code, "VersioningStatusUnavailable")
        }
        XCTAssertEqual(recorder.requests.map(\.httpMethod), ["GET"])
    }

    func testDownloadStreamsThenPublishesDestination() async throws {
        MockURLProtocol.setHandler { request in
            (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!,
                Data("downloaded".utf8)
            )
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ossuno-mcp-download-\(UUID().uuidString)", isDirectory: true)
        let destination = directory.appendingPathComponent("nested/object.txt")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = try MCPPathPolicy(paths: [directory.path]).prepareDownloadPath(destination.path)

        let result = try await makeClient().downloadFile(
            bucket: "bucket", key: "object.txt", to: target
        )
        XCTAssertEqual(result.size, 10)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "downloaded")
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: destination.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".ossuno-mcp-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testRedirectResponseIsRejected() async throws {
        MockURLProtocol.setHandler { request in
            (
                HTTPURLResponse(
                    url: request.url!, statusCode: 307, httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://evil.example/steal"]
                )!,
                Data()
            )
        }
        do {
            _ = try await makeClient().listBuckets()
            XCTFail("expected redirect rejection")
        } catch let error as OSSServiceError {
            XCTAssertEqual(error.code, "RedirectRejected")
            XCTAssertEqual(error.statusCode, 307)
        }
    }
}
