import AppKit
import SwiftUI

@main
struct OssunoApp: App {
    @NSApplicationDelegateAdaptor(OssunoAppDelegate.self) private var appDelegate

    init() {
        AppIdentity.prepareForLaunch()
    }

    var body: some Scene {
        WindowGroup("Ossuno", id: "main") {
            WorkspaceRoot()
        }
        .defaultSize(width: 1240, height: 800)
        .windowToolbarStyle(.unified)
        .commands {
            OssunoCommands()
        }

        Settings {
            SettingsView()
                .environment(AppModel.settingsSession)
                .frame(width: 620, height: 600)
        }

        Window("Ossuno 帮助", id: "help") {
            HelpView()
        }
        .defaultSize(width: 860, height: 640)

        Window("传输", id: "transfers") {
            TransferWindow()
                .environment(AppModel.settingsSession)
        }
        .defaultSize(width: 780, height: 520)
        .windowToolbarStyle(.unified)

        MenuBarExtra(isInserted: menuBarBinding) {
            TransferMenu()
                .environment(AppServices.shared.focused ?? AppModel.settingsSession)
        } label: {
            Label("Ossuno", systemImage: "photo.on.rectangle.angled")
        }
    }
}

private struct WorkspaceRoot: View {
    @State private var model: AppModel

    init() {
        #if DEBUG
        if let mode = ScreenshotDemo.currentMode {
            _model = State(initialValue: ScreenshotDemo.makeModel(for: mode))
            return
        }
        #endif
        _model = State(initialValue: AppModel())
    }

    var body: some View {
        RootView()
            .environment(model)
            .modifier(ScreenshotActiveState())
            .background(WindowFocusProbe { model.becomeFocused() })
            .onAppear {
                #if DEBUG
                if ScreenshotDemo.currentMode != nil {
                    ScreenshotDemo.prepareWindow()
                    return
                }
                #endif
                guard !AppRuntime.isRunningTests else { return }
                model.bootstrap()
                model.becomeFocused()
            }
    }
}

private struct ScreenshotActiveState: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if DEBUG
        if ScreenshotDemo.currentMode != nil {
            content.environment(\.controlActiveState, .active)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

final class OssunoAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        #if DEBUG
        if ScreenshotDemo.currentMode != nil {
            ScreenshotDemo.applyAppearance()
            return
        }
        #endif
        MainActor.assumeIsolated {
            TransferNotifier.shared.prepare()
            Task { @MainActor in
                // Ensure the local preference stays in sync with the system
                // authorization state — otherwise the switch in Settings
                // could claim "on" while notifications are globally denied.
                var notifyPref = AppServices.shared.settings.notifyWhenTransfersFinish
                await TransferNotifier.shared.reconcilePreferenceWithSystem(pref: &notifyPref)
                AppServices.shared.settings.notifyWhenTransfersFinish = notifyPref

                if AppServices.shared.settings.notifyWhenTransfersFinish {
                    TransferNotifier.shared.requestAuthorizationIfNeeded()
                }
            }
            AppServices.shared.settings.appearance.apply()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            AppServices.shared.routeIncoming(urls)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let transferring = AppServices.shared.transfers.activeCount > 0
            let organizing = AppServices.shared.sessions.contains(where: \.isOrganizingCloud)
            guard AppTermination.shouldConfirm(transferring: transferring, organizing: organizing) else {
                return .terminateNow
            }
            let prompt = AppTermination.prompt(transferring: transferring, organizing: organizing)
            let alert = NSAlert()
            alert.messageText = prompt.title
            alert.informativeText = prompt.message
            alert.addButton(withTitle: "退出")
            alert.addButton(withTitle: organizing ? "继续整理" : "继续传输")
            if alert.runModal() == .alertFirstButtonReturn {
                AppServices.shared.transfers.pauseAll()
                return .terminateNow
            }
            return .terminateCancel
        }
    }
}

enum AppTermination {
    static func shouldConfirm(transferring: Bool, organizing: Bool) -> Bool {
        transferring || organizing
    }

    static func prompt(transferring: Bool, organizing: Bool) -> (title: String, message: String) {
        if organizing && transferring {
            return (
                "还有整理和传输未完成",
                "现在退出会中断未完成的重命名、移动或复制，已复制的对象可能不会回滚；未完成的上传或下载也会中断。"
            )
        }
        if organizing {
            return (
                "还有云端整理未完成",
                "现在退出会中断未完成的重命名、移动或复制，已复制的对象可能不会回滚。"
            )
        }
        return (
            "还有文件在传输",
            "现在退出会中断未完成的上传或下载。"
        )
    }
}

