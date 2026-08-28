import Foundation
import Testing
@testable import Ossuno

struct PathTemplateTests {
    @Test func joinSkipsEmptyParts() {
        #expect(PathTemplate.join("", key: "a.jpg") == "a.jpg")
        #expect(PathTemplate.join("assets/", key: "a.jpg") == "assets/a.jpg")
        #expect(PathTemplate.join("/assets/", key: "/a.jpg") == "assets/a.jpg")
    }

    @Test func lastComponentHandlesFolders() {
        #expect(PathTemplate.lastComponent("assets/2026/") == "2026")
        #expect(PathTemplate.lastComponent("hero.png") == "hero.png")
    }

    @Test func parentPrefixWalksUp() {
        #expect(PathTemplate.parentPrefix("assets/2026/08/") == "assets/2026/")
        #expect(PathTemplate.parentPrefix("assets/") == "")
        #expect(PathTemplate.parentPrefix("") == "")
    }

    @Test func expandDateTokens() {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 14
        let date = Calendar(identifier: .gregorian).date(from: components)!
        let result = PathTemplate.expand("assets/{yyyy}/{MM}/{dd}/{filename}", now: date, filename: "hero.png")
        #expect(result == "assets/2026/08/14/hero.png")
    }

    @Test func nestedRelativeKeepsFolderTree() {
        #expect(
            PathTemplate.nestedRelative(
                rootName: "avatars",
                rootPath: "/tmp/drop/avatars",
                filePath: "/tmp/drop/avatars/2024/b.png"
            ) == "avatars/2024/b.png"
        )
        #expect(
            PathTemplate.nestedRelative(
                rootName: "avatars",
                rootPath: "/tmp/drop/avatars/",
                filePath: "/tmp/drop/avatars/hero.png"
            ) == "avatars/hero.png"
        )
    }

    @Test func replacingLastComponentKeepsParents() {
        #expect(PathTemplate.replacingLastComponent("avatars/pic.heic", with: "pic.jpg") == "avatars/pic.jpg")
        #expect(PathTemplate.replacingLastComponent("pic.heic", with: "pic.jpg") == "pic.jpg")
    }

    @Test func destinationKeyKeepsNestedFolderDrop() {
        #expect(
            PathTemplate.destinationKey(
                prefix: "assets/",
                filename: "avatars/2024/b.png",
                applyTemplate: false,
                template: "ignored/"
            ) == "assets/avatars/2024/b.png"
        )
    }

    @Test func destinationKeyKeepsFilenameWithoutTemplate() {
        #expect(PathTemplate.destinationKey(prefix: "avatars/", filename: "hero.png", applyTemplate: false, template: "assets/{yyyy}/") == "avatars/hero.png")
        #expect(PathTemplate.destinationKey(prefix: "", filename: "hero.png", applyTemplate: false, template: "assets/{yyyy}/") == "hero.png")
    }

    @Test func destinationKeyUsesTemplateOnlyAtRoot() {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 14
        let date = Calendar(identifier: .gregorian).date(from: components)!
        let expanded = PathTemplate.expand("assets/{yyyy}/{MM}/{dd}/", now: date, filename: "hero.png")
        #expect(expanded == "assets/2026/08/14")
        #expect(PathTemplate.destinationKey(prefix: "avatars/", filename: "hero.png", applyTemplate: true, template: "assets/{yyyy}/{MM}/{dd}/") == "avatars/hero.png")
    }

    @Test func destinationKeyDoesNotRepeatFilenameWhenTemplateNamesTheObject() {
        #expect(
            PathTemplate.destinationKey(
                prefix: "",
                filename: "hero.png",
                applyTemplate: true,
                template: "assets/{filename}"
            ) == "assets/hero.png"
        )
        #expect(
            PathTemplate.destinationKey(
                prefix: "",
                filename: "cat.png",
                applyTemplate: true,
                template: "photos/{name}.{ext}"
            ) == "photos/cat.png"
        )
    }

    @Test func destinationKeyStillAppendsFilenameToADatePrefix() {
        let extra = PathTemplate.expand("assets/{yyyy}/{MM}/{dd}/", filename: "hero.png")
        #expect(
            PathTemplate.destinationKey(
                prefix: "",
                filename: "hero.png",
                applyTemplate: true,
                template: "assets/{yyyy}/{MM}/{dd}/"
            ) == PathTemplate.join(extra, key: "hero.png")
        )
    }

    @Test func relativeStripsPrefix() {
        #expect(PathTemplate.relative("assets/2026/a.png", under: "assets/") == "2026/a.png")
        #expect(PathTemplate.relative("assets/a.png", under: "assets/") == "a.png")
        #expect(PathTemplate.relative("a.png", under: "") == "a.png")
        #expect(PathTemplate.relative("other/a.png", under: "assets/") == "a.png")
    }

    @Test func crumbsIncludeBucket() {
        let crumbs = PathTemplate.crumbs(bucket: "studio", prefix: "assets/2026/")
        #expect(crumbs.map(\.title) == ["studio", "assets", "2026"])
        #expect(crumbs.last?.prefix == "assets/2026/")
    }

}

