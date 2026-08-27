import Foundation
import Testing
@testable import Ossuno

struct OSSClientTests {
    @Test func retryPolicyRetriesOnlyTransientFailures() {
        let policy = OSSRetryPolicy(maxAttempts: 4, jitter: { 0 })

        #expect(policy.delay(afterAttempt: 1, outcome: .httpStatus(503)) == .milliseconds(500))
        #expect(policy.delay(afterAttempt: 2, outcome: .httpStatus(429)) == .seconds(1))
        #expect(policy.delay(afterAttempt: 3, outcome: .urlError(.timedOut)) == .seconds(2))
        #expect(
            policy.delay(
                afterAttempt: 1,
                outcome: .httpStatus(429),
                retryAfter: .seconds(3)
            ) == .seconds(3)
        )
        #expect(policy.delay(afterAttempt: 1, outcome: .httpStatus(403)) == nil)
        #expect(policy.delay(afterAttempt: 4, outcome: .httpStatus(503)) == nil)
    }

    @Test func transientFailureRetriesAndRebuildsTheRequest() async throws {
        let transport = StubOSSTransport(steps: [
            .response(status: 503, headers: [:], data: Self.errorXML(code: "ServiceUnavailable", message: "retry", requestID: "one")),
            .response(
                status: 200,
                headers: [:],
                data: Data("<ListAllMyBucketsResult><Buckets></Buckets></ListAllMyBucketsResult>".utf8)
            )
        ])
        let sleeper = RecordingRetrySleeper()
        let client = Self.client(
            transport: transport,
            retryPolicy: OSSRetryPolicy(maxAttempts: 4, jitter: { 0 }),
            retrySleeper: sleeper
        )

        let buckets = try await client.listBuckets()

        #expect(buckets.isEmpty)
        let requests = await transport.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization")?.isEmpty == false })
        #expect(await sleeper.recordedDelays() == [.milliseconds(500)])
    }

    @Test func authenticationFailureIsNeverRetried() async {
        let transport = StubOSSTransport(steps: [
            .response(status: 403, headers: [:], data: Self.errorXML(code: "AccessDenied", message: "denied", requestID: "one"))
        ])
        let sleeper = RecordingRetrySleeper()
        let client = Self.client(
            transport: transport,
            retryPolicy: OSSRetryPolicy(maxAttempts: 4, jitter: { 0 }),
            retrySleeper: sleeper
        )

        await #expect(throws: OSSServiceError.self) {
            _ = try await client.listBuckets()
        }

        #expect(await transport.recordedRequests().count == 1)
        #expect(await sleeper.recordedDelays().isEmpty)
    }

    @Test func signedRedirectResponsesAreRejectedWithoutRetry() async {
        let transport = StubOSSTransport(steps: [
            .response(
                status: 307,
                headers: [
                    "Location": "https://evil.example/steal",
                    "x-oss-request-id": "redirect-1"
                ],
                data: Data()
            )
        ])
        let sleeper = RecordingRetrySleeper()
        let client = Self.client(
            transport: transport,
            retryPolicy: OSSRetryPolicy(maxAttempts: 4, jitter: { 0 }),
            retrySleeper: sleeper
        )

        do {
            _ = try await client.listBuckets()
            Issue.record("Expected RedirectRejected")
        } catch let error as OSSServiceError {
            #expect(error.code == "RedirectRejected")
            #expect(error.statusCode == 307)
            #expect(error.message.contains("https://evil.example/steal"))
            #expect(error.requestId == "redirect-1")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await transport.recordedRequests().count == 1)
        #expect(await sleeper.recordedDelays().isEmpty)
    }

    @Test func retryAfterOverridesTheShorterBackoffForReads() async throws {
        let transport = StubOSSTransport(steps: [
            .response(
                status: 503,
                headers: ["Retry-After": "3"],
                data: Self.errorXML(code: "ServiceUnavailable", message: "retry", requestID: "one")
            ),
            .response(
                status: 200,
                headers: [:],
                data: Data("<ListAllMyBucketsResult><Buckets></Buckets></ListAllMyBucketsResult>".utf8)
            )
        ])
        let sleeper = RecordingRetrySleeper()
        let client = Self.client(
            transport: transport,
            retryPolicy: OSSRetryPolicy(maxAttempts: 3, jitter: { 0 }),
            retrySleeper: sleeper
        )

        _ = try await client.listBuckets()

        #expect(await sleeper.recordedDelays() == [.seconds(3)])
    }

    @Test func deleteIsNeverRepeatedAfterATransientServiceFailure() async {
        let transport = StubOSSTransport(steps: [
            .response(
                status: 503,
                headers: [:],
                data: Self.errorXML(code: "ServiceUnavailable", message: "uncertain", requestID: "delete")
            )
        ])
        let client = Self.client(
            transport: transport,
            retryPolicy: OSSRetryPolicy(maxAttempts: 4, jitter: { 0 })
        )

        await #expect(throws: OSSServiceError.self) {
            _ = try await client.deleteObject(key: "one.txt")
        }

        #expect(await transport.recordedRequests().map(\.httpMethod) == ["DELETE"])
    }

    @Test func copyIsNeverRepeatedAfterATransientServiceFailure() async {
        let transport = StubOSSTransport(steps: [
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "head")),
            .response(
                status: 503,
                headers: [:],
                data: Self.errorXML(code: "ServiceUnavailable", message: "uncertain", requestID: "copy")
            ),
            // Ambiguous copy confirmation: source exists but destination does not.
            .response(status: 200, headers: ["Content-Length": "1", "x-oss-hash-crc64ecma": "1"], data: Data()),
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "confirm"))
        ])
        let client = Self.client(
            transport: transport,
            retryPolicy: OSSRetryPolicy(maxAttempts: 4, jitter: { 0 })
        )

        await #expect(throws: (any Error).self) {
            _ = try await client.copyObject(from: "source.txt", to: "destination.txt", overwrite: false)
        }

        let requests = await transport.recordedRequests()
        #expect(requests.filter { $0.httpMethod == "PUT" }.count == 1)
    }

    @Test func versionedDeleteReturnsAnUndoMarkerAndCanDeleteThatExactVersion() async throws {
        let transport = StubOSSTransport(steps: [
            .response(
                status: 204,
                headers: [
                    "X-Oss-Delete-Marker": "true",
                    "x-oss-version-id": "CAEQExiBgMCf3Z2X2BciIGQ4YjU"
                ],
                data: Data()
            ),
            .response(status: 204, headers: [:], data: Data())
        ])
        let client = Self.client(transport: transport)

        let receipt = try await client.deleteObject(key: "folder/file name.txt")
        _ = try await client.deleteObject(
            key: receipt.key,
            versionID: receipt.versionID
        )

        #expect(receipt.isDeleteMarker)
        #expect(receipt.versionID == "CAEQExiBgMCf3Z2X2BciIGQ4YjU")
        let requests = await transport.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests[0].url?.query == nil)
        #expect(requests[1].url?.query?.contains("versionId=CAEQExiBgMCf3Z2X2BciIGQ4YjU") == true)
    }

    @Test func literalNullVersionIsNeverTreatedAsAnExactDeleteTarget() async {
        let transport = StubOSSTransport(steps: [])

        do {
            _ = try await Self.client(transport: transport).deleteObject(
                key: "temporary.txt",
                versionID: "null"
            )
            Issue.record("Expected invalid version rejection")
        } catch let error as OSSServiceError {
            #expect(error.code == "InvalidVersionID")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await transport.recordedRequests().isEmpty)
    }

    @Test func getObjectACLUsesTheDedicatedACLSubresourceAndNeverFallsBack() async throws {
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: [:],
                data: Data("""
                <AccessControlPolicy>
                  <AccessControlList><Grant>public-read</Grant></AccessControlList>
                </AccessControlPolicy>
                """.utf8)
            )
        ])

        let acl = try await Self.client(transport: transport).getObjectACL(key: "folder/file.txt")

        #expect(acl == .publicRead)
        let request = try #require(await transport.recordedRequests().first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.query == "acl")
    }

    @Test func getObjectACLSurfacesPermissionFailure() async {
        let transport = StubOSSTransport(steps: [
            .response(
                status: 403,
                headers: [:],
                data: Self.errorXML(code: "AccessDenied", message: "denied", requestID: "acl")
            )
        ])

        await #expect(throws: OSSServiceError.self) {
            _ = try await Self.client(transport: transport).getObjectACL(key: "private.txt")
        }
    }

    @Test func getObjectTagsPinsTheRequestedVersion() async throws {
        let transport = StubOSSTransport(steps: [
            .response(status: 200, headers: [:], data: Self.emptyTagsXML)
        ])

        _ = try await Self.client(transport: transport).getObjectTags(
            key: "object.txt",
            versionID: "source-v1"
        )

        let query = try #require(await transport.recordedRequests().first?.url?.query)
        #expect(query.contains("tagging"))
        #expect(query.contains("versionId=source-v1"))
    }

    @Test func disabledCreateAllowsExplicitVersionedCreateFlagWithoutAReceiptVersion() async throws {
        let payload = Data("payload".utf8)
        let transport = StubOSSTransport(steps: [
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "head")),
            .response(
                status: 200,
                headers: ["x-oss-hash-crc64ecma": String(CRC64XZ.checksum(payload))],
                data: Data()
            )
        ])

        let verified = try await Self.client(transport: transport).putData(
            key: "new.txt",
            data: payload,
            contentType: "text/plain",
            acl: .private,
            allowVersionedCreate: true
        )

        #expect(verified)
        #expect(await transport.recordedRequests().map(\.httpMethod) == ["HEAD", "PUT"])
    }

    @Test func enabledCreateRejectsANullCommittedVersion() async {
        let payload = Data("payload".utf8)
        let transport = StubOSSTransport(steps: [
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "head")),
            .response(
                status: 200,
                headers: [
                    "x-oss-hash-crc64ecma": String(CRC64XZ.checksum(payload)),
                    "x-oss-version-id": "null"
                ],
                data: Data()
            )
        ])

        do {
            _ = try await Self.client(
                transport: transport,
                versioningStatusOverride: .enabled
            ).putData(
                key: "new.txt",
                data: payload,
                contentType: "text/plain",
                acl: .private,
                allowVersionedCreate: true
            )
            Issue.record("Expected uncertain write")
        } catch let error as OSSServiceError {
            #expect(error.code == "WriteOutcomeUncertain")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await transport.recordedRequests().map(\.httpMethod) == ["HEAD", "PUT"])
    }

    @Test func enabledOverwriteRejectsAMissingCommittedVersion() async {
        let payload = Data("replacement".utf8)
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: ["x-oss-hash-crc64ecma": String(CRC64XZ.checksum(payload))],
                data: Data()
            )
        ])

        do {
            _ = try await Self.client(
                transport: transport,
                versioningStatusOverride: .enabled
            ).putData(
                key: "replace.txt",
                data: payload,
                contentType: "text/plain",
                acl: .private,
                overwrite: true
            )
            Issue.record("Expected uncertain write")
        } catch let error as OSSServiceError {
            #expect(error.code == "WriteOutcomeUncertain")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await transport.recordedRequests().map(\.httpMethod) == ["PUT"])
    }

    @Test func cancelledMutationsAreReportedAsUncertainAndNeverRepeated() async {
        let putTransport = StubOSSTransport(steps: [
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "head")),
            .cancel
        ])
        await #expect(throws: OSSServiceError.self) {
            _ = try await Self.client(transport: putTransport).putData(
                key: "new.txt",
                data: Data("payload".utf8),
                contentType: "text/plain",
                acl: .private
            )
        }
        #expect(await putTransport.recordedRequests().map(\.httpMethod) == ["HEAD", "PUT"])

        let copyTransport = StubOSSTransport(steps: [
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "head")),
            .cancel
        ])
        await #expect(throws: CloudObjectOperationError.copyOutcomeUncertain(destination: "dest.txt")) {
            _ = try await Self.client(transport: copyTransport).copyObject(
                from: "source.txt",
                to: "dest.txt",
                overwrite: false
            )
        }
        #expect(await copyTransport.recordedRequests().map(\.httpMethod) == ["HEAD", "PUT"])

        let deleteTransport = StubOSSTransport(steps: [.cancel])
        do {
            _ = try await Self.client(transport: deleteTransport).deleteObject(key: "delete.txt")
            Issue.record("Expected uncertain delete")
        } catch let error as OSSServiceError {
            #expect(error.code == "DeleteOutcomeUncertain")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await deleteTransport.recordedRequests().map(\.httpMethod) == ["DELETE"])
    }

    @Test func overwriteDestinationIdentityChangeStopsBeforePut() async {
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: [
                    "Content-Length": "7",
                    "ETag": "concurrent-etag",
                    "x-oss-version-id": "concurrent-v2"
                ],
                data: Data()
            )
        ])
        let expected = OSSObjectIdentity(etag: "original-etag", versionID: "original-v1", size: 7)

        do {
            _ = try await Self.client(
                transport: transport,
                versioningStatusOverride: .enabled
            ).putData(
                key: "replace.txt",
                data: Data("payload".utf8),
                contentType: "text/plain",
                acl: .private,
                expectedDestination: expected,
                overwrite: true
            )
            Issue.record("Expected destination change")
        } catch let error as OSSServiceError {
            #expect(error.code == "DestinationChanged")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await transport.recordedRequests().map(\.httpMethod) == ["HEAD"])
    }

    @Test func createOnlyWriteChecksVersioningBeforeDestinationOrPut() async {
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: [:],
                data: Data("<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>".utf8)
            )
        ])

        await #expect(throws: OSSVersioningSafetyError(
            operation: .createOnly,
            status: .enabled
        )) {
            _ = try await Self.client(
                transport: transport,
                versioningStatusOverride: nil
            ).putData(
                key: "safe.txt",
                data: Data("payload".utf8),
                contentType: "text/plain",
                acl: .private
            )
        }

        let requests = await transport.recordedRequests()
        #expect(requests.count == 1)
        #expect(requests[0].httpMethod == "GET")
        #expect(requests[0].url?.query == "versioning")
    }

    @Test func suspendedVersioningBlocksReplaceAndUnscopedDelete() async {
        let versioning = Data(
            "<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>".utf8
        )
        let transport = StubOSSTransport(steps: [
            .response(status: 200, headers: [:], data: versioning),
            .response(status: 200, headers: [:], data: versioning)
        ])
        let client = Self.client(transport: transport, versioningStatusOverride: nil)

        await #expect(throws: OSSVersioningSafetyError(
            operation: .replace,
            status: .suspended
        )) {
            _ = try await client.putData(
                key: "replace.txt",
                data: Data("payload".utf8),
                contentType: "text/plain",
                acl: .private,
                overwrite: true
            )
        }
        await #expect(throws: OSSVersioningSafetyError(
            operation: .delete,
            status: .suspended
        )) {
            _ = try await client.deleteObject(key: "delete.txt")
        }

        #expect(await transport.recordedRequests().allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func copyCreateOnlyFailsClosedForUnknownVersioningStatus() async {
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: [:],
                data: Data("<VersioningConfiguration><Status>FutureMode</Status></VersioningConfiguration>".utf8)
            )
        ])

        await #expect(throws: OSSVersioningSafetyError(
            operation: .createOnly,
            status: .unknown
        )) {
            _ = try await Self.client(
                transport: transport,
                versioningStatusOverride: nil
            ).copyObject(
                from: "source.txt",
                to: "destination.txt",
                overwrite: false
            )
        }

        #expect(await transport.recordedRequests().map(\.httpMethod) == ["GET"])
    }

    @Test func multipartRechecksVersioningImmediatelyBeforeComplete() async throws {
        let file = try Self.multipartFile(parts: 1)
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = StubOSSTransport(steps: [
            .response(status: 200, headers: [:], data: Data("<VersioningConfiguration />".utf8)),
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "preflight")),
            .response(status: 200, headers: [:], data: Data("<VersioningConfiguration />".utf8)),
            .response(
                status: 200,
                headers: [:],
                data: Data("<InitiateMultipartUploadResult><UploadId>u-1</UploadId></InitiateMultipartUploadResult>".utf8)
            ),
            .response(status: 200, headers: ["ETag": "etag-1"], data: Data()),
            .response(
                status: 200,
                headers: [:],
                data: Data("<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>".utf8)
            )
        ])
        let checkpoints = CheckpointRecorder()

        await #expect(throws: OSSVersioningSafetyError(
            operation: .createOnly,
            status: .suspended
        )) {
            _ = try await Self.client(
                transport: transport,
                versioningStatusOverride: nil
            ).putObject(
                key: "large.bin",
                fileURL: file,
                contentType: "application/octet-stream",
                acl: .private,
                onCheckpoint: { checkpoints.append($0) }
            )
        }

        let requests = await transport.recordedRequests()
        #expect(requests.filter { $0.url?.query == "versioning" }.count == 3)
        #expect(requests.contains { $0.httpMethod == "POST" && $0.url?.query == "uploadId=u-1" } == false)
        #expect(checkpoints.values.last??.completedParts.count == 1)
    }

    @Test func multipartDestinationChangeStopsBeforeComplete() async throws {
        let file = try Self.multipartFile(parts: 1)
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: [:],
                data: Data("<InitiateMultipartUploadResult><UploadId>u-identity</UploadId></InitiateMultipartUploadResult>".utf8)
            ),
            .response(status: 200, headers: ["ETag": "part-etag"], data: Data()),
            .response(
                status: 200,
                headers: [
                    "Content-Length": "1",
                    "ETag": "concurrent-etag",
                    "x-oss-version-id": "concurrent-v2"
                ],
                data: Data()
            )
        ])
        let expected = OSSObjectIdentity(etag: "original-etag", versionID: "original-v1", size: 1)

        do {
            _ = try await Self.client(
                transport: transport,
                versioningStatusOverride: .enabled
            ).putObjectWithReceipt(
                key: "large.bin",
                fileURL: file,
                contentType: "application/octet-stream",
                acl: .private,
                expectedDestination: expected,
                overwrite: true
            )
            Issue.record("Expected destination change")
        } catch let error as OSSServiceError {
            #expect(error.code == "DestinationChanged")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let requests = await transport.recordedRequests()
        #expect(requests.map(\.httpMethod) == ["POST", "PUT", "HEAD"])
        #expect(requests.contains { $0.httpMethod == "POST" && $0.url?.query == "uploadId=u-identity" } == false)
    }

    @Test func downloadPreservesServiceErrorBody() async throws {
        let transport = StubOSSTransport(steps: [
            .response(
                status: 403,
                headers: ["x-oss-request-id": "header-request"],
                data: Self.errorXML(code: "AccessDenied", message: "Denied", requestID: "body-request")
            )
        ])
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-download-error-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }

        do {
            try await Self.client(transport: transport).download(key: "private.txt", to: destination)
            Issue.record("Expected OSSServiceError")
        } catch let error as OSSServiceError {
            #expect(error.statusCode == 403)
            #expect(error.code == "AccessDenied")
            #expect(error.message == "Denied")
            #expect(error.requestId == "body-request")
            #expect(error.localizedDescription.contains("AccessDenied"))
            #expect(error.localizedDescription.contains("body-request"))
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func downloadNeverOverwritesAnExistingLocalFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-no-overwrite-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "existing.txt")
        let temporary = directory.appending(path: "response.tmp")
        try Data("original".utf8).write(to: destination)
        try Data("replacement".utf8).write(to: temporary)
        let transport = StubOSSTransport(steps: [.download(temporary, headers: [:])])

        await #expect(throws: (any Error).self) {
            try await Self.client(transport: transport).download(
                key: "existing.txt",
                to: destination,
                within: directory
            )
        }

        #expect(try Data(contentsOf: destination) == Data("original".utf8))
    }

    @Test func multipartCancellationPreservesCheckpointWithoutAborting() async throws {
        let transport = StubOSSTransport(steps: [
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "preflight")),
            .response(
                status: 200,
                headers: [:],
                data: Data("<InitiateMultipartUploadResult><UploadId>u-1</UploadId></InitiateMultipartUploadResult>".utf8)
            ),
            .cancel
        ])
        let file = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-multipart-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(OSSClient.multipartThreshold))
        try handle.close()
        defer { try? FileManager.default.removeItem(at: file) }

        let checkpoints = CheckpointRecorder()
        await #expect(throws: CancellationError.self) {
            try await Self.client(transport: transport).putObject(
                key: "large.bin",
                fileURL: file,
                contentType: "application/octet-stream",
                acl: .private,
                onCheckpoint: { checkpoint in
                    checkpoints.append(checkpoint)
                }
            )
        }

        let requests = await transport.recordedRequests()
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.httpMethod != "DELETE" })
        #expect(checkpoints.values.last??.uploadID == "u-1")
    }

    @Test func multipartUploadEmitsAReusableCheckpointAfterEveryPart() async throws {
        let transport = StubOSSTransport(steps: [
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "preflight")),
            .response(
                status: 200,
                headers: [:],
                data: Data("<InitiateMultipartUploadResult><UploadId>u-1</UploadId></InitiateMultipartUploadResult>".utf8)
            ),
            .response(status: 200, headers: ["ETag": "\"etag-1\""], data: Data()),
            .response(status: 200, headers: ["ETag": "\"etag-2\""], data: Data()),
            .response(status: 200, headers: [:], data: Data())
        ])
        let file = try Self.multipartFile(parts: 2)
        defer { try? FileManager.default.removeItem(at: file) }
        let checkpoints = CheckpointRecorder()

        _ = try await Self.client(transport: transport).putObject(
            key: "large.bin",
            fileURL: file,
            contentType: "application/octet-stream",
            acl: .private,
            onCheckpoint: { checkpoints.append($0) }
        )

        #expect(checkpoints.values.compactMap { $0?.completedParts.count } == [0, 1, 2])
        #expect(checkpoints.values.last! == nil)
        let complete = try #require(await transport.recordedRequests().last)
        #expect(complete.value(forHTTPHeaderField: "x-oss-forbid-overwrite") == "true")
    }

    @Test func multipartUploadSkipsPartsAlreadyInAValidCheckpoint() async throws {
        let transport = StubOSSTransport(steps: [
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "preflight")),
            .response(status: 200, headers: ["ETag": "etag-2"], data: Data()),
            .response(status: 200, headers: [:], data: Data())
        ])
        let file = try Self.multipartFile(parts: 2)
        defer { try? FileManager.default.removeItem(at: file) }
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let checkpoint = MultipartUploadCheckpoint(
            bucketName: "bucket",
            objectKey: "large.bin",
            sourceSize: Int64(values.fileSize!),
            sourceModifiedAt: values.contentModificationDate!,
            partSize: OSSClient.partSize,
            uploadID: "u-1",
            completedParts: [MultipartCompletedPart(number: 1, etag: "etag-1")]
        )

        _ = try await Self.client(transport: transport).putObject(
            key: "large.bin",
            fileURL: file,
            contentType: "application/octet-stream",
            acl: .private,
            checkpoint: checkpoint
        )

        let requests = await transport.recordedRequests()
        #expect(requests.count == 3)
        #expect(requests[1].url?.query?.contains("partNumber=2") == true)
        #expect(requests[2].httpMethod == "POST")
        #expect(requests[2].url?.query == "uploadId=u-1")
    }

    @Test func multipartAbortIsAnExplicitDelete() async throws {
        let checkpoint = MultipartUploadCheckpoint(
            bucketName: "bucket",
            objectKey: "large.bin",
            sourceSize: OSSClient.partSize,
            sourceModifiedAt: .distantPast,
            partSize: OSSClient.partSize,
            uploadID: "u-1",
            completedParts: []
        )
        let transport = StubOSSTransport(steps: [
            .response(status: 204, headers: [:], data: Data())
        ])

        try await Self.client(transport: transport).abortMultipartUpload(checkpoint)

        let request = try #require(await transport.recordedRequests().first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.query == "uploadId=u-1")
    }

    @Test func multipartInitiateIsNeverRepeatedWhenItsResponseIsUncertain() async throws {
        let file = try Self.multipartFile(parts: 1)
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = StubOSSTransport(steps: [
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "preflight")),
            .response(
                status: 503,
                headers: [:],
                data: Self.errorXML(code: "ServiceUnavailable", message: "uncertain", requestID: "initiate")
            ),
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "confirm"))
        ])
        let client = Self.client(
            transport: transport,
            retryPolicy: OSSRetryPolicy(maxAttempts: 4, jitter: { 0 })
        )

        await #expect(throws: OSSServiceError.self) {
            _ = try await client.putObject(
                key: "large.bin",
                fileURL: file,
                contentType: "application/octet-stream",
                acl: .private
            )
        }

        let requests = await transport.recordedRequests()
        #expect(requests.filter { $0.httpMethod == "POST" && $0.url?.query == "uploads" }.count == 1)
    }

    @Test func multipartPartPutCanRetryBecauseItsUploadIDAndPartNumberAreStable() async throws {
        let file = try Self.multipartFile(parts: 1)
        defer { try? FileManager.default.removeItem(at: file) }
        let payload = try Data(contentsOf: file)
        let checksum = CRC64XZ.checksum(payload)
        let transport = StubOSSTransport(steps: [
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "preflight")),
            .response(
                status: 200,
                headers: [:],
                data: Data("<InitiateMultipartUploadResult><UploadId>u-1</UploadId></InitiateMultipartUploadResult>".utf8)
            ),
            .response(status: 503, headers: [:], data: Self.errorXML(code: "InternalError", message: "retry", requestID: "part")),
            .response(status: 200, headers: ["ETag": "etag-1"], data: Data()),
            .response(status: 200, headers: ["x-oss-hash-crc64ecma": String(checksum)], data: Data())
        ])
        let client = Self.client(
            transport: transport,
            retryPolicy: OSSRetryPolicy(maxAttempts: 3, jitter: { 0 })
        )

        let verified = try await client.putObject(
            key: "large.bin",
            fileURL: file,
            contentType: "application/octet-stream",
            acl: .private
        )

        #expect(verified)
        let partRequests = await transport.recordedRequests().filter {
            $0.httpMethod == "PUT" && $0.url?.query?.contains("partNumber=1") == true
        }
        #expect(partRequests.count == 2)
        #expect(partRequests.allSatisfy { $0.value(forHTTPHeaderField: "Content-MD5") != nil })
    }

    @Test func lostCompleteResponseIsReportedAsUncertainWithoutSubmittingAgain() async throws {
        let file = try Self.multipartFile(parts: 1)
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = StubOSSTransport(steps: [
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "preflight")),
            .response(
                status: 200,
                headers: [:],
                data: Data("<InitiateMultipartUploadResult><UploadId>u-1</UploadId></InitiateMultipartUploadResult>".utf8)
            ),
            .response(status: 200, headers: ["ETag": "etag-1"], data: Data()),
            .failure(.networkConnectionLost)
        ])
        let checkpoints = CheckpointRecorder()

        await #expect(throws: OSSServiceError.self) {
            _ = try await Self.client(
                transport: transport,
                retryPolicy: OSSRetryPolicy(maxAttempts: 4, jitter: { 0 })
            ).putObjectWithReceipt(
                key: "large.bin",
                fileURL: file,
                contentType: "application/octet-stream",
                acl: .private,
                onCheckpoint: { checkpoints.append($0) }
            )
        }

        let requests = await transport.recordedRequests()
        #expect(requests.filter { $0.httpMethod == "POST" && $0.url?.query == "uploadId=u-1" }.count == 1)
        #expect(requests.last?.httpMethod == "POST")
        #expect(checkpoints.values.last??.completedParts.count == 1)
    }

    @Test func cancelledCompleteIsReportedAsUncertainWithoutSubmittingAgain() async throws {
        let file = try Self.multipartFile(parts: 1)
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = StubOSSTransport(steps: [
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "preflight")),
            .response(
                status: 200,
                headers: [:],
                data: Data("<InitiateMultipartUploadResult><UploadId>u-cancel</UploadId></InitiateMultipartUploadResult>".utf8)
            ),
            .response(status: 200, headers: ["ETag": "etag-1"], data: Data()),
            .cancel
        ])

        do {
            _ = try await Self.client(transport: transport).putObjectWithReceipt(
                key: "large.bin",
                fileURL: file,
                contentType: "application/octet-stream",
                acl: .private
            )
            Issue.record("Expected uncertain completion")
        } catch let error as OSSServiceError {
            #expect(error.code == "WriteOutcomeUncertain")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let completionRequests = await transport.recordedRequests().filter {
            $0.httpMethod == "POST" && $0.url?.query == "uploadId=u-cancel"
        }
        #expect(completionRequests.count == 1)
    }

    @Test func multipartCompleteConflictNeverGuessesSuccessFromMatchingBytes() async throws {
        let file = try Self.multipartFile(parts: 1)
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = StubOSSTransport(steps: [
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "preflight")),
            .response(
                status: 200,
                headers: [:],
                data: Data("<InitiateMultipartUploadResult><UploadId>u-1</UploadId></InitiateMultipartUploadResult>".utf8)
            ),
            .response(status: 200, headers: ["ETag": "etag-1"], data: Data()),
            .response(
                status: 409,
                headers: [:],
                data: Self.errorXML(code: "FileAlreadyExists", message: "exists", requestID: "complete")
            )
        ])
        let checkpoints = CheckpointRecorder()

        await #expect(throws: OSSServiceError.self) {
            _ = try await Self.client(transport: transport).putObjectWithReceipt(
                key: "large.bin",
                fileURL: file,
                contentType: "application/octet-stream",
                acl: .private,
                onCheckpoint: { checkpoints.append($0) }
            )
        }

        #expect(checkpoints.values.last??.completedParts.count == 1)
        let requests = await transport.recordedRequests()
        #expect(requests[3].value(forHTTPHeaderField: "x-oss-forbid-overwrite") == "true")
        #expect(requests.map(\.httpMethod) == ["HEAD", "POST", "PUT", "POST"])
    }

    @Test func multipartCompleteConflictPreservesCheckpointWhenExistingObjectDiffers() async throws {
        let file = try Self.multipartFile(parts: 1)
        defer { try? FileManager.default.removeItem(at: file) }
        let payload = try Data(contentsOf: file)
        let transport = StubOSSTransport(steps: [
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "preflight")),
            .response(
                status: 200,
                headers: [:],
                data: Data("<InitiateMultipartUploadResult><UploadId>u-1</UploadId></InitiateMultipartUploadResult>".utf8)
            ),
            .response(status: 200, headers: ["ETag": "etag-1"], data: Data()),
            .response(
                status: 409,
                headers: [:],
                data: Self.errorXML(code: "FileAlreadyExists", message: "exists", requestID: "complete")
            ),
            .response(
                status: 200,
                headers: [
                    "Content-Length": "\(payload.count)",
                    "x-oss-hash-crc64ecma": "1"
                ],
                data: Data()
            )
        ])
        let checkpoints = CheckpointRecorder()

        await #expect(throws: OSSServiceError.self) {
            _ = try await Self.client(transport: transport).putObjectWithReceipt(
                key: "large.bin",
                fileURL: file,
                contentType: "application/octet-stream",
                acl: .private,
                onCheckpoint: { checkpoints.append($0) }
            )
        }

        #expect(checkpoints.values.last??.completedParts.count == 1)
        let complete = try #require((await transport.recordedRequests()).dropFirst(3).first)
        #expect(complete.value(forHTTPHeaderField: "x-oss-forbid-overwrite") == "true")
    }

    @Test func multipartUploadStopsBeforeCompleteWhenTheSourceChanges() async throws {
        let file = try Self.multipartFile(parts: 1)
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = StubOSSTransport(steps: [
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "preflight")),
            .response(
                status: 200,
                headers: [:],
                data: Data("<InitiateMultipartUploadResult><UploadId>u-1</UploadId></InitiateMultipartUploadResult>".utf8)
            ),
            .mutateFile(file, status: 200, headers: ["ETag": "etag-1"], data: Data())
        ])

        do {
            _ = try await Self.client(transport: transport).putObject(
                key: "large.bin",
                fileURL: file,
                contentType: "application/octet-stream",
                acl: .private
            )
            Issue.record("Expected SourceFileChanged")
        } catch let error as OSSServiceError {
            #expect(error.code == "SourceFileChanged")
        }

        let requests = await transport.recordedRequests()
        #expect(requests.map(\.httpMethod) == ["HEAD", "POST", "PUT"])
    }

    @Test func renameConflictNeverDeletesSource() async throws {
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: [
                    "Content-Length": "1",
                    "ETag": "source-etag",
                    "x-oss-version-id": "source-v1"
                ],
                data: Data()
            ),
            .response(status: 200, headers: [:], data: Self.privateACLXML),
            .response(status: 200, headers: [:], data: Self.emptyTagsXML),
            .response(
                status: 200,
                headers: ["Content-Length": "1", "ETag": "destination-etag"],
                data: Data()
            )
        ])

        await #expect(throws: OSSServiceError.self) {
            try await Self.client(transport: transport, versioningStatusOverride: .enabled)
                .renameObject(from: "old name.txt", to: "new name.txt", overwrite: false)
        }

        let requests = await transport.recordedRequests()
        #expect(requests.count == 4)
        #expect(requests.last?.httpMethod == "HEAD")
        #expect(requests.allSatisfy { $0.httpMethod != "DELETE" })
    }

    @Test func customEndpointPreservesSchemeAndPort() async throws {
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: [:],
                data: Data("<ListAllMyBucketsResult><Buckets></Buckets></ListAllMyBucketsResult>".utf8)
            )
        ])
        var client = Self.client(transport: transport)
        client.endpointHost = "http://127.0.0.1:9000"

        _ = try await client.listBuckets()

        let request = try #require(await transport.recordedRequests().first)
        #expect(request.url?.scheme == "http")
        #expect(request.url?.host == "127.0.0.1")
        #expect(request.url?.port == 9000)
    }

    @Test func presignedURLPreservesCustomEndpointSchemeAndPort() throws {
        let transport = StubOSSTransport(steps: [])
        var client = Self.client(transport: transport)
        client.endpointHost = "http://127.0.0.1:9000"

        let url = try #require(client.presignedURL(key: "folder/file name.txt"))

        #expect(url.scheme == "http")
        #expect(url.host == "127.0.0.1")
        #expect(url.port == 9000)
        #expect(url.path(percentEncoded: true) == "/bucket/folder/file%20name.txt")
    }

    @Test func truncatedListingWithoutTokenStaysIncomplete() async throws {
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: [:],
                data: Data("<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>".utf8)
            )
        ])

        let listing = try await Self.client(transport: transport).listAll(prefix: "folder/")

        #expect(listing.isTruncated)
        #expect(await transport.recordedRequests().count == 1)
    }

    @Test func recursiveObjectPageUsesNoDelimiterAndForwardsTheExactToken() async throws {
        let firstPage = Data("""
        <ListBucketResult>
          <IsTruncated>true</IsTruncated>
          <NextContinuationToken>next/token + value</NextContinuationToken>
          <Contents><Key>folder/a.txt</Key><Size>1</Size><ETag>a</ETag></Contents>
        </ListBucketResult>
        """.utf8)
        let secondPage = Data("""
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <Contents><Key>folder/nested/b.txt</Key><Size>2</Size><ETag>b</ETag></Contents>
        </ListBucketResult>
        """.utf8)
        let transport = StubOSSTransport(steps: [
            .response(status: 200, headers: [:], data: firstPage),
            .response(status: 200, headers: [:], data: secondPage)
        ])
        let client = Self.client(transport: transport)

        let first = try await client.listObjectPage(prefix: "folder/")
        let second = try await client.listObjectPage(prefix: "folder/", token: first.nextToken)

        #expect(first.objects.map(\.key) == ["folder/a.txt"])
        #expect(second.objects.map(\.key) == ["folder/nested/b.txt"])
        let requests = await transport.recordedRequests()
        let firstItems = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let secondItems = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(!firstItems.contains(where: { $0.name == "delimiter" }))
        #expect(firstItems.contains(URLQueryItem(name: "list-type", value: "2")))
        #expect(firstItems.contains(URLQueryItem(name: "max-keys", value: "1000")))
        #expect(secondItems.contains(URLQueryItem(name: "continuation-token", value: "next/token + value")))
    }

    @Test func recursiveAggregateStopsWhenATruncatedPageOmitsItsToken() async throws {
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: [:],
                data: Data("""
                <ListBucketResult>
                  <IsTruncated>true</IsTruncated>
                  <Contents><Key>a.txt</Key><Size>1</Size><ETag>a</ETag></Contents>
                </ListBucketResult>
                """.utf8)
            )
        ])

        let result = try await Self.client(transport: transport).listAllObjects(prefix: "")

        #expect(result.objects.map(\.key) == ["a.txt"])
        #expect(result.truncated)
        #expect(await transport.recordedRequests().count == 1)
    }

    @Test func crc64XZMatchesTheStandardCheckVector() {
        #expect(CRC64XZ.checksum(Data("123456789".utf8)) == 0x995D_C9BB_DF19_39FA)
    }

    @Test func putDataReportsMatchingServerCRC64() async throws {
        let data = Data("verified upload".utf8)
        let checksum = CRC64XZ.checksum(data)
        let transport = StubOSSTransport(steps: [
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "preflight")),
            .response(
                status: 200,
                headers: ["x-oss-hash-crc64ecma": String(checksum)],
                data: Data()
            )
        ])

        let verified = try await Self.client(transport: transport).putData(
            key: "verified.txt",
            data: data,
            contentType: "text/plain",
            acl: .private
        )

        #expect(verified)
    }

    @Test func putDataRejectsMismatchedServerCRC64AndRemovesTheExactCommittedVersion() async {
        let transport = StubOSSTransport(steps: [
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "preflight")),
            .response(
                status: 200,
                headers: [
                    "x-oss-hash-crc64ecma": "1",
                    "x-oss-version-id": "bad-version"
                ],
                data: Data()
            ),
            .response(status: 204, headers: [:], data: Data())
        ])

        await #expect(throws: OSSIntegrityError.self) {
            try await Self.client(transport: transport).putData(
                key: "corrupted.txt",
                data: Data("different".utf8),
                contentType: "text/plain",
                acl: .private
            )
        }

        let requests = await transport.recordedRequests()
        #expect(requests.map(\.httpMethod) == ["HEAD", "PUT", "DELETE"])
        #expect(requests.last?.url?.query == "versionId=bad-version")
    }

    @Test func downloadRejectsMismatchedCRCBeforePublishingDestination() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-crc-download-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "download.txt")
        let temporary = directory.appending(path: "response.tmp")
        try Data("downloaded bytes".utf8).write(to: temporary)
        let transport = StubOSSTransport(steps: [
            .download(temporary, headers: ["x-oss-hash-crc64ecma": "1"])
        ])

        await #expect(throws: OSSIntegrityError.self) {
            try await Self.client(transport: transport).download(
                key: "download.txt",
                to: destination,
                within: directory
            )
        }

        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func resumableDownloadUsesBoundedByteRangesAndPublishesAtomically() async throws {
        let directory = try Self.temporaryDirectory(named: "range-download")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "large.bin")
        let size = 20 * 1_024 * 1_024
        let first = Data(repeating: 1, count: Int(OSSClient.downloadChunkSize))
        let second = Data(repeating: 2, count: Int(OSSClient.downloadChunkSize))
        let third = Data(repeating: 3, count: size - first.count - second.count)
        let checksum = CRC64XZ.checksum(first + second + third)
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: [
                    "Content-Length": "\(size)",
                    "ETag": "v1",
                    "x-oss-hash-crc64ecma": String(checksum)
                ],
                data: Data()
            ),
            .response(status: 206, headers: ["Content-Range": "bytes 0-8388607/20971520", "ETag": "v1"], data: first),
            .response(status: 206, headers: ["Content-Range": "bytes 8388608-16777215/20971520", "ETag": "v1"], data: second),
            .response(status: 206, headers: ["Content-Range": "bytes 16777216-20971519/20971520", "ETag": "v1"], data: third)
        ])
        let recorder = DownloadCheckpointRecorder()

        _ = try await Self.client(transport: transport).downloadResumable(
            key: "large.bin",
            to: destination,
            within: directory,
            expectedSize: Int64(size),
            checkpoint: nil,
            onCheckpoint: { recorder.append($0) }
        )

        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect((try destination.resourceValues(forKeys: [.fileSizeKey])).fileSize == size)
        let requests = await transport.recordedRequests()
        #expect(requests.dropFirst().map { $0.value(forHTTPHeaderField: "Range") } == [
            "bytes=0-8388607",
            "bytes=8388608-16777215",
            "bytes=16777216-20971519"
        ])
        #expect(requests.dropFirst().allSatisfy { $0.value(forHTTPHeaderField: "If-Match") == "\"v1\"" })
        #expect(recorder.values.compactMap { $0?.completedBytes } == [0, 8_388_608, 16_777_216, 20_971_520])
        #expect(recorder.values.last! == nil)
    }

    @Test func resumableDownloadContinuesFromACompleteRange() async throws {
        let directory = try Self.temporaryDirectory(named: "range-resume")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "large.bin")
        let partialName = ".ossuno-known.partial"
        let partial = directory.appending(path: partialName)
        let first = Data(repeating: 1, count: Int(OSSClient.downloadChunkSize))
        try first.write(to: partial)
        let size = 20 * 1_024 * 1_024
        let second = Data(repeating: 2, count: Int(OSSClient.downloadChunkSize))
        let third = Data(repeating: 3, count: size - first.count - second.count)
        let checksum = CRC64XZ.checksum(first + second + third)
        let checkpoint = RangeDownloadCheckpoint(
            bucketName: "bucket",
            objectKey: "large.bin",
            expectedSize: Int64(size),
            etag: "v1",
            chunkSize: OSSClient.downloadChunkSize,
            completedBytes: OSSClient.downloadChunkSize,
            partialFileName: partialName
        )
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: [
                    "Content-Length": "\(size)",
                    "ETag": "v1",
                    "x-oss-hash-crc64ecma": String(checksum)
                ],
                data: Data()
            ),
            .response(status: 206, headers: ["Content-Range": "bytes 8388608-16777215/20971520", "ETag": "v1"], data: second),
            .response(status: 206, headers: ["Content-Range": "bytes 16777216-20971519/20971520", "ETag": "v1"], data: third)
        ])

        _ = try await Self.client(transport: transport).downloadResumable(
            key: "large.bin",
            to: destination,
            within: directory,
            expectedSize: Int64(size),
            checkpoint: checkpoint
        )

        let requests = await transport.recordedRequests()
        #expect(requests.dropFirst().map { $0.value(forHTTPHeaderField: "Range") } == [
            "bytes=8388608-16777215",
            "bytes=16777216-20971519"
        ])
    }

    @Test func resumableDownloadKeepsPartialWhenIntegrityCheckFails() async throws {
        let directory = try Self.temporaryDirectory(named: "range-crc")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "small.bin")
        let bytes = Data("downloaded".utf8)
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: ["Content-Length": "\(bytes.count)", "ETag": "v1", "x-oss-hash-crc64ecma": "1"],
                data: Data()
            ),
            .response(
                status: 206,
                headers: ["Content-Range": "bytes 0-\(bytes.count - 1)/\(bytes.count)", "ETag": "v1"],
                data: bytes
            )
        ])
        let recorder = DownloadCheckpointRecorder()

        await #expect(throws: OSSIntegrityError.self) {
            try await Self.client(transport: transport).downloadResumable(
                key: "small.bin",
                to: destination,
                within: directory,
                expectedSize: Int64(bytes.count),
                checkpoint: nil,
                onCheckpoint: { recorder.append($0) }
            )
        }

        let partialName = try #require(recorder.values.compactMap { $0 }.last?.partialFileName)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: partialName).path))
    }

    @Test func resumableDownloadReplacesAnExistingFileOnlyAfterIntegrityPasses() async throws {
        let directory = try Self.temporaryDirectory(named: "range-replace")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "small.bin")
        try Data("original".utf8).write(to: destination)
        let bytes = Data("replaced!".utf8)
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: [
                    "Content-Length": "\(bytes.count)",
                    "ETag": "v2",
                    "x-oss-hash-crc64ecma": String(CRC64XZ.checksum(bytes))
                ],
                data: Data()
            ),
            .response(
                status: 206,
                headers: ["Content-Range": "bytes 0-\(bytes.count - 1)/\(bytes.count)", "ETag": "v2"],
                data: bytes
            )
        ])

        _ = try await Self.client(transport: transport).downloadResumable(
            key: "small.bin",
            to: destination,
            within: directory,
            expectedSize: Int64(bytes.count),
            overwrite: true
        )

        #expect(try Data(contentsOf: destination) == bytes)
    }

    @Test func resumableDownloadRevalidatesAnExistingDestinationImmediatelyBeforeReplace() async throws {
        let directory = try Self.temporaryDirectory(named: "range-revalidate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "small.bin")
        let original = Data("original".utf8)
        try original.write(to: destination)
        let bytes = Data("replacement".utf8)
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: [
                    "Content-Length": "\(bytes.count)",
                    "ETag": "v2",
                    "x-oss-hash-crc64ecma": String(CRC64XZ.checksum(bytes))
                ],
                data: Data()
            ),
            .response(
                status: 206,
                headers: ["Content-Range": "bytes 0-\(bytes.count - 1)/\(bytes.count)", "ETag": "v2"],
                data: bytes
            )
        ])

        await #expect(throws: OSSServiceError.self) {
            _ = try await Self.client(transport: transport).downloadResumable(
                key: "small.bin",
                to: destination,
                within: directory,
                expectedSize: Int64(bytes.count),
                overwrite: true,
                beforeReplacingExisting: {
                    throw OSSServiceError(
                        statusCode: 0,
                        code: "LocalFileChanged",
                        message: "目标文件已变化",
                        requestId: ""
                    )
                }
            )
        }

        #expect(try Data(contentsOf: destination) == original)
    }

    @Test func failedOverwriteDownloadLeavesTheOriginalFile() async throws {
        let directory = try Self.temporaryDirectory(named: "range-keep")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "small.bin")
        let original = Data("original".utf8)
        try original.write(to: destination)
        let bytes = Data("new".utf8)
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: [
                    "Content-Length": "\(bytes.count)",
                    "ETag": "v2",
                    "x-oss-hash-crc64ecma": "1"
                ],
                data: Data()
            ),
            .response(
                status: 206,
                headers: ["Content-Range": "bytes 0-\(bytes.count - 1)/\(bytes.count)", "ETag": "v2"],
                data: bytes
            )
        ])

        await #expect(throws: OSSIntegrityError.self) {
            try await Self.client(transport: transport).downloadResumable(
                key: "small.bin",
                to: destination,
                within: directory,
                expectedSize: Int64(bytes.count),
                overwrite: true
            )
        }

        #expect(try Data(contentsOf: destination) == original)
    }

    @Test func resumableDownloadRejectsAWrongContentRange() async throws {
        let directory = try Self.temporaryDirectory(named: "range-header")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "small.bin")
        let bytes = Data("downloaded".utf8)
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: [
                    "Content-Length": "\(bytes.count)",
                    "ETag": "v1",
                    "x-oss-hash-crc64ecma": String(CRC64XZ.checksum(bytes))
                ],
                data: Data()
            ),
            .response(
                status: 206,
                headers: ["Content-Range": "bytes 1-\(bytes.count)/\(bytes.count)", "ETag": "v1"],
                data: bytes
            )
        ])

        do {
            _ = try await Self.client(transport: transport).downloadResumable(
                key: "small.bin",
                to: destination,
                within: directory,
                expectedSize: Int64(bytes.count)
            )
            Issue.record("Expected InvalidRangeResponse")
        } catch let error as OSSServiceError {
            #expect(error.code == "InvalidRangeResponse")
        }

        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func resumableDownloadRejectsARangeResponseWithoutThePinnedETag() async throws {
        let directory = try Self.temporaryDirectory(named: "range-missing-etag")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "small.bin")
        let bytes = Data("downloaded".utf8)
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: [
                    "Content-Length": "\(bytes.count)",
                    "ETag": "v1",
                    "x-oss-hash-crc64ecma": String(CRC64XZ.checksum(bytes))
                ],
                data: Data()
            ),
            .response(
                status: 206,
                headers: ["Content-Range": "bytes 0-\(bytes.count - 1)/\(bytes.count)"],
                data: bytes
            )
        ])

        await #expect(throws: OSSServiceError.self) {
            _ = try await Self.client(transport: transport).downloadResumable(
                key: "small.bin",
                to: destination,
                within: directory,
                expectedSize: Int64(bytes.count)
            )
        }

        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func resumableDownloadTurnsIfMatchFailureIntoRemoteObjectChanged() async throws {
        let directory = try Self.temporaryDirectory(named: "range-etag")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "small.bin")
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: ["Content-Length": "10", "ETag": "v1", "x-oss-hash-crc64ecma": "1"],
                data: Data()
            ),
            .response(
                status: 412,
                headers: [:],
                data: Self.errorXML(code: "PreconditionFailed", message: "changed", requestID: "range")
            )
        ])

        do {
            _ = try await Self.client(transport: transport).downloadResumable(
                key: "small.bin",
                to: destination,
                within: directory,
                expectedSize: 10
            )
            Issue.record("Expected RemoteObjectChanged")
        } catch let error as OSSServiceError {
            #expect(error.code == "RemoteObjectChanged")
        }

        let rangeRequest = try #require(await transport.recordedRequests().last)
        #expect(rangeRequest.value(forHTTPHeaderField: "If-Match") == "\"v1\"")
    }

    @Test func prefixPlanPreservesRelativePaths() throws {
        let plan = try CloudObjectOperation.planPrefix(
            source: "old/",
            destination: "new/",
            keys: ["old/", "old/a.jpg", "old/sub/b.jpg"]
        )

        #expect(plan.map(\.destinationKey) == ["new/", "new/a.jpg", "new/sub/b.jpg"])
    }

    @Test func prefixCannotMoveInsideItself() {
        #expect(throws: CloudObjectOperationError.self) {
            try CloudObjectOperation.planPrefix(
                source: "old/",
                destination: "old/sub/",
                keys: ["old/a.jpg"]
            )
        }
    }

    @Test func disabledBucketMoveFailsBeforeAnyCopyOrDelete() async throws {
        let listing = Data("""
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <Contents><Key>old/a.txt</Key><Size>1</Size><ETag>a</ETag></Contents>
          <Contents><Key>old/b.txt</Key><Size>1</Size><ETag>b</ETag></Contents>
        </ListBucketResult>
        """.utf8)
        let transport = StubOSSTransport(steps: [
            .response(status: 200, headers: [:], data: listing)
        ])

        await #expect(throws: OSSVersioningSafetyError(
            operation: .move,
            status: .disabled
        )) {
            try await Self.client(transport: transport).movePrefix(from: "old/", to: "new/")
        }

        let requests = await transport.recordedRequests()
        #expect(requests.map(\.httpMethod) == ["GET"])
    }

    @Test func putObjectForbidsOverwriteUnlessRequested() async throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-put-forbid-\(UUID().uuidString).txt")
        try Data("payload".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = StubOSSTransport(steps: [
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "preflight")),
            .response(status: 200, headers: [:], data: Data()),
            .response(
                status: 200,
                headers: ["x-oss-version-id": "replace-v1"],
                data: Data()
            )
        ])
        _ = try await Self.client(transport: transport).putObject(
            key: "safe.txt",
            fileURL: file,
            contentType: "text/plain",
            acl: .private
        )
        _ = try await Self.client(
            transport: transport,
            versioningStatusOverride: .enabled
        ).putObject(
            key: "replace.txt",
            fileURL: file,
            contentType: "text/plain",
            acl: .private,
            overwrite: true
        )

        let requests = await transport.recordedRequests()
        #expect(requests[1].value(forHTTPHeaderField: "x-oss-forbid-overwrite") == "true")
        #expect(requests[1].value(forHTTPHeaderField: "Content-MD5") != nil)
        #expect(requests[2].value(forHTTPHeaderField: "x-oss-forbid-overwrite") == nil)
    }

    @Test func lostSimplePutResponseIsReportedAsUncertainWithoutSubmittingAgain() async throws {
        let payload = Data("stable bytes".utf8)
        let file = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-put-confirm-\(UUID().uuidString).txt")
        try payload.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = StubOSSTransport(steps: [
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "preflight")),
            .failure(.networkConnectionLost)
        ])

        await #expect(throws: OSSServiceError.self) {
            _ = try await Self.client(
                transport: transport,
                retryPolicy: OSSRetryPolicy(maxAttempts: 4, jitter: { 0 })
            ).putObjectWithReceipt(
                key: "stable.txt",
                fileURL: file,
                contentType: "text/plain",
                acl: .private
            )
        }

        #expect(await transport.recordedRequests().map(\.httpMethod) == ["HEAD", "PUT"])
    }

    @Test func uploadReceiptAndPropertiesComeFromTheCommittingResponse() async throws {
        let payload = Data("properties".utf8)
        let file = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-put-properties-\(UUID().uuidString).txt")
        try payload.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = StubOSSTransport(steps: [
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "preflight")),
            .response(
                status: 200,
                headers: [
                    "x-oss-hash-crc64ecma": String(CRC64XZ.checksum(payload)),
                    "x-oss-version-id": "response-v1"
                ],
                data: Data()
            )
        ])
        let properties = OSSObjectProperties(
            contentType: "text/custom",
            cacheControl: "max-age=60",
            contentDisposition: "attachment; filename=example.txt",
            userMetadata: ["origin": "relay"]
        )

        let receipt = try await Self.client(transport: transport).putObjectWithReceipt(
            key: "properties.txt",
            fileURL: file,
            contentType: "text/plain",
            acl: .publicRead,
            properties: properties,
            contentEncoding: "gzip",
            storageClass: "IA",
            serverSideEncryption: "KMS",
            serverSideEncryptionKeyID: "kms-key-1"
        )

        #expect(receipt.versionID == "response-v1")
        #expect(!receipt.matchedExisting)
        let request = try #require(await transport.recordedRequests().last)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "text/custom")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "max-age=60")
        #expect(request.value(forHTTPHeaderField: "Content-Disposition") == "attachment; filename=example.txt")
        #expect(request.value(forHTTPHeaderField: "Content-Encoding") == "gzip")
        #expect(request.value(forHTTPHeaderField: "x-oss-storage-class") == "IA")
        #expect(request.value(forHTTPHeaderField: "x-oss-server-side-encryption") == "KMS")
        #expect(request.value(forHTTPHeaderField: "x-oss-server-side-encryption-key-id") == "kms-key-1")
        #expect(request.value(forHTTPHeaderField: "x-oss-object-acl") == "public-read")
        #expect(request.value(forHTTPHeaderField: "x-oss-meta-origin") == "relay")
    }

    @Test func copyPreservesMetadataAndTagsByDefaultAndCanSetACL() async throws {
        let transport = StubOSSTransport(steps: [
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "preflight")),
            .response(status: 200, headers: ["x-oss-version-id": "copy-v1"], data: Data())
        ])

        let version = try await Self.client(transport: transport).copyObject(
            from: "source.txt",
            to: "destination.txt",
            overwrite: false,
            acl: .private,
            sourceETag: "source-etag",
            serverSideEncryption: "KMS",
            serverSideEncryptionKeyID: "kms-key-1"
        )

        #expect(version == "copy-v1")
        let request = try #require(await transport.recordedRequests().last)
        #expect(request.value(forHTTPHeaderField: "x-oss-copy-source") == "/bucket/source.txt")
        #expect(request.value(forHTTPHeaderField: "x-oss-forbid-overwrite") == "true")
        #expect(request.value(forHTTPHeaderField: "x-oss-object-acl") == "private")
        #expect(request.value(forHTTPHeaderField: "x-oss-copy-source-if-match") == "\"source-etag\"")
        #expect(request.value(forHTTPHeaderField: "x-oss-server-side-encryption") == "KMS")
        #expect(request.value(forHTTPHeaderField: "x-oss-server-side-encryption-key-id") == "kms-key-1")
        #expect(request.value(forHTTPHeaderField: "x-oss-metadata-directive") == "COPY")
        #expect(request.value(forHTTPHeaderField: "x-oss-tagging-directive") == "Copy")
    }

    @Test func replaceMetadataUsesTheExpectedFullSnapshotAndReplacesPinnedTags() async throws {
        let tags = [
            OSSObjectTag(key: "Owner", value: "Alice Smith"),
            OSSObjectTag(key: "env", value: "prod")
        ]
        let headHeaders = [
            "Content-Type": "text/plain",
            "Content-Length": "5",
            "ETag": "source-etag",
            "Cache-Control": "max-age=10",
            "Content-Disposition": "inline",
            "Content-Encoding": "gzip",
            "Content-Language": "en-US",
            "Expires": "Wed, 21 Oct 2030 07:28:00 GMT",
            "x-oss-storage-class": "IA",
            "x-oss-server-side-encryption": "KMS",
            "x-oss-server-side-encryption-key-id": "kms-key-1",
            "x-oss-server-side-data-encryption": "SM4",
            "x-oss-meta-origin": "old",
            "x-oss-version-id": "source-v1"
        ]
        let expected = OSSObjectSnapshot(
            head: ObjectHead(
                contentType: "text/plain",
                contentLength: 5,
                lastModified: nil,
                etag: "source-etag",
                acl: nil,
                storageClass: "IA",
                cacheControl: "max-age=10",
                contentDisposition: "inline",
                contentEncoding: "gzip",
                contentLanguage: "en-US",
                expires: "Wed, 21 Oct 2030 07:28:00 GMT",
                serverSideEncryption: "KMS",
                serverSideEncryptionKeyID: "kms-key-1",
                serverSideDataEncryption: "SM4",
                userMetadata: ["origin": "old"],
                versionID: "source-v1"
            ),
            acl: .publicRead,
            tags: tags,
            etag: "source-etag"
        )
        let transport = StubOSSTransport(steps: [
            .response(status: 200, headers: headHeaders, data: Data()),
            .response(
                status: 200,
                headers: [:],
                data: Data("<AccessControlPolicy><AccessControlList><Grant>public-read</Grant></AccessControlList></AccessControlPolicy>".utf8)
            ),
            .response(status: 200, headers: [:], data: OSSXML.taggingData(tags)),
            .response(status: 200, headers: headHeaders, data: Data()),
            .response(status: 200, headers: ["x-oss-version-id": "metadata-v2"], data: Data())
        ])
        let properties = OSSObjectProperties(
            contentType: "text/custom",
            cacheControl: "max-age=60",
            contentDisposition: "attachment; filename=file.txt",
            userMetadata: ["origin": "updated"]
        )

        let versionID = try await Self.client(
            transport: transport,
            versioningStatusOverride: .enabled
        ).replaceMetadata(key: "object.txt", properties: properties, expected: expected)

        #expect(versionID == "metadata-v2")
        let request = try #require(await transport.recordedRequests().last)
        #expect(request.httpMethod == "PUT")
        #expect(request.value(forHTTPHeaderField: "x-oss-copy-source") == "/bucket/object.txt?versionId=source-v1")
        #expect(request.value(forHTTPHeaderField: "x-oss-copy-source-if-match") == "\"source-etag\"")
        #expect(request.value(forHTTPHeaderField: "x-oss-object-acl") == "public-read")
        #expect(request.value(forHTTPHeaderField: "x-oss-storage-class") == "IA")
        #expect(request.value(forHTTPHeaderField: "x-oss-server-side-encryption") == "KMS")
        #expect(request.value(forHTTPHeaderField: "x-oss-server-side-encryption-key-id") == "kms-key-1")
        #expect(request.value(forHTTPHeaderField: "x-oss-server-side-data-encryption") == "SM4")
        #expect(request.value(forHTTPHeaderField: "x-oss-metadata-directive") == "REPLACE")
        #expect(request.value(forHTTPHeaderField: "x-oss-tagging-directive") == "Replace")
        #expect(request.value(forHTTPHeaderField: "x-oss-tagging") == "Owner=Alice%20Smith&env=prod")
        #expect(request.value(forHTTPHeaderField: "Content-Encoding") == "gzip")
        #expect(request.value(forHTTPHeaderField: "Content-Language") == "en-US")
        #expect(request.value(forHTTPHeaderField: "Expires") == "Wed, 21 Oct 2030 07:28:00 GMT")
        #expect(request.value(forHTTPHeaderField: "x-oss-meta-origin") == "updated")
    }

    @Test func downloadWithoutServerCRCStillPublishesTheDestination() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-missing-crc-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "download.txt")
        let temporary = directory.appending(path: "response.tmp")
        let payload = Data("downloaded bytes".utf8)
        try payload.write(to: temporary)
        let transport = StubOSSTransport(steps: [
            .download(temporary, headers: [:])
        ])

        let verified = try await Self.client(transport: transport).download(
            key: "download.txt",
            to: destination,
            within: directory
        )

        #expect(verified == false)
        #expect(try Data(contentsOf: destination) == payload)
    }

    @Test func putObjectTreatsAnyExistingObjectAsAConflictEvenWhenBytesMatch() async throws {
        let payload = Data("same-bytes".utf8)
        let file = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-put-exists-\(UUID().uuidString).txt")
        try payload.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let checksum = CRC64XZ.checksum(payload)
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: [
                    "Content-Length": "\(payload.count)",
                    "x-oss-hash-crc64ecma": String(checksum)
                ],
                data: Data()
            )
        ])

        await #expect(throws: OSSServiceError.self) {
            _ = try await Self.client(transport: transport).putObject(
                key: "same.txt",
                fileURL: file,
                contentType: "text/plain",
                acl: .private
            )
        }

        let requests = await transport.recordedRequests()
        #expect(requests.map(\.httpMethod) == ["HEAD"])
    }

    @Test func putObjectRejectsADifferentExistingObject() async throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-put-conflict-\(UUID().uuidString).txt")
        try Data("local".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: ["Content-Length": "99"],
                data: Data()
            )
        ])

        await #expect(throws: OSSServiceError.self) {
            try await Self.client(transport: transport).putObject(
                key: "other.txt",
                fileURL: file,
                contentType: "text/plain",
                acl: .private
            )
        }
        #expect(await transport.recordedRequests().map(\.httpMethod) == ["HEAD"])
    }

    @Test func sameSizeWithoutCRCIsNeverAcceptedAsTheSameObject() async throws {
        let payload = Data("local".utf8)
        let file = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-put-size-only-\(UUID().uuidString).txt")
        try payload.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: ["Content-Length": "\(payload.count)"],
                data: Data()
            )
        ])

        await #expect(throws: OSSServiceError.self) {
            _ = try await Self.client(transport: transport).putObject(
                key: "unknown.txt",
                fileURL: file,
                contentType: "text/plain",
                acl: .private
            )
        }

        #expect(await transport.recordedRequests().map(\.httpMethod) == ["HEAD"])
    }

    @Test func enabledBatchCopyCreatesANewVersionAndReturnsItsExactIdentity() async throws {
        let mapping = CloudObjectMapping(sourceKey: "old/a.txt", destinationKey: "new/a.txt")
        var steps: [StubOSSTransport.Step] = [
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "destination"))
        ]
        steps += Self.snapshotSteps(etag: "source-a", versionID: "source-a-v1", size: 7)
        steps += [
            .response(status: 200, headers: ["x-oss-version-id": "created-v1"], data: Data()),
            .response(
                status: 200,
                headers: ["Content-Length": "7", "ETag": "created-etag", "x-oss-version-id": "created-v1"],
                data: Data()
            )
        ]
        let transport = StubOSSTransport(steps: steps)

        let committed = try await Self.client(
            transport: transport,
            versioningStatusOverride: .enabled
        ).performCloudOperation([mapping], mode: .copy)

        #expect(committed["new/a.txt"] == OSSObjectIdentity(
            etag: "created-etag",
            versionID: "created-v1",
            size: 7
        ))
        let put = try #require(await transport.recordedRequests().first { $0.httpMethod == "PUT" })
        #expect(put.value(forHTTPHeaderField: "x-oss-forbid-overwrite") == "true")
        #expect(put.value(forHTTPHeaderField: "x-oss-copy-source") == "/bucket/old/a.txt?versionId=source-a-v1")
    }

    @Test func mixedLargeBatchFailsBeforeTheFirstCopy() async throws {
        let mappings = [
            CloudObjectMapping(sourceKey: "old/small.bin", destinationKey: "new/small.bin"),
            CloudObjectMapping(sourceKey: "old/large.bin", destinationKey: "new/large.bin")
        ]
        var steps: [StubOSSTransport.Step] = [
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "dest-small")),
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "dest-large"))
        ]
        steps += Self.snapshotSteps(etag: "source-small", versionID: "source-small-v1", size: 1)
        steps += Self.snapshotSteps(
            etag: "source-large",
            versionID: "source-large-v1",
            size: OSSClient.maximumSingleCopyBytes + 1
        )
        let transport = StubOSSTransport(steps: steps)

        do {
            _ = try await Self.client(
                transport: transport,
                versioningStatusOverride: .enabled
            ).performCloudOperation(mappings, mode: .copy)
            Issue.record("Expected large-copy rejection")
        } catch let error as OSSServiceError {
            #expect(error.code == "CopyObjectTooLarge")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await transport.recordedRequests().allSatisfy { $0.httpMethod != "PUT" })
    }

    @Test func mutableOverlappingSourcesFailBeforeTheFirstCopy() async throws {
        let mappings = [
            CloudObjectMapping(sourceKey: "a.txt", destinationKey: "b.txt"),
            CloudObjectMapping(sourceKey: "b.txt", destinationKey: "c.txt")
        ]
        var steps: [StubOSSTransport.Step] = [
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "not-yet-visible", requestID: "dest-b")),
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "dest-c"))
        ]
        steps += Self.mutableSnapshotSteps(etag: "source-a")
        steps += Self.mutableSnapshotSteps(etag: "source-b")
        let transport = StubOSSTransport(steps: steps)

        do {
            _ = try await Self.client(transport: transport).performCloudOperation(mappings, mode: .copy)
            Issue.record("Expected mutable overlap rejection")
        } catch let error as OSSServiceError {
            #expect(error.code == "MutableSourceOverlap")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await transport.recordedRequests().allSatisfy { $0.httpMethod != "PUT" })
    }

    @Test func expectedSourceChangeFailsBeforeTheFirstCopy() async throws {
        let mapping = CloudObjectMapping(sourceKey: "old/a.txt", destinationKey: "new/a.txt")
        var steps: [StubOSSTransport.Step] = [
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "destination"))
        ]
        steps += Self.snapshotSteps(etag: "source-new", versionID: "source-v2", size: 1)
        let transport = StubOSSTransport(steps: steps)

        do {
            _ = try await Self.client(
                transport: transport,
                versioningStatusOverride: .enabled
            ).performCloudOperation(
                [mapping],
                mode: .copy,
                expectedSources: [
                    "old/a.txt": OSSObjectIdentity(etag: "source-old", versionID: "source-v1", size: 1)
                ]
            )
            Issue.record("Expected source change")
        } catch let error as OSSServiceError {
            #expect(error.code == "SourceObjectChanged")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await transport.recordedRequests().allSatisfy { $0.httpMethod != "PUT" })
    }

    @Test func expectedDestinationChangeAfterBackupFailsBeforeTheFirstCopy() async throws {
        let mapping = CloudObjectMapping(sourceKey: "old/a.txt", destinationKey: "new/a.txt")
        let transport = StubOSSTransport(steps: [
            .response(
                status: 200,
                headers: [
                    "Content-Length": "1",
                    "ETag": "concurrent-etag",
                    "x-oss-version-id": "concurrent-v2"
                ],
                data: Data()
            )
        ])

        do {
            _ = try await Self.client(
                transport: transport,
                versioningStatusOverride: .enabled
            ).performCloudOperation(
                [mapping],
                mode: .copy,
                expectedDestinations: [
                    "new/a.txt": OSSObjectIdentity(etag: "backup-etag", versionID: "backup-v1", size: 1)
                ]
            )
            Issue.record("Expected destination change")
        } catch let error as OSSServiceError {
            #expect(error.code == "DestinationChanged")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await transport.recordedRequests().map(\.httpMethod) == ["HEAD"])
    }

    @Test func batchVersioningChangeToSuspendedStopsBeforeCopy() async throws {
        let mapping = CloudObjectMapping(sourceKey: "old/a.txt", destinationKey: "new/a.txt")
        var steps: [StubOSSTransport.Step] = [
            .response(status: 200, headers: [:], data: Data("<VersioningConfiguration />".utf8)),
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "destination"))
        ]
        steps += Self.mutableSnapshotSteps(etag: "source-a")
        steps += [
            .response(
                status: 200,
                headers: [:],
                data: Data("<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>".utf8)
            )
        ]
        let transport = StubOSSTransport(steps: steps)

        await #expect(throws: CloudObjectOperationError.self) {
            _ = try await Self.client(
                transport: transport,
                versioningStatusOverride: nil
            ).performCloudOperation([mapping], mode: .copy)
        }

        let requests = await transport.recordedRequests()
        #expect(requests.filter { $0.url?.query == "versioning" }.count == 2)
        #expect(requests.allSatisfy { $0.httpMethod != "PUT" })
    }

    @Test func overwriteBatchRollsBackAnExistingDestinationByItsCommittedVersion() async throws {
        let mappings = [
            CloudObjectMapping(sourceKey: "old/a.txt", destinationKey: "new/a.txt"),
            CloudObjectMapping(sourceKey: "old/b.txt", destinationKey: "new/b.txt")
        ]
        var steps: [StubOSSTransport.Step] = [
            .response(
                status: 200,
                headers: [
                    "Content-Length": "1",
                    "ETag": "destination-a-old",
                    "x-oss-version-id": "destination-a-v1"
                ],
                data: Data()
            ),
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "head-b")),
        ]
        steps += Self.snapshotSteps(etag: "source-a", versionID: "source-a-v1")
        steps += Self.snapshotSteps(etag: "source-b", versionID: "source-b-v1")
        steps += [
            .response(
                status: 200,
                headers: [
                    "Content-Length": "1",
                    "ETag": "destination-a-old",
                    "x-oss-version-id": "destination-a-v1"
                ],
                data: Data()
            ),
            .response(status: 200, headers: ["x-oss-version-id": "replacement-a"], data: Data()),
            .response(
                status: 200,
                headers: [
                    "Content-Length": "1",
                    "ETag": "replacement-a-etag",
                    "x-oss-version-id": "replacement-a"
                ],
                data: Data()
            ),
            .response(status: 500, headers: [:], data: Self.errorXML(code: "InternalError", message: "copy failed", requestID: "copy-b")),
            .response(status: 204, headers: [:], data: Data())
        ]
        let transport = StubOSSTransport(steps: steps)

        do {
            try await Self.client(
                transport: transport,
                versioningStatusOverride: .enabled
            ).performCloudOperation(
                mappings,
                mode: .copy,
                overwrite: true
            )
            Issue.record("Expected copyPhaseFailed")
        } catch let error as CloudObjectOperationError {
            guard case .copyPhaseFailed(
                _,
                let modifiedExistingDestinations,
                let residualDestinations,
                let uncertainDestinations
            ) = error else {
                Issue.record("Unexpected cloud error: \(error)")
                return
            }
            #expect(modifiedExistingDestinations.isEmpty)
            #expect(residualDestinations.isEmpty)
            #expect(uncertainDestinations == ["new/b.txt"])
        }

        let requests = await transport.recordedRequests()
        let delete = try #require(requests.last)
        #expect(delete.httpMethod == "DELETE")
        #expect(delete.url?.query == "versionId=replacement-a")
        #expect(requests.filter { $0.httpMethod == "PUT" }.count == 2)
    }

    @Test func overwriteAllowlistRejectsANewConflictBeforeAnyCopyStarts() async throws {
        let mappings = [
            CloudObjectMapping(sourceKey: "old/a.txt", destinationKey: "new/a.txt"),
            CloudObjectMapping(sourceKey: "old/b.txt", destinationKey: "new/b.txt")
        ]
        let transport = StubOSSTransport(steps: [
            // A was discovered and backed up by the caller, so replacement is
            // authorized. B appeared after that scan and must stay protected.
            .response(status: 200, headers: ["Content-Length": "1", "ETag": "old-a"], data: Data()),
            .response(status: 200, headers: ["Content-Length": "1", "ETag": "new-b"], data: Data())
        ])

        await #expect(throws: CloudObjectOperationError.destinationExists("new/b.txt")) {
            try await Self.client(
                transport: transport,
                versioningStatusOverride: .enabled
            ).performCloudOperation(
                mappings,
                mode: .copy,
                overwrite: true,
                overwriteDestinations: ["new/a.txt"]
            )
        }

        let requests = await transport.recordedRequests()
        #expect(requests.map(\.httpMethod) == ["HEAD", "HEAD"])
        #expect(requests.allSatisfy { $0.httpMethod != "PUT" })
    }

    @Test func overwriteBatchRollsBackOnlyANewDestinationByExactVersion() async throws {
        let mappings = [
            CloudObjectMapping(sourceKey: "old/a.txt", destinationKey: "new/a.txt"),
            CloudObjectMapping(sourceKey: "old/b.txt", destinationKey: "new/b.txt")
        ]
        var steps: [StubOSSTransport.Step] = [
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "head-a")),
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "head-b")),
        ]
        steps += Self.snapshotSteps(etag: "source-a", versionID: "source-a-v1")
        steps += Self.snapshotSteps(etag: "source-b", versionID: "source-b-v1")
        steps += [
            .response(status: 200, headers: ["x-oss-version-id": "created-a"], data: Data()),
            .response(
                status: 200,
                headers: [
                    "Content-Length": "1",
                    "ETag": "created-a-etag",
                    "x-oss-version-id": "created-a"
                ],
                data: Data()
            ),
            .response(status: 500, headers: [:], data: Self.errorXML(code: "InternalError", message: "copy failed", requestID: "copy-b")),
            .response(status: 204, headers: [:], data: Data())
        ]
        let transport = StubOSSTransport(steps: steps)

        do {
            try await Self.client(
                transport: transport,
                versioningStatusOverride: .enabled
            ).performCloudOperation(
                mappings,
                mode: .copy,
                overwrite: true
            )
            Issue.record("Expected copyPhaseFailed")
        } catch let error as CloudObjectOperationError {
            guard case .copyPhaseFailed(
                _,
                let modifiedExistingDestinations,
                let residualDestinations,
                let uncertainDestinations
            ) = error else {
                Issue.record("Unexpected cloud error: \(error)")
                return
            }
            #expect(modifiedExistingDestinations.isEmpty)
            #expect(residualDestinations.isEmpty)
            #expect(uncertainDestinations == ["new/b.txt"])
        }

        let delete = try #require(await transport.recordedRequests().last)
        #expect(delete.httpMethod == "DELETE")
        #expect(delete.url?.path == "/new/a.txt")
        #expect(delete.url?.query == "versionId=created-a")
    }

    @Test func failedExactVersionRollbackReportsTheResidualDestination() async throws {
        let mappings = [
            CloudObjectMapping(sourceKey: "old/a.txt", destinationKey: "new/a.txt"),
            CloudObjectMapping(sourceKey: "old/b.txt", destinationKey: "new/b.txt")
        ]
        var steps: [StubOSSTransport.Step] = [
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "head-a")),
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "head-b")),
        ]
        steps += Self.snapshotSteps(etag: "source-a", versionID: "source-a-v1")
        steps += Self.snapshotSteps(etag: "source-b", versionID: "source-b-v1")
        steps += [
            .response(status: 200, headers: ["x-oss-version-id": "created-a"], data: Data()),
            .response(
                status: 200,
                headers: [
                    "Content-Length": "1",
                    "ETag": "created-a-etag",
                    "x-oss-version-id": "created-a"
                ],
                data: Data()
            ),
            .response(status: 500, headers: [:], data: Self.errorXML(code: "InternalError", message: "copy failed", requestID: "copy-b")),
            .response(status: 500, headers: [:], data: Self.errorXML(code: "InternalError", message: "cleanup failed", requestID: "delete-a"))
        ]
        let transport = StubOSSTransport(steps: steps)

        do {
            try await Self.client(
                transport: transport,
                versioningStatusOverride: .enabled
            ).performCloudOperation(mappings, mode: .copy)
            Issue.record("Expected copyPhaseFailed")
        } catch let error as CloudObjectOperationError {
            guard case .copyPhaseFailed(
                _,
                let modifiedExistingDestinations,
                let residualDestinations,
                let uncertainDestinations
            ) = error else {
                Issue.record("Unexpected cloud error: \(error)")
                return
            }
            #expect(modifiedExistingDestinations.isEmpty)
            #expect(residualDestinations == ["new/a.txt"])
            #expect(uncertainDestinations == ["new/b.txt"])
        }

        let delete = try #require(await transport.recordedRequests().last)
        #expect(delete.httpMethod == "DELETE")
        #expect(delete.url?.query == "versionId=created-a")
    }

    @Test func ambiguousSourceCleanupFailureNeverDeletesTheCommittedDestination() async throws {
        let listing = Data("""
        <ListBucketResult>
          <IsTruncated>false</IsTruncated>
          <Contents><Key>old/a.txt</Key><Size>1</Size><ETag>a</ETag></Contents>
        </ListBucketResult>
        """.utf8)
        var steps: [StubOSSTransport.Step] = [
            .response(status: 200, headers: [:], data: listing),
            .response(status: 404, headers: [:], data: Self.errorXML(code: "NoSuchKey", message: "missing", requestID: "head-a")),
        ]
        steps += Self.snapshotSteps(etag: "source-a", versionID: "source-a-v1")
        steps += [
            .response(status: 200, headers: ["x-oss-version-id": "copied-v1"], data: Data()),
            .response(
                status: 200,
                headers: [
                    "Content-Length": "1",
                    "ETag": "copied-etag",
                    "x-oss-version-id": "copied-v1"
                ],
                data: Data()
            )
        ]
        steps += Self.snapshotSteps(etag: "source-a", versionID: "source-a-v1")
        steps += [
            .cancel
        ]
        let transport = StubOSSTransport(steps: steps)

        await #expect(throws: CloudObjectOperationError.sourceCleanupFailed(
            failedSource: "old/a.txt",
            removedSources: [],
            uncertainSources: ["old/a.txt"],
            residualDestinations: ["new/a.txt"]
        )) {
            try await Self.client(
                transport: transport,
                versioningStatusOverride: .enabled
            ).movePrefix(from: "old/", to: "new/")
        }

        let requests = await transport.recordedRequests()
        #expect(requests.map(\.httpMethod) == [
            "GET", "HEAD", "HEAD", "GET", "GET", "PUT", "HEAD", "HEAD", "GET", "GET", "DELETE"
        ])
        #expect(requests.last?.url?.path == "/old/a.txt")
    }

    @Test func partialMoveFailureReportsExactlyWhichSourcesWereAlreadyRemoved() async throws {
        let mappings = [
            CloudObjectMapping(sourceKey: "old/long-a.txt", destinationKey: "new/long-a.txt"),
            CloudObjectMapping(sourceKey: "old/b.txt", destinationKey: "new/b.txt")
        ]
        var steps: [StubOSSTransport.Step] = [
            .response(
                status: 200,
                headers: ["Content-Length": "1", "ETag": "old-dest-a", "x-oss-version-id": "dest-a-v1"],
                data: Data()
            ),
            .response(
                status: 200,
                headers: ["Content-Length": "1", "ETag": "old-dest-b", "x-oss-version-id": "dest-b-v1"],
                data: Data()
            )
        ]
        steps += Self.snapshotSteps(etag: "source-a", versionID: "source-a-v1")
        steps += Self.snapshotSteps(etag: "source-b", versionID: "source-b-v1")
        steps += [
            .response(
                status: 200,
                headers: ["Content-Length": "1", "ETag": "old-dest-a", "x-oss-version-id": "dest-a-v1"],
                data: Data()
            ),
            .response(status: 200, headers: ["x-oss-version-id": "replacement-a"], data: Data()),
            .response(
                status: 200,
                headers: ["Content-Length": "1", "ETag": "replacement-a-etag", "x-oss-version-id": "replacement-a"],
                data: Data()
            ),
            .response(
                status: 200,
                headers: ["Content-Length": "1", "ETag": "old-dest-b", "x-oss-version-id": "dest-b-v1"],
                data: Data()
            ),
            .response(status: 200, headers: ["x-oss-version-id": "replacement-b"], data: Data()),
            .response(
                status: 200,
                headers: ["Content-Length": "1", "ETag": "replacement-b-etag", "x-oss-version-id": "replacement-b"],
                data: Data()
            )
        ]
        steps += Self.snapshotSteps(etag: "source-a", versionID: "source-a-v1")
        steps += [.response(status: 204, headers: [:], data: Data())]
        steps += Self.snapshotSteps(etag: "source-b", versionID: "source-b-v1")
        steps += [
            .response(status: 500, headers: [:], data: Self.errorXML(code: "InternalError", message: "delete failed", requestID: "delete-b"))
        ]
        let transport = StubOSSTransport(steps: steps)

        do {
            try await Self.client(
                transport: transport,
                versioningStatusOverride: .enabled
            ).performCloudOperation(
                mappings,
                mode: .move,
                overwriteDestinations: ["new/long-a.txt", "new/b.txt"]
            )
            Issue.record("Expected sourceCleanupFailed")
        } catch let error as CloudObjectOperationError {
            guard case .sourceCleanupFailed(
                let failedSource,
                let removedSources,
                let uncertainSources,
                let residualDestinations
            ) = error else {
                Issue.record("Unexpected cloud error: \(error)")
                return
            }
            #expect(failedSource == "old/b.txt")
            #expect(removedSources == ["old/long-a.txt"])
            #expect(uncertainSources == ["old/b.txt"])
            #expect(residualDestinations == ["new/b.txt"])
        }

        let requests = await transport.recordedRequests()
        #expect(requests.filter { $0.httpMethod == "PUT" }.count == 2)
        #expect(requests.filter { $0.httpMethod == "DELETE" }.count == 2)
        #expect(requests.last?.url?.query == "versionId=source-b-v1")
    }

    private static func client(
        transport: any OSSHTTPTransport,
        retryPolicy: OSSRetryPolicy = OSSRetryPolicy(maxAttempts: 1, jitter: { 0 }),
        retrySleeper: any OSSRetrySleeping = RecordingRetrySleeper(),
        versioningStatusOverride: OSSBucketVersioningStatus? = .disabled
    ) -> OSSClient {
        OSSClient(
            credentials: OSSCredentials(
                accessKeyId: "test-id",
                accessKeySecret: "test-secret",
                securityToken: nil
            ),
            region: "cn-hangzhou",
            endpointHost: "oss-cn-hangzhou.aliyuncs.com",
            bucket: "bucket",
            transport: transport,
            retryPolicy: retryPolicy,
            retrySleeper: retrySleeper,
            testingVersioningStatusOverride: versioningStatusOverride
        )
    }

    private static func errorXML(code: String, message: String, requestID: String) -> Data {
        Data("<Error><Code>\(code)</Code><Message>\(message)</Message><RequestId>\(requestID)</RequestId></Error>".utf8)
    }

    private static let privateACLXML = Data(
        "<AccessControlPolicy><AccessControlList><Grant>private</Grant></AccessControlList></AccessControlPolicy>".utf8
    )

    private static let emptyTagsXML = Data(
        "<Tagging><TagSet></TagSet></Tagging>".utf8
    )

    private static func snapshotSteps(
        etag: String,
        versionID: String,
        size: Int64 = 1,
        acl: ObjectACL = .private,
        tags: [OSSObjectTag] = [],
        additionalHeaders: [String: String] = [:]
    ) -> [StubOSSTransport.Step] {
        var headers = additionalHeaders
        headers["Content-Length"] = String(size)
        headers["ETag"] = etag
        headers["x-oss-version-id"] = versionID
        let aclXML = Data(
            "<AccessControlPolicy><AccessControlList><Grant>\(acl.rawValue)</Grant></AccessControlList></AccessControlPolicy>".utf8
        )
        return [
            .response(status: 200, headers: headers, data: Data()),
            .response(status: 200, headers: [:], data: aclXML),
            .response(status: 200, headers: [:], data: OSSXML.taggingData(tags))
        ]
    }

    private static func mutableSnapshotSteps(
        etag: String,
        size: Int64 = 1,
        acl: ObjectACL = .private,
        tags: [OSSObjectTag] = []
    ) -> [StubOSSTransport.Step] {
        let headers = ["Content-Length": String(size), "ETag": etag]
        let aclXML = Data(
            "<AccessControlPolicy><AccessControlList><Grant>\(acl.rawValue)</Grant></AccessControlList></AccessControlPolicy>".utf8
        )
        return [
            .response(status: 200, headers: headers, data: Data()),
            .response(status: 200, headers: [:], data: aclXML),
            .response(status: 200, headers: [:], data: OSSXML.taggingData(tags)),
            .response(status: 200, headers: headers, data: Data())
        ]
    }

    private static func multipartFile(parts: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-multipart-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(Int64(parts) * OSSClient.partSize))
        try handle.close()
        return url
    }

    private static func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "ossuno-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class CheckpointRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MultipartUploadCheckpoint?] = []

    var values: [MultipartUploadCheckpoint?] { lock.withLock { storage } }

    func append(_ checkpoint: MultipartUploadCheckpoint?) {
        lock.withLock { storage.append(checkpoint) }
    }
}

