import Foundation
import Testing
@testable import Ossuno

struct OSSXMLACLTests {
    @Test(arguments: [
        ("default", ObjectACL.default),
        ("private", ObjectACL.private),
        ("public-read", ObjectACL.publicRead),
        ("public-read-write", ObjectACL.publicReadWrite)
    ])
    func parsesKnownObjectACLs(grant: String, expected: ObjectACL) throws {
        let data = Data("""
        <AccessControlPolicy>
          <AccessControlList><Grant>\(grant)</Grant></AccessControlList>
        </AccessControlPolicy>
        """.utf8)

        #expect(try OSSXML.objectACL(from: data) == expected)
    }

    @Test func acceptsAccessControlListAsRoot() throws {
        let data = Data("<AccessControlList><Grant>private</Grant></AccessControlList>".utf8)
        #expect(try OSSXML.objectACL(from: data) == .private)
    }

    @Test(arguments: [
        "<AccessControlPolicy />",
        "<AccessControlPolicy><AccessControlList /></AccessControlPolicy>",
        "<AccessControlPolicy><AccessControlList><Grant> </Grant></AccessControlList></AccessControlPolicy>",
        "<AccessControlPolicy><AccessControlList><Grant>private</Grant><Grant>public-read</Grant></AccessControlList></AccessControlPolicy>"
    ])
    func rejectsMissingOrAmbiguousGrant(xml: String) {
        #expect(throws: OSSServiceError.self) {
            try OSSXML.objectACL(from: Data(xml.utf8))
        }
    }

    @Test func rejectsUnknownGrant() {
        let data = Data("""
        <AccessControlPolicy>
          <AccessControlList><Grant>authenticated-read</Grant></AccessControlList>
        </AccessControlPolicy>
        """.utf8)

        #expect(throws: OSSServiceError.self) {
            try OSSXML.objectACL(from: data)
        }
    }

    @Test func parsesStrictBucketVersioningConfiguration() throws {
        #expect(try OSSXML.bucketVersioningStatus(
            from: Data("<VersioningConfiguration />".utf8)
        ) == .disabled)
        #expect(try OSSXML.bucketVersioningStatus(
            from: Data("<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>".utf8)
        ) == .enabled)
        #expect(try OSSXML.bucketVersioningStatus(
            from: Data("<VersioningConfiguration><Status>FutureMode</Status></VersioningConfiguration>".utf8)
        ) == .unknown)
    }

    @Test(arguments: [
        "<html />",
        "<VersioningConfiguration><Status /></VersioningConfiguration>",
        "<VersioningConfiguration><Status>   </Status></VersioningConfiguration>",
        "<VersioningConfiguration><Status>Enabled</Status><Status>Suspended</Status></VersioningConfiguration>"
    ])
    func rejectsMalformedBucketVersioningConfiguration(xml: String) {
        #expect(throws: OSSServiceError.self) {
            try OSSXML.bucketVersioningStatus(from: Data(xml.utf8))
        }
    }

    @Test func objectTagsPreserveLegalWhitespaceAndCaseSensitiveKeys() throws {
        let data = Data("""
        <Tagging><TagSet>
          <Tag><Key>Owner</Key><Value> Alice </Value></Tag>
          <Tag><Key>owner</Key><Value>Bob</Value></Tag>
        </TagSet></Tagging>
        """.utf8)

        #expect(try OSSXML.tags(from: data) == [
            OSSObjectTag(key: "Owner", value: " Alice "),
            OSSObjectTag(key: "owner", value: "Bob")
        ])
    }

    @Test(arguments: [
        "<Tagging />",
        "<Tagging><TagSet><Tag><Value>missing-key</Value></Tag></TagSet></Tagging>",
        "<Tagging><TagSet><Tag><Key>bad?</Key><Value>value</Value></Tag></TagSet></Tagging>",
        "<Tagging><TagSet><Tag><Key>same</Key></Tag><Tag><Key>same</Key></Tag></TagSet></Tagging>"
    ])
    func rejectsMalformedObjectTags(xml: String) {
        #expect(throws: OSSServiceError.self) {
            try OSSXML.tags(from: Data(xml.utf8))
        }
    }

    @Test func listingPreservesLeadingAndTrailingSpacesInKeys() throws {
        let data = Data("""
        <ListBucketResult>
          <CommonPrefixes><Prefix> folder/</Prefix></CommonPrefixes>
          <Contents><Key> photo.jpg</Key><Size>1</Size><ETag>a</ETag></Contents>
          <Contents><Key>photo.jpg </Key><Size>2</Size><ETag>b</ETag></Contents>
          <IsTruncated>true</IsTruncated>
          <NextContinuationToken> token + value </NextContinuationToken>
        </ListBucketResult>
        """.utf8)

        let listing = try OSSXML.listing(from: data)
        #expect(listing.folders.map(\.prefix) == [" folder/"])
        #expect(listing.objects.map(\.key) == [" photo.jpg", "photo.jpg "])
        #expect(listing.nextToken == " token + value ")
    }

    @Test func completeMultipartUploadXMLEscapesETags() {
        let xml = String(
            data: OSSXML.completeMultipartUploadXML(parts: [
                (number: 2, etag: "b&2"),
                (number: 1, etag: "a<1>")
            ]),
            encoding: .utf8
        )
        #expect(
            xml == "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>\"a&lt;1&gt;\"</ETag></Part><Part><PartNumber>2</PartNumber><ETag>\"b&amp;2\"</ETag></Part></CompleteMultipartUpload>"
        )
    }
}