struct SignerTests {
    @Test func uriEncodeLeavesUnreserved() {
        #expect(OSSSigner.uriEncode("abc-_.~", encodeSlash: true) == "abc-_.~")
    }

    @Test func uriEncodeEncodesSlashWhenAsked() {
        #expect(OSSSigner.uriEncode("a/b", encodeSlash: true) == "a%2Fb")
        #expect(OSSSigner.uriEncode("a/b", encodeSlash: false) == "a/b")
    }

    @Test func resourcePathMatchesOfficialRules() {
        #expect(OSSSigner.resourcePath(bucket: nil, key: nil) == "/")
        #expect(OSSSigner.resourcePath(bucket: "demo", key: nil) == "/demo/")
        #expect(OSSSigner.resourcePath(bucket: "demo", key: "a/b.jpg") == "/demo/a/b.jpg")
    }

    @Test func imageKindRecognizesCommonFormats() {
        #expect(ImageKind.isImage(key: "a.PNG"))
        #expect(ImageKind.isImage(key: "b.heic"))
        #expect(ImageKind.isImage(key: "loop.GIF"))
        #expect(ImageKind.isImage(key: "cover.webp"))
        #expect(ImageKind.isImage(key: "mark.svg"))
        #expect(ImageKind.contentType(for: "c.webp") == "image/webp")
        #expect(ImageKind.contentType(for: "loop.gif") == "image/gif")
        #expect(ImageKind.contentType(for: "mark.svg") == "image/svg+xml")
        #expect(ImageKind.imgProcessable(key: "loop.gif"))
        #expect(ImageKind.imgProcessable(key: "cover.webp"))
        #expect(!ImageKind.imgProcessable(key: "mark.svg"))
        #expect(!ImageKind.isImage(key: "notes.txt"))
        #expect(ImageKind.isText(key: "config.JSON"))
        #expect(ImageKind.isText(key: "readme.txt"))
        #expect(ImageKind.isSupported(key: "data.json"))
        #expect(ImageKind.contentType(for: "notes.txt") == "text/plain")
        #expect(ImageKind.contentType(for: "data.json") == "application/json")
        #expect(ImageKind.displayKind(for: "data.json") == "JSON")
        #expect(ImageKind.isText(key: "component.ts"))
        #expect(!ImageKind.isVideo(key: "component.ts"))
        #expect(ImageKind.contentType(for: "component.ts") == "text/plain")
        #expect(ImageKind.isVideo(key: "camera.m2ts"))
        #expect(ImageKind.contentType(for: "camera.m2ts") == "video/mp2t")
    }

    @Test func byteFormatterDoesNotSpellOutZero() {
        #expect(Formatters.bytes(0) == "0 KB")
        #expect(!Formatters.bytes(1_300_000).localizedStandardContains("Zero"))
    }