private final class DownloadCheckpointRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RangeDownloadCheckpoint?] = []

    var values: [RangeDownloadCheckpoint?] { lock.withLock { storage } }

    func append(_ checkpoint: RangeDownloadCheckpoint?) {
        lock.withLock { storage.append(checkpoint) }
    }
}

private actor StubOSSTransport: OSSHTTPTransport {
    enum Step: Sendable {
        case response(status: Int, headers: [String: String], data: Data)
        case download(URL, headers: [String: String])
        case cancel
        case failure(URLError.Code)
        case mutateFile(URL, status: Int, headers: [String: String], data: Data)
    }

    private var steps: [Step]
    private var requests: [URLRequest] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        requests.append(request)
        guard !steps.isEmpty else {
            throw OSSServiceError(statusCode: 0, code: "NoStub", message: "Missing stub response", requestId: "")
        }
        switch steps.removeFirst() {
        case .response(let status, let headers, let data):
            return OSSHTTPResult(status: status, headers: headers, data: data, temporaryDownloadURL: nil)
        case .download(let url, let headers):
            return OSSHTTPResult(status: 200, headers: headers, data: Data(), temporaryDownloadURL: url)
        case .cancel:
            throw CancellationError()
        case .failure(let code):
            throw URLError(code)
        case .mutateFile(let url, let status, let headers, let data):
            var contents = try Data(contentsOf: url)
            contents.append(0xFF)
            try contents.write(to: url)
            return OSSHTTPResult(
                status: status,
                headers: headers,
                data: data,
                temporaryDownloadURL: nil
            )
        }
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

private actor RecordingRetrySleeper: OSSRetrySleeping {
    private var delays: [Duration] = []

    func sleep(for delay: Duration) async throws {
        delays.append(delay)
    }

    func recordedDelays() -> [Duration] {
        delays
    }
}
