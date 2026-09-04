#if DEBUG
import AppKit
import Darwin
import Foundation
import ScreenCaptureKit
import Security

@MainActor
enum ScreenshotDemo {
    enum Mode: Equatable {
        case browser
        case account
    }

    static var currentMode: Mode? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ossuno-screenshot-browser") { return .browser }
        if arguments.contains("--ossuno-screenshot-account") { return .account }
        return nil
    }

    static var accountShowsAdvanced: Bool {
        accountShowsAdvanced(arguments: ProcessInfo.processInfo.arguments)
    }

    static func accountShowsAdvanced(arguments: [String]) -> Bool {
        arguments.contains("--ossuno-screenshot-account")
            && arguments.contains("--ossuno-screenshot-account-advanced")
    }

    static func outputURL(arguments: [String] = ProcessInfo.processInfo.arguments) -> URL? {
        let prefix = "--ossuno-screenshot-output="
        guard let argument = arguments.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let path = String(argument.dropFirst(prefix.count))
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    static var forcedAppearance: NSAppearance? {
        guard currentMode != nil else { return nil }
        return NSAppearance(
            named: ProcessInfo.processInfo.arguments.contains("--ossuno-screenshot-dark") ? .darkAqua : .aqua
        )
    }

    static var accountFailure: AccountFormFailure? {
        accountFailure(arguments: ProcessInfo.processInfo.arguments)
    }

    static func accountFailure(arguments: [String]) -> AccountFormFailure? {
        guard arguments.contains("--ossuno-screenshot-account"),
              arguments.contains("--ossuno-screenshot-account-error")
        else { return nil }
        return AccountFormFailure(
            operation: .savingAccount,
            error: KeychainStoreError(status: errSecInteractionNotAllowed)
        )
    }

    static func applyAppearance() {
        guard let forcedAppearance else { return }
        NSApp.appearance = forcedAppearance
    }

    static let accountDraft = AccountDraft(
        id: UUID(uuidString: "6A7ED12A-73B6-4C18-A6DE-3BD395520001")!,
        name: "Ossuno 演示工作室",
        accessKeyId: "LTAI5tDEMO0000000000",
        secret: "demo-secret-never-used",
        token: "",
        regionID: "cn-hangzhou",
        endpointOverride: "",
        cdnDomain: "media.example.com",
        defaultACL: .default,
        prefixTemplate: "assets/{yyyy}/{MM}/{dd}/",
        useTransferAccelerate: true,
        createdAt: Date(timeIntervalSince1970: 1_765_756_800)
    )

    static func makeModel(for mode: Mode) -> AppModel {
        let accountID = UUID(uuidString: "6A7ED12A-73B6-4C18-A6DE-3BD395520001")!
        let account = OSSAccount(
            id: accountID,
            name: "Ossuno 演示工作室",
            accessKeyId: "LTAI5tDEMO0000000000",
            regionID: "cn-hangzhou",
            endpointOverride: "",
            cdnDomain: "media.example.com",
            defaultACL: .default,
            prefixTemplate: "assets/{yyyy}/{MM}/{dd}/",
            useTransferAccelerate: true,
            createdAt: Date(timeIntervalSince1970: 1_765_756_800)
        )
        let defaults = UserDefaults(suiteName: "Ossuno.ScreenshotDemo.\(UUID().uuidString)")!
        let services = AppServices(
            accounts: [account],
            settings: AppSettings(defaults: defaults),
            favorites: FavoriteStore(defaults: defaults)
        )
        let model = AppModel(services: services)
        model.browser = BrowserModel(defaults: defaults)
        model.selectedAccountID = accountID
        model.buckets = buckets
        model.selectedBucketName = "ossuno-studio-assets"
        model.browser.prefix = "campaigns/2026-autumn/"
        model.browser.viewMode = .list
        model.browser.imagesOnly = false
        model.searchScope = .folder
        model.searchFilter = .all
        model.browser.folders = folders
        model.browser.objects = objects
        model.browser.backStack = ["", "campaigns/"]
        model.browser.replaceSelection(["campaigns/2026-autumn/发布素材/"])
        model.favorites.add(FavoriteLocation(
            accountID: accountID,
            bucketName: "ossuno-studio-assets",
            prefix: "brand/",
            name: "品牌素材"
        ))
        model.favorites.add(FavoriteLocation(
            accountID: accountID,
            bucketName: "ossuno-studio-assets",
            prefix: "campaigns/2026-autumn/发布素材/",
            name: "待发布"
        ))
        if mode == .browser {
            model.transfers.jobs = [
                TransferJob(
                    id: UUID(),
                    kind: .download,
                    status: .running,
                    title: "交付清单.pdf",
                    objectKey: "campaigns/2026-autumn/交付清单.pdf",
                    localURL: nil,
                    transferred: 589_660,
                    total: 842_371,
                    errorMessage: nil,
                    publicURL: nil,
                    finishedAt: nil
                ),
                TransferJob(
                    id: UUID(),
                    kind: .upload,
                    status: .paused,
                    title: "片头动画.mov",
                    objectKey: "campaigns/2026-autumn/片头动画.mov",
                    localURL: nil,
                    transferred: 94_371_840,
                    total: 186_422_901,
                    errorMessage: nil,
                    publicURL: nil,
                    finishedAt: nil
                )
            ]
        }
        model.showAccountSheet = mode == .account
        return model
    }

    static func prepareWindow() {
        applyAppearance()
        schedulePreparedCapture(attempt: 0)
    }

    private static func schedulePreparedCapture(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.25 : 0.2)) {
            applyAppearance()
            let window = NSApp.windows.first(where: { $0.identifier == WindowActions.workspaceID })
                ?? NSApp.windows.first(where: \.canBecomeKey)
                ?? NSApp.windows.first
            guard let window else {
                if attempt < 20 {
                    schedulePreparedCapture(attempt: attempt + 1)
                } else {
                    fputs("screenshot: no window\n", stderr)
                    exitIfCapturing()
                }
                return
            }
            window.appearance = NSApp.appearance
            let size = NSSize(width: 1240, height: 800)
            let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(origin: .zero, size: size)
            window.setFrame(
                NSRect(
                    origin: CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2),
                    size: size
                ),
                display: true
            )
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            guard outputURL() != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + (currentMode == .account ? 1.8 : 1.0)) {
                Task { @MainActor in
                    await writeRequestedScreenshot()
                    exitIfCapturing()
                }
            }
        }
    }

    private static func exitIfCapturing() {
        guard outputURL() != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Darwin.exit(0)
        }
    }

    static func writeRequestedScreenshot() async {
        guard let url = outputURL() else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = await captureWithScreenCaptureKit() ?? capturePNG()
            guard let data else {
                fputs("screenshot: capture failed\n", stderr)
                return
            }
            try data.write(to: url)
            fputs("screenshot: wrote \(url.path)\n", stderr)
        } catch {
            fputs("screenshot: \(error.localizedDescription)\n", stderr)
        }
    }

    private static func captureWithScreenCaptureKit() async -> Data? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let bundleID = Bundle.main.bundleIdentifier
            let processID = ProcessInfo.processInfo.processIdentifier
            let window = content.windows
                .filter { window in
                    guard let application = window.owningApplication else { return false }
                    return application.bundleIdentifier == bundleID
                        && isCurrentProcess(candidatePID: application.processID, currentPID: processID)
                }
                .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            guard let window else {
                fputs("screenshot: ScreenCaptureKit found no window\n", stderr)
                return nil
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            configuration.showsCursor = false
            configuration.width = Int(window.frame.width * 2)
            configuration.height = Int(window.frame.height * 2)
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        } catch {
            fputs("screenshot: ScreenCaptureKit \(error.localizedDescription)\n", stderr)
            return nil
        }
    }

    static func isCurrentProcess(candidatePID: Int32?, currentPID: Int32) -> Bool {
        candidatePID == currentPID
    }

    static func capturePNG() -> Data? {
        let windows = NSApp.windows.filter { $0.isVisible && $0.alphaValue > 0 }
        guard let workspace = windows.first(where: { $0.identifier == WindowActions.workspaceID })
                ?? windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              let workspaceImage = rasterize(workspace)
        else { return nil }

        let sheet = workspace.attachedSheet ?? windows.first(where: \.isSheet)
        guard let sheet, let sheetImage = rasterize(sheet) else {
            return png(from: workspaceImage)
        }

        let canvas = NSImage(size: workspaceImage.size)
        canvas.lockFocus()
        workspaceImage.draw(in: NSRect(origin: .zero, size: workspaceImage.size))
        NSColor.black.withAlphaComponent(0.32).setFill()
        NSRect(origin: .zero, size: workspaceImage.size).fill(using: .sourceOver)
        let sheetRect = NSRect(
            x: (workspaceImage.size.width - sheetImage.size.width) / 2,
            y: (workspaceImage.size.height - sheetImage.size.height) / 2,
            width: sheetImage.size.width,
            height: sheetImage.size.height
        )
        sheetImage.draw(in: sheetRect)
        canvas.unlockFocus()
        return png(from: canvas)
    }

    private static func rasterize(_ window: NSWindow) -> NSImage? {
        guard let themeFrame = window.contentView?.superview else { return nil }
        flattenVibrancy(in: themeFrame)
        let bounds = themeFrame.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = themeFrame.bitmapImageRepForCachingDisplay(in: bounds)
        else { return nil }
        themeFrame.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func flattenVibrancy(in view: NSView) {
        if let effect = view as? NSVisualEffectView {
            effect.appearance = view.window?.appearance ?? NSApp.appearance
            effect.blendingMode = .withinWindow
            effect.state = .inactive
        }
        for subview in view.subviews {
            flattenVibrancy(in: subview)
        }
    }

    private static func png(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static let buckets = [
        OSSBucket(
            name: "ossuno-studio-assets",
            regionID: "cn-hangzhou",
            location: "oss-cn-hangzhou",
            extranetEndpoint: "oss-cn-hangzhou.aliyuncs.com",
            createdAt: Date(timeIntervalSince1970: 1_704_067_200)
        ),
        OSSBucket(
            name: "ossuno-product-archive",
            regionID: "cn-shanghai",
            location: "oss-cn-shanghai",
            extranetEndpoint: "oss-cn-shanghai.aliyuncs.com",
            createdAt: Date(timeIntervalSince1970: 1_672_531_200)
        ),
        OSSBucket(
            name: "ossuno-team-uploads",
            regionID: "cn-hangzhou",
            location: "oss-cn-hangzhou",
            extranetEndpoint: "oss-cn-hangzhou.aliyuncs.com",
            createdAt: Date(timeIntervalSince1970: 1_735_689_600)
        )
    ]

    private static let folders = [
        OSSFolder(prefix: "campaigns/2026-autumn/品牌规范/"),
        OSSFolder(prefix: "campaigns/2026-autumn/产品图/"),
        OSSFolder(prefix: "campaigns/2026-autumn/发布素材/"),
        OSSFolder(prefix: "campaigns/2026-autumn/归档/")
    ]

    private static let objects = [
        object("交付清单.pdf", size: 842_371, modified: 1_786_579_200),
        object("发布说明.md", size: 18_426, modified: 1_786_406_400),
        object("视觉规范-v3.sketch", size: 28_934_228, modified: 1_785_974_400),
        object("官网文案.txt", size: 9_842, modified: 1_785_628_800),
        object("素材索引.json", size: 124_908, modified: 1_785_369_600),
        object("片头动画.mov", size: 186_422_901, modified: 1_784_851_200),
        object("封面视觉.psd", size: 74_208_552, modified: 1_783_209_600)
    ]

    private static func object(_ name: String, size: Int64, modified: TimeInterval) -> OSSObject {
        OSSObject(
            key: "campaigns/2026-autumn/\(name)",
            size: size,
            etag: "DEMO-\(size)",
            lastModified: Date(timeIntervalSince1970: modified),
            storageClass: "Standard"
        )
    }
}
#endif