    @Test func canonicalRequestHasRequiredBlankAdditionalHeaders() {
        let request = OSSSigner.canonicalRequest(
            method: "PUT",
            resourcePath: "/examplebucket/exampleobject",
            query: [],
            headers: [
                "content-type": "text/plain",
                "x-oss-content-sha256": "UNSIGNED-PAYLOAD",
                "x-oss-date": "20250411T064124Z"
            ]
        )
        let expected = "PUT\n/examplebucket/exampleobject\n\ncontent-type:text/plain\nx-oss-content-sha256:UNSIGNED-PAYLOAD\nx-oss-date:20250411T064124Z\n\n\nUNSIGNED-PAYLOAD"
        #expect(request == expected)
    }
}

struct ImageProcessTests {
    @Test func gridUsesCenterCropWithoutFormat() {
        #expect(OSSImageProcess.grid.query.contains("resize,m_fill,w_128,h_128"))
        #expect(OSSImageProcess.grid.query.contains("limit_1"))
        #expect(!OSSImageProcess.grid.query.contains("format,jpg"))
    }

    @Test func webpPreviewFallsBackToJPEGProcess() {
        let queries = OSSImageProcess.grid.queries(for: "cover.webp")
        #expect(queries.contains(where: { $0.contains("format,jpg") }))
        #expect(ImageKind.needsJPEGPreview(key: "cover.webp"))
        #expect(!ImageKind.needsJPEGPreview(key: "hero.png"))
    }

    @Test func inspectorOnlyResizes() {
        #expect(OSSImageProcess.inspector.query.contains("resize,m_lfit"))
        #expect(!OSSImageProcess.inspector.query.contains("crop"))
        #expect(!OSSImageProcess.inspector.query.contains("format,jpg"))
    }
}

struct AppVersionTests {
    @Test func stripsTagPrefix() {
        #expect(AppVersion.normalized("v0.0.2") == "0.0.2")
        #expect(AppVersion.normalized("0.0.2-beta") == "0.0.2")
    }

    @Test func comparesSemanticVersions() {
        #expect(AppVersion.isNewer("0.0.2", than: "0.0.1"))
        #expect(AppVersion.isNewer("0.1.0", than: "0.0.9"))
        #expect(!AppVersion.isNewer("0.0.1", than: "0.0.1"))
        #expect(!AppVersion.isNewer("0.0.1", than: "0.0.2"))
        #expect(AppVersion.isNewer("v1.0.0", than: "0.9.9"))
    }
}

struct EndpointTests {
    @Test func stripsAccidentalBucketPrefix() {
        #expect(OSSEndpoint.normalize("https://mybucket.oss-cn-hangzhou.aliyuncs.com") == "oss-cn-hangzhou.aliyuncs.com")
        #expect(OSSEndpoint.normalize("oss-cn-hangzhou.aliyuncs.com") == "oss-cn-hangzhou.aliyuncs.com")
        #expect(OSSEndpoint.normalize("cdn.example.com") == "cdn.example.com")
        #expect(OSSEndpoint.normalize("https://tenant.oss-proxy.example/path") == "tenant.oss-proxy.example")
    }

    @Test func virtualHostOnlyForAliyun() {
        #expect(OSSEndpoint.isAliyunVirtualHost("oss-cn-shanghai.aliyuncs.com"))
        #expect(!OSSEndpoint.isAliyunVirtualHost("aliyuncs.com.evil.example"))
        #expect(OSSEndpoint.objectHost(endpoint: "oss-cn-shanghai.aliyuncs.com", bucketName: "studio") == "studio.oss-cn-shanghai.aliyuncs.com")
        #expect(OSSEndpoint.objectHost(endpoint: "aliyuncs.com.evil.example", bucketName: "studio") == "aliyuncs.com.evil.example")
        #expect(OSSEndpoint.objectHost(endpoint: "img.example.com", bucketName: "studio") == "img.example.com")
    }
}