private enum AppRuntime {
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

struct OssunoCommands: Commands {
    @FocusedValue(\.ossunoActions) private var actions
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Keep AppKit's standard Undo/Redo items intact so focused text
        // controls retain their native editing behavior. Ossuno's cloud undo
        // remains available as a separate semantic command (and ⌘Z is
        // routed to it by RootView while the browser, rather than a field, is
        // focused).
        CommandGroup(after: .undoRedo) {
            Divider()
            Button(actions?.undoTitle ?? "撤销 Ossuno 操作") {
                actions?.undo()
            }
            .disabled(actions?.canUndo != true)
        }
        CommandGroup(replacing: .newItem) {
            Button("上传") { actions?.upload() }
                .keyboardShortcut("o", modifiers: [.command])
            Button("从剪贴板上传") { actions?.pasteLocalFiles() }
            Button("添加账号…") { actions?.addAccount() }
            Divider()
            Button("新建文件夹") { actions?.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        // Never replace the system pasteboard group. Replacing it disables
        // ⌘X/⌘C/⌘V/⌘A in SwiftUI TextField and SecureField. The
        // browser-specific variants live beside the native commands, while
        // RootView handles the familiar shortcuts only when text is not being
        // edited.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("剪切云端项目") {
                (actions?.cut ?? { AppServices.shared.focused?.cutCloudSelection() })()
            }
            .disabled(!(actions?.canCopy ?? AppServices.shared.focused?.canCopyCloudItems ?? false))
            Button("复制云端项目") {
                (actions?.copy ?? { AppServices.shared.focused?.copyCloudSelection() })()
            }
            .disabled(!(actions?.canCopy ?? AppServices.shared.focused?.canCopyCloudItems ?? false))
            Button("粘贴云端项目") {
                if let actions {
                    actions.paste()
                } else {
                    AppServices.shared.focused?.paste()
                }
            }
            .disabled(!(actions?.canPaste ?? AppServices.shared.focused?.canPaste ?? false))
            Divider()
            Button("复制链接") { actions?.copyLink() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("复制 Markdown") { actions?.copyMarkdown() }
            Button("复制 HTML") { actions?.copyHTML() }
            Divider()
            Button("全选云端项目") { actions?.selectAll() }
            Button("取消选择云端项目") { actions?.deselectAll() }
        }
        CommandGroup(after: .appInfo) {
            Button("检查更新…") {
                AppServices.shared.updates.checkForUpdates()
            }
        }
        CommandMenu("传输") {
            Button("打开传输中心") {
                openWindow(id: "transfers")
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            Divider()
            Button("全部暂停") {
                AppServices.shared.transfers.pauseAll()
            }
            .disabled(!AppServices.shared.transfers.jobs.contains(where: { $0.status == .running }))
            Button("全部继续") {
                AppServices.shared.transfers.resumeAll()
            }
            .disabled(!AppServices.shared.transfers.jobs.contains(where: { $0.status == .paused }))
        }
        CommandGroup(replacing: .help) {
            Button("Ossuno 帮助") {
                openWindow(id: "help")
            }
            .keyboardShortcut("?", modifiers: [.command])
            Button("复制诊断信息") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(DiagnosticsReport.make(), forType: .string)
            }
            Divider()
            Button("Ossuno 官网") {
                NSWorkspace.shared.open(AppLinks.website)
            }
            Button("在 GitHub 打开仓库") {
                NSWorkspace.shared.open(AppLinks.github)
            }
            Button("问题与反馈") {
                NSWorkspace.shared.open(AppLinks.issues)
            }
        }
        CommandMenu("浏览") {
            Button("打开选中项") { actions?.openSelection() }
                .keyboardShortcut(.downArrow, modifiers: [.command])
            Button("重命名") { actions?.rename() }
            Divider()
            Button("后退") { actions?.goBack() }
                .keyboardShortcut("[", modifiers: [.command])
            Button("前进") { actions?.goForward() }
                .keyboardShortcut("]", modifiers: [.command])
            Divider()
            Button("刷新") { actions?.refresh() }
                .keyboardShortcut("r", modifiers: [.command])
            Button("快速查看") { actions?.quickLook() }
            Button("显示信息") { actions?.showInformation() }
                .keyboardShortcut("i", modifiers: [.command])
                .disabled(actions?.canShowInformation != true)
            Button("对象属性") { actions?.showObjectProperties() }
                .disabled(actions?.canActOnObject != true)
            Divider()
            Button("网格") { actions?.grid() }
                .keyboardShortcut("1", modifiers: [.command])
            Button("列表") { actions?.list() }
                .keyboardShortcut("2", modifiers: [.command])
        }
    }
}

struct OssunoActions {
    var undoTitle: String
    var canUndo: Bool
    var undo: () -> Void
    var upload: () -> Void
    var copy: () -> Void
    var canCopy: Bool
    var cut: () -> Void
    var paste: () -> Void
    var canPaste: Bool
    var pasteLocalFiles: () -> Void
    var addAccount: () -> Void
    var newFolder: () -> Void
    var copyLink: () -> Void
    var copyMarkdown: () -> Void
    var copyHTML: () -> Void
    var rename: () -> Void
    var openSelection: () -> Void
    var refresh: () -> Void
    var quickLook: () -> Void
    var canShowInformation: Bool
    var showInformation: () -> Void
    var canActOnObject: Bool
    var showObjectProperties: () -> Void
    var grid: () -> Void
    var list: () -> Void
    var goBack: () -> Void
    var goForward: () -> Void
    var selectAll: () -> Void
    var deselectAll: () -> Void
}

private struct OssunoActionsKey: FocusedValueKey {
    typealias Value = OssunoActions
}

extension FocusedValues {
    var ossunoActions: OssunoActions? {
        get { self[OssunoActionsKey.self] }
        set { self[OssunoActionsKey.self] = newValue }
    }
}

private var menuBarBinding: Binding<Bool> {
    Binding(
        get: { MainActor.assumeIsolated { AppServices.shared.showMenuBarExtra } },
        set: { value in
            MainActor.assumeIsolated { AppServices.shared.showMenuBarExtra = value }
        }
    )
}

@MainActor
enum WindowActions {
    static let workspaceID = NSUserInterfaceItemIdentifier("ossuno.workspace")

    static func prepare(_ window: NSWindow) {
        window.identifier = workspaceID
        window.tabbingMode = .disallowed
    }
}

private struct WindowFocusProbe: NSViewRepresentable {
    var onFocus: () -> Void

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.onFocus = onFocus
        return view
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.onFocus = onFocus
    }

    final class Probe: NSView {
        var onFocus: (() -> Void)?

        override func viewDidMoveToWindow() {
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            WindowActions.prepare(window)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(becameKey),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
            if window.isKeyWindow {
                onFocus?()
            }
        }

        @objc private func becameKey() {
            onFocus?()
        }
    }
}
