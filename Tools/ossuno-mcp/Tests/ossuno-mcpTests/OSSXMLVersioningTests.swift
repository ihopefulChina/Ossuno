import Foundation
import XCTest
@testable import ossuno_mcp

final class OSSXMLVersioningTests: XCTestCase, @unchecked Sendable {
    func testParsesEnabledSuspendedAndUnconfiguredStates() throws {
        XCTAssertEqual(
            try parse("<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>"),
            .enabled
        )
        XCTAssertEqual(
            try parse("<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>"),
            .suspended
        )
        XCTAssertEqual(try parse("<VersioningConfiguration/>"), .unconfigured)
        XCTAssertEqual(
            try parse("<VersioningConfiguration><Status>  </Status></VersioningConfiguration>"),
            .unconfigured
        )
    }

    func testRejectsUnknownStatusAndUnexpectedRoot() {
        XCTAssertThrowsError(
            try parse("<VersioningConfiguration><Status>Future</Status></VersioningConfiguration>")
        ) { error in
            XCTAssertEqual((error as? OSSServiceError)?.code, "InvalidVersioningStatus")
        }
        XCTAssertThrowsError(try parse("<NotVersioning/>")) { error in
            XCTAssertEqual((error as? OSSServiceError)?.code, "InvalidVersioningResponse")
        }
    }

    private func parse(_ xml: String) throws -> OSSBucketVersioningStatus {
        try OSSXML.bucketVersioningStatus(from: Data(xml.utf8))
    }

    func testListingPreservesLeadingAndTrailingSpacesInKeys() throws {
        let xml = """
            <ListBucketResult>
              <CommonPrefixes><Prefix> folder/</Prefix></CommonPrefixes>
              <Contents><Key> photo.jpg</Key><Size>1</Size><ETag>a</ETag></Contents>
              <Contents><Key>photo.jpg </Key><Size>2</Size><ETag>b</ETag></Contents>
              <IsTruncated>true</IsTruncated>
              <NextContinuationToken> token + value </NextContinuationToken>
            </ListBucketResult>
            """
        let listing = try OSSXML.listing(from: Data(xml.utf8))
        XCTAssertEqual(listing.folders.map(\.prefix), [" folder/"])
        XCTAssertEqual(listing.objects.map(\.key), [" photo.jpg", "photo.jpg "])
        XCTAssertEqual(listing.nextToken, " token + value ")
    }
}
