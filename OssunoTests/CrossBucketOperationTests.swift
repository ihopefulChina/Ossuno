import Foundation
import Testing
@testable import Ossuno

struct CrossBucketOperationTests {
    @Test func methodSelectionRequiresSameAccountAndRegionForServerSideCopy() {
        let account = UUID()
        #expect(CrossBucketOperation.method(sourceAccountID: account, destinationAccountID: account, sourceRegion: "cn-hangzhou", destinationRegion: "cn-hangzhou") == .serverSide)
        #expect(CrossBucketOperation.method(sourceAccountID: account, destinationAccountID: account, sourceRegion: "cn-hangzhou", destinationRegion: "cn-shanghai") == .relay)
        #expect(CrossBucketOperation.method(sourceAccountID: account, destinationAccountID: UUID(), sourceRegion: "cn-hangzhou", destinationRegion: "cn-hangzhou") == .relay)
    }

    @Test func objectsLargerThanSingleCopyLimitUseRelay() {
        let small = CrossBucketMapping(
            sourceKey: "small.bin",
            destinationKey: "archive/small.bin",
            expectedSize: CrossBucketOperation.maximumSingleCopyBytes
        )
        let large = CrossBucketMapping(
            sourceKey: "large.bin",
            destinationKey: "archive/large.bin",
            expectedSize: CrossBucketOperation.maximumSingleCopyBytes + 1
        )

        #expect(CrossBucketOperation.executionMethod(preferred: .serverSide, mappings: [small]) == .serverSide)
        #expect(CrossBucketOperation.executionMethod(preferred: .serverSide, mappings: [small, large]) == .relay)
        #expect(CrossBucketOperation.executionMethod(preferred: .relay, mappings: [small]) == .relay)
    }

    @Test func folderMappingsPreserveRelativePathsAndKnownBytes() throws {
        let plan = try CrossBucketOperation.plan(
            sourceAccountID: UUID(),
            destinationAccountID: UUID(),
            sourceRegion: "a",
            destinationRegion: "b",
            destinationPrefix: "archive/",
            objectKeys: ["cover.png"],
            folders: ["Design/": [
                OSSObject(key: "Design/icons/app.png", size: 10, etag: "", lastModified: nil, storageClass: "Standard"),
                OSSObject(key: "Design/readme.txt", size: 5, etag: "", lastModified: nil, storageClass: "Standard")
            ]]
        )

        #expect(plan.mappings.map(\.destinationKey) == ["archive/cover.png", "archive/Design/icons/app.png", "archive/Design/readme.txt"])
        #expect(plan.knownBytes == 15)
        #expect(plan.method == .relay)
    }

    @Test func placeholderFoldersProduceMappingsWithTrailingSlash() throws {
        let plan = try CrossBucketOperation.plan(
            sourceAccountID: UUID(),
            destinationAccountID: UUID(),
            sourceRegion: "a",
            destinationRegion: "b",
            destinationPrefix: "archive/",
            objectKeys: [],
            folders: ["Empty/": [
                OSSObject(key: "Empty/", size: 0, etag: "", lastModified: nil, storageClass: "Standard")
            ]]
        )

        #expect(plan.mappings.map(\.sourceKey) == ["Empty/"])
        #expect(plan.mappings.map(\.destinationKey) == ["archive/Empty/"])
        #expect(CrossBucketOperation.emptyResultMessage(hadMappings: false) == "源文件夹为空，没有可复制的对象")
        #expect(CrossBucketOperation.emptyResultMessage(hadMappings: true) == "所有同名项目都已跳过")
    }

    @Test func nestedFolderPlaceholdersKeepTrailingSlash() throws {
        let plan = try CrossBucketOperation.plan(
            sourceAccountID: UUID(),
            destinationAccountID: UUID(),
            sourceRegion: "a",
            destinationRegion: "b",
            destinationPrefix: "archive/",
            objectKeys: [],
            folders: ["Design/": [
                OSSObject(key: "Design/", size: 0, etag: "", lastModified: nil, storageClass: "Standard"),
                OSSObject(key: "Design/icons/", size: 0, etag: "", lastModified: nil, storageClass: "Standard"),
                OSSObject(key: "Design/icons/app.png", size: 10, etag: "", lastModified: nil, storageClass: "Standard")
            ]]
        )

        #expect(plan.mappings.map(\.destinationKey) == [
            "archive/Design/",
            "archive/Design/icons/",
            "archive/Design/icons/app.png"
        ])
    }

    @Test func moveRollbackKeepsDestinationsWhoseSourcesWereAlreadyDeleted() {
        let copied = [
            CrossBucketMapping(sourceKey: "a.txt", destinationKey: "dest/a.txt", expectedSize: 1),
            CrossBucketMapping(sourceKey: "b.txt", destinationKey: "dest/b.txt", expectedSize: 1)
        ]

        #expect(
            CrossBucketOperation.rollbackDestinations(copied: copied, removedSources: []).map(\.destinationKey)
                == ["dest/b.txt", "dest/a.txt"]
        )
        #expect(
            CrossBucketOperation.rollbackDestinations(copied: copied, removedSources: ["a.txt"]).map(\.destinationKey)
                == ["dest/b.txt"]
        )
    }
}
