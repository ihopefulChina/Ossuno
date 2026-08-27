import AppKit
import SwiftUI

enum BrowserMenuHit: Equatable {
    case empty
    case folder(String)
    case file(String)

    static func parseIdentifier(_ raw: String?) -> BrowserMenuHit? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("ossuno.folder:") {
            let value = String(raw.dropFirst("ossuno.folder:".count))
            return value.isEmpty ? nil : .folder(value)
        }
        if raw.hasPrefix("ossuno.file:") {
            let value = String(raw.dropFirst("ossuno.file:".count))
            return value.isEmpty ? nil : .file(value)
        }
        return nil
    }

    static func fromTableID(_ id: String) -> BrowserMenuHit {
        id.hasSuffix("/") ? .folder(id) : .file(id)
    }

    var itemID: String? {
        switch self {
        case .folder(let prefix): prefix
        case .file(let key): key
        case .empty: nil
        }
    }
}

enum BrowserMenuHitResolver {
    static let minCell = CGFloat(16)
    static let maxCellWidth = CGFloat(280)
    static let maxCellHeight = CGFloat(400)

    static func isCellSized(_ size: CGSize) -> Bool {
        size.width >= minCell
            && size.height >= minCell
            && size.width <= maxCellWidth
            && size.height <= maxCellHeight
    }

    static func isHuge(_ size: CGSize) -> Bool {
        size.width > maxCellWidth || size.height > maxCellHeight
    }

    @MainActor
    static func resolve(
        event: NSEvent,
        tableItemIDs: [String],
        registry: BrowserItemHitRegistry = .shared
    ) -> BrowserMenuHit {
        let hitView = event.window?.contentView?.hitTest(event.locationInWindow)
        return resolve(
            hitView: hitView,
            windowPoint: event.locationInWindow,
            window: event.window,
            tableItemIDs: tableItemIDs,
            registry: registry
        )
    }

    @MainActor
    static func resolve(
        hitView: NSView?,
        windowPoint: NSPoint,
        window: NSWindow?,
        tableItemIDs: [String],
        registry: BrowserItemHitRegistry
    ) -> BrowserMenuHit {
        if let window, let hit = registry.hit(at: windowPoint, in: window) {
            return hit
        }
        if let hitView, let hit = findItemHit(startingAt: hitView) {
            return hit
        }

        var ancestor = hitView
        while let current = ancestor {
            if let table = current as? NSTableView {
                let row = table.row(at: table.convert(windowPoint, from: nil))
                if row >= 0, row < tableItemIDs.count {
                    return .fromTableID(tableItemIDs[row])
                }
                return .empty
            }
            ancestor = current.superview
        }
        return .empty
    }

    @MainActor
    static func looksLikeItemControl(event: NSEvent) -> Bool {
        looksLikeItemControl(
            startingAt: event.window?.contentView?.hitTest(event.locationInWindow)
        )
    }

    @MainActor
    static func looksLikeItemControl(startingAt view: NSView?) -> Bool {
        var current = view
        var depth = 0
        while let node = current, depth < 12 {
            if node is NSScrollView || node is NSClipView || node is NSTableView {
                return false
            }
            if node is NSControl || node is NSTextView {
                return true
            }
            if BrowserMenuHit.parseIdentifier(node.identifier?.rawValue) != nil {
                return true
            }
            current = node.superview
            depth += 1
        }
        return false
    }

    @MainActor
    static func findItemHit(startingAt start: NSView) -> BrowserMenuHit? {
        var view: NSView? = start
        var depth = 0
        while let current = view, depth < 16 {
            if current is NSScrollView || current is NSClipView {
                return nil
            }
            if let hit = BrowserMenuHit.parseIdentifier(current.identifier?.rawValue) {
                return hit
            }
            if shouldSearchDescendants(current),
               let hit = searchDescendants(current, remaining: 6)
            {
                return hit
            }
            if current is NSTableView {
                return nil
            }
            view = current.superview
            depth += 1
        }
        return nil
    }

    @MainActor
    static func shouldSearchDescendants(_ view: NSView) -> Bool {
        view is NSButton || view is NSTableRowView || isCellSized(view.bounds.size)
    }

    @MainActor
    static func searchDescendants(_ view: NSView, remaining: Int) -> BrowserMenuHit? {
        guard remaining > 0 else { return nil }
        if let hit = BrowserMenuHit.parseIdentifier(view.identifier?.rawValue) {
            return hit
        }
        for child in view.subviews {
            if let hit = searchDescendants(child, remaining: remaining - 1) {
                return hit
            }
        }
        return nil
    }
}

final class BrowserItemHitRegistry: @unchecked Sendable {
    static let shared = BrowserItemHitRegistry()

    private struct Record {
        weak var view: NSView?
        var id: String
    }

    private var records: [ObjectIdentifier: Record] = [:]
    private let lock = NSLock()

    func register(_ view: NSView, id: String) {
        lock.lock()
        records[ObjectIdentifier(view)] = Record(view: view, id: id)
        lock.unlock()
    }

    func unregister(_ view: NSView) {
        lock.lock()
        records.removeValue(forKey: ObjectIdentifier(view))
        lock.unlock()
    }

    @MainActor
    func hit(at windowPoint: NSPoint, in window: NSWindow) -> BrowserMenuHit? {
        lock.lock()
        records = records.filter { $0.value.view != nil }
        let snapshot = Array(records.values)
        lock.unlock()

        var best: (hit: BrowserMenuHit, area: CGFloat)?
        for record in snapshot {
            guard let view = record.view,
                  view.window === window,
                  view.superview != nil,
                  !view.isHiddenOrHasHiddenAncestor,
                  view.visibleRect.width > 0,
                  view.visibleRect.height > 0
            else { continue }
            let frame = view.convert(view.bounds, to: nil)
            guard frame.contains(windowPoint) else { continue }
            guard BrowserMenuHitResolver.isCellSized(frame.size) else { continue }
            guard let hit = BrowserMenuHit.parseIdentifier(record.id) else { continue }
            let area = frame.width * frame.height
            if best.map({ area < $0.area }) ?? true {
                best = (hit, area)
            }
        }
        return best?.hit
    }
}

enum BrowserContextKind: Equatable {
    case folderListing
    case bucketSearch
}

struct BrowserContextActions {
    var pasteTitle: String
    var pasteIntoFolderTitle: String
    var canPaste: () -> Bool
    var hasCloudClipboard: () -> Bool
    var canDeselect: Bool
    var isOrganizing: Bool
    var tableItemIDs: [String]
    var viewMode: BrowserViewMode
    var selectedKeys: () -> Set<String>
    var isFavorite: (String) -> Bool
    var deleteTitle: (String) -> String
    var downloadTitle: (String) -> String
    var showsRevealInFolder: Bool
    var usesSearchEmptyMenu: Bool

    var onHighlight: (String) -> Void
    var onSelectItem: (String, BrowserSelectionModifiers) -> Void
    var onBackgroundClick: () -> Void
    var onOpenItem: (String) -> Void
    var onPaste: () -> Void
    var onPasteInto: (String) -> Void
    var onUpload: () -> Void
    var onPasteLocal: () -> Void
    var onNewFolder: () -> Void
    var onDownloadCurrent: () -> Void
    var onRefresh: () -> Void
    var onSelectAll: () -> Void
    var onDeselect: () -> Void
    var onOpenFolder: (String) -> Void
    var onQuickLook: (String) -> Void
    var onCopy: (String) -> Void
    var onCut: (String) -> Void
    var onRename: (String) -> Void
    var onDelete: (String) -> Void
    var onDownload: (String) -> Void
    var onToggleFavorite: (String) -> Void
    var onCopyLink: (String) -> Void
    var onCopyMarkdown: (String) -> Void
    var onObjectProperties: (String) -> Void
    var onRevealInFolder: (String) -> Void
}

struct BrowserItemMarker: NSViewRepresentable {
    var id: String

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.itemID = id
        return view
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.itemID = id
        view.tagCell()
    }

    final class Probe: NSView {
        var itemID = ""

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            autoresizingMask = [.width, .height]
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            autoresizingMask = [.width, .height]
        }

        deinit {
            BrowserItemHitRegistry.shared.unregister(self)
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            tagCell()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tagCell()
        }

        override func layout() {
            super.layout()
            tagCell()
        }

        func tagCell() {
            guard !itemID.isEmpty else { return }
            identifier = NSUserInterfaceItemIdentifier(itemID)
            if BrowserMenuHitResolver.isCellSized(bounds.size) {
                BrowserItemHitRegistry.shared.register(self, id: itemID)
            }
        }
    }
}

struct BrowserBackgroundMenuOverlay: NSViewRepresentable {
    var actions: BrowserContextActions

    func makeCoordinator() -> Coordinator {
        Coordinator(actions: actions)
    }

    func makeNSView(context: Context) -> Host {
        let host = Host()
        context.coordinator.host = host
        host.coordinator = context.coordinator
        return host
    }

    func updateNSView(_ host: Host, context: Context) {
        context.coordinator.actions = actions
        context.coordinator.host = host
        host.coordinator = context.coordinator
    }

    final class Host: NSView {
        var coordinator: Coordinator?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.installIfNeeded()
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var actions: BrowserContextActions
        weak var host: Host?
        nonisolated(unsafe) private var monitor: Any?

        init(actions: BrowserContextActions) {
            self.actions = actions
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func installIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                let snapshot = BrowserMouseSnapshot(event)
                let consume = MainActor.assumeIsolated {
                    self?.handleMouse(snapshot) ?? false
                }
                return consume ? nil : event
            }
        }

        private func handleMouse(_ snapshot: BrowserMouseSnapshot) -> Bool {
            guard let host, let window = host.window, window.windowNumber == snapshot.windowNumber else {
                return false
            }
            let location = host.convert(snapshot.locationInWindow, from: nil)
            guard host.bounds.contains(location), host.bounds.width > 8, host.bounds.height > 8 else {
                return false
            }

            let hitView = window.contentView?.hitTest(snapshot.locationInWindow)
            let hit = BrowserMenuHitResolver.resolve(
                hitView: hitView,
                windowPoint: snapshot.locationInWindow,
                window: window,
                tableItemIDs: actions.tableItemIDs,
                registry: .shared
            )
            let looksLikeItem = BrowserMenuHitResolver.looksLikeItemControl(startingAt: hitView)

            if snapshot.isRight {
                switch BrowserPointerPolicy.action(
                    kind: .right,
                    clickCount: snapshot.clickCount,
                    hit: hit,
                    looksLikeItemControl: looksLikeItem,
                    modifiers: snapshot.modifiers,
                    selectOnSingleClick: false
                ) {
                case .showMenu(let menuHit):
                    BrowserShortcutScope.focusBrowser(in: window)
                    if let itemID = menuHit.itemID {
                        actions.onHighlight(itemID)
                        presentMenu(hit: menuHit, at: snapshot.locationInWindow, in: window, afterHighlight: true)
                    } else {
                        presentMenu(hit: menuHit, at: snapshot.locationInWindow, in: window, afterHighlight: false)
                    }
                    return true
                case .passThrough, .clearSelection, .selectAndOpen, .select:
                    return false
                }
            }

            if snapshot.isLeft {
                switch BrowserPointerPolicy.action(
                    kind: .left,
                    clickCount: snapshot.clickCount,
                    hit: hit,
                    looksLikeItemControl: looksLikeItem,
                    modifiers: snapshot.modifiers,
                    selectOnSingleClick: actions.viewMode == .grid
                ) {
                case .selectAndOpen(let itemID):
                    BrowserShortcutScope.focusBrowser(in: window)
                    actions.onOpenItem(itemID)
                    return true
                case .select(let itemID, let modifiers):
                    BrowserShortcutScope.focusBrowser(in: window)
                    actions.onSelectItem(itemID, modifiers)
                    return false
                case .clearSelection:
                    BrowserShortcutScope.focusBrowser(in: window)
                    actions.onBackgroundClick()
                    return false
                case .showMenu, .passThrough:
                    return false
                }
            }
            return false
        }

        private func presentMenu(
            hit: BrowserMenuHit,
            at windowPoint: NSPoint,
            in window: NSWindow,
            afterHighlight: Bool
        ) {
            if afterHighlight {
                Task { @MainActor [weak self] in
                    guard let self, let window = self.host?.window else { return }
                    self.popMenu(hit: hit, at: windowPoint, in: window)
                }
            } else {
                popMenu(hit: hit, at: windowPoint, in: window)
            }
        }

        private func popMenu(hit: BrowserMenuHit, at windowPoint: NSPoint, in window: NSWindow) {
            guard host?.window === window else { return }
            window.layoutIfNeeded()
            window.displayIfNeeded()
            let menu = RetainedMenu(actions: actions, hit: hit)
            guard let content = window.contentView,
                  let popupEvent = NSEvent.mouseEvent(
                    with: .rightMouseDown,
                    location: windowPoint,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                  )
            else { return }
            NSMenu.popUpContextMenu(menu, with: popupEvent, for: content)
        }
    }
}

struct BrowserMouseSnapshot: Sendable {
    var isRight: Bool
    var isLeft: Bool
    var clickCount: Int
    var modifiers: BrowserSelectionModifiers
    var locationInWindow: CGPoint
    var windowNumber: Int

    init(_ event: NSEvent) {
        isRight = event.type == .rightMouseDown
        isLeft = event.type == .leftMouseDown
        clickCount = event.clickCount
        modifiers = BrowserSelectionModifiers.from(event)
        locationInWindow = event.locationInWindow
        windowNumber = event.windowNumber
    }
}

enum BrowserPointerPolicy {
    enum Kind: Equatable {
        case left
        case right
    }

    enum Action: Equatable {
        case showMenu(BrowserMenuHit)
        case selectAndOpen(String)
        case select(String, BrowserSelectionModifiers)
        case clearSelection
        case passThrough
    }

    /// Resolves what a click should do. This is the single shared activation
    /// path for both grid and list views: a single click selects on mouse-down
    /// (Finder style, honoring Command/Shift), a double click opens the item,
    /// and a plain click on empty space clears the selection.
    static func action(
        kind: Kind,
        clickCount: Int,
        hit: BrowserMenuHit,
        looksLikeItemControl: Bool,
        modifiers: BrowserSelectionModifiers,
        selectOnSingleClick: Bool
    ) -> Action {
        switch kind {
        case .right:
            if hit != .empty { return .showMenu(hit) }
            return looksLikeItemControl ? .passThrough : .showMenu(.empty)
        case .left:
            guard !looksLikeItemControl else { return .passThrough }
            if clickCount >= 2 {
                guard let itemID = hit.itemID else { return .passThrough }
                return .selectAndOpen(itemID)
            }
            if clickCount == 1 {
                if let itemID = hit.itemID {
                    // Grid selects every click itself. List mode also selects
                    // plain clicks (idempotent with the table's own selection,
                    // so the highlight never depends on table internals), but
                    // leaves Command/Shift clicks to the native table to avoid
                    // double-toggling the same key.
                    if selectOnSingleClick || modifiers.isEmpty {
                        return .select(itemID, modifiers)
                    }
                    return .passThrough
                }
                return modifiers.isEmpty ? .clearSelection : .passThrough
            }
            return .passThrough
        }
    }
}

extension BrowserSelectionModifiers {
    static func from(_ event: NSEvent) -> BrowserSelectionModifiers {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: BrowserSelectionModifiers = []
        if flags.contains(.command) { modifiers.insert(.toggle) }
        if flags.contains(.shift) { modifiers.insert(.extendRange) }
        return modifiers
    }
}

enum BrowserTableSelection {
    static func rowIndexes(itemIDs: [String], selected: Set<String>, rowCount: Int) -> IndexSet {
        var rows = IndexSet()
        let count = min(itemIDs.count, rowCount)
        for index in 0..<count where selected.contains(itemIDs[index]) {
            rows.insert(index)
        }
        return rows
    }
}

@MainActor
private final class RetainedMenu: NSMenu {
    private let target: MenuTarget

    init(actions: BrowserContextActions, hit: BrowserMenuHit) {
        target = MenuTarget(actions: actions, hit: hit)
        super.init(title: "")
        autoenablesItems = false
        target.populate(self)
    }

    nonisolated required init(coder: NSCoder) {
        // NSMenu's NSCoder initializer is imported as nonisolated even though
        // AppKit constructs menus on the main thread. State that invariant
        // explicitly so Swift 6 does not treat MenuTarget initialization as a
        // cross-actor call.
        target = MainActor.assumeIsolated {
            MenuTarget(actions: .disabled, hit: .empty)
        }
        super.init(coder: coder)
    }
}

@MainActor
private final class MenuTarget: NSObject {
    let actions: BrowserContextActions
    let hit: BrowserMenuHit

    init(actions: BrowserContextActions, hit: BrowserMenuHit) {
        self.actions = actions
        self.hit = hit
    }

    func populate(_ menu: NSMenu) {
        switch hit {
        case .empty:
            populateEmpty(menu)
        case .folder(let prefix):
            populateFolder(menu, prefix: prefix)
        case .file(let key):
            populateFile(menu, key: key)
        }
    }

    private func populateEmpty(_ menu: NSMenu) {
        if actions.usesSearchEmptyMenu {
            add(menu, "全选", #selector(performSelectAll))
            if actions.canDeselect {
                add(menu, "取消选择", #selector(performDeselect))
            }
            separator(menu)
            add(menu, "再试一次", #selector(performRefresh))
            return
        }
        add(menu, actions.pasteTitle, #selector(performPaste), enabled: actions.canPaste())
        separator(menu)
        add(menu, "上传", #selector(performUpload))
        add(menu, "从剪贴板上传", #selector(performPasteLocal))
        add(menu, "新建文件夹", #selector(performNewFolder))
        separator(menu)
        add(menu, "下载当前文件夹", #selector(performDownloadCurrent))
        add(menu, "刷新", #selector(performRefresh))
        separator(menu)
        add(menu, "全选", #selector(performSelectAll))
        if actions.canDeselect {
            add(menu, "取消选择", #selector(performDeselect))
        }
    }

    private func populateFolder(_ menu: NSMenu, prefix: String) {
        add(menu, "打开", #selector(performOpenFolder))
        add(menu, actions.deleteTitle(prefix), #selector(performDelete), enabled: !actions.isOrganizing)
        separator(menu)
        add(
            menu,
            actions.isFavorite(prefix) ? "从常用中移除" : "添加到常用",
            #selector(performToggleFavorite)
        )
        add(menu, actions.downloadTitle(prefix), #selector(performDownloadItem))
        add(menu, "复制", #selector(performCopy))
        add(menu, "剪切", #selector(performCut))
        add(
            menu,
            actions.pasteIntoFolderTitle,
            #selector(performPasteInto),
            enabled: actions.canPaste()
        )
        add(menu, "重命名", #selector(performRename), enabled: !actions.isOrganizing)
    }

    private func populateFile(_ menu: NSMenu, key: String) {
        add(menu, "快速查看", #selector(performQuickLook))
        add(menu, actions.deleteTitle(key), #selector(performDelete), enabled: !actions.isOrganizing)
        if actions.showsRevealInFolder {
            add(menu, "显示所在文件夹", #selector(performRevealInFolder))
        }
        separator(menu)
        add(menu, "复制链接", #selector(performCopyLink))
        add(menu, "复制 Markdown", #selector(performCopyMarkdown))
        add(menu, "复制", #selector(performCopy))
        add(menu, "剪切", #selector(performCut))
        if !actions.showsRevealInFolder {
            add(menu, actions.pasteTitle, #selector(performPaste), enabled: actions.canPaste())
        }
        add(menu, actions.downloadTitle(key), #selector(performDownloadItem))
        add(menu, "重命名", #selector(performRename), enabled: !actions.isOrganizing)
        add(menu, "对象属性", #selector(performObjectProperties))
    }

    private func add(_ menu: NSMenu, _ title: String, _ selector: Selector, enabled: Bool = true) {
        let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
    }

    private func separator(_ menu: NSMenu) {
        menu.addItem(.separator())
    }

    @objc func performPaste() { actions.onPaste() }
    @objc func performPasteInto() {
        if case .folder(let prefix) = hit { actions.onPasteInto(prefix) }
    }
    @objc func performUpload() { actions.onUpload() }
    @objc func performPasteLocal() { actions.onPasteLocal() }
    @objc func performNewFolder() { actions.onNewFolder() }
    @objc func performDownloadCurrent() { actions.onDownloadCurrent() }
    @objc func performRefresh() { actions.onRefresh() }
    @objc func performSelectAll() { actions.onSelectAll() }
    @objc func performDeselect() { actions.onDeselect() }
    @objc func performOpenFolder() {
        if case .folder(let prefix) = hit { actions.onOpenFolder(prefix) }
    }
    @objc func performQuickLook() {
        if case .file(let key) = hit { actions.onQuickLook(key) }
    }
    @objc func performCopy() { if let key = hit.itemID { actions.onCopy(key) } }
    @objc func performCut() { if let key = hit.itemID { actions.onCut(key) } }
    @objc func performRename() { if let key = hit.itemID { actions.onRename(key) } }
    @objc func performDelete() { if let key = hit.itemID { actions.onDelete(key) } }
    @objc func performDownloadItem() { if let key = hit.itemID { actions.onDownload(key) } }
    @objc func performToggleFavorite() {
        if case .folder(let prefix) = hit { actions.onToggleFavorite(prefix) }
    }
    @objc func performCopyLink() {
        if case .file(let key) = hit { actions.onCopyLink(key) }
    }
    @objc func performCopyMarkdown() {
        if case .file(let key) = hit { actions.onCopyMarkdown(key) }
    }
    @objc func performObjectProperties() {
        if case .file(let key) = hit { actions.onObjectProperties(key) }
    }
    @objc func performRevealInFolder() {
        if case .file(let key) = hit { actions.onRevealInFolder(key) }
    }
}

extension BrowserContextActions {
    @MainActor
    static func live(
        model: AppModel,
        kind: BrowserContextKind,
        showFileImporter: @escaping () -> Void
    ) -> BrowserContextActions {
        let isSearch = kind == .bucketSearch
        return BrowserContextActions(
            pasteTitle: model.pasteMenuTitle,
            pasteIntoFolderTitle: model.pasteIntoFolderTitle,
            canPaste: { model.canPaste },
            hasCloudClipboard: { model.canPasteCloudItems },
            canDeselect: !model.actionableSelectionKeys.isEmpty,
            isOrganizing: model.isOrganizingCloud,
            tableItemIDs: isSearch
                ? model.searchController.results.map(\.key)
                : model.browser.orderedVisibleKeys,
            viewMode: isSearch ? .list : model.browser.viewMode,
            selectedKeys: { model.actionableSelectionKeys },
            isFavorite: { prefix in model.isFavorite(prefix: prefix) },
            deleteTitle: { model.deleteMenuTitle(clickedKey: $0) },
            downloadTitle: { model.downloadMenuTitle(clickedKey: $0) },
            showsRevealInFolder: isSearch,
            usesSearchEmptyMenu: isSearch,
            onHighlight: { model.selectForContextMenu($0) },
            onSelectItem: { key, modifiers in
                if isSearch {
                    if modifiers.isEmpty {
                        model.selectSearchKeys([key])
                    }
                    return
                }
                model.browser.select(key: key, modifiers: modifiers)
            },
            onBackgroundClick: { model.clearVisibleSelection() },
            onOpenItem: { model.openVisibleItem(id: $0) },
            onPaste: { model.paste() },
            onPasteInto: { model.paste(into: $0) },
            onUpload: showFileImporter,
            onPasteLocal: { model.pasteFromClipboard() },
            onNewFolder: { model.wantsNewFolder = true },
            onDownloadCurrent: { model.downloadCurrentPrefix() },
            onRefresh: {
                if isSearch {
                    Task { await model.runBucketSearch() }
                } else {
                    Task { await model.refreshListing() }
                }
            },
            onSelectAll: { model.selectAllVisible() },
            onDeselect: { model.clearVisibleSelection() },
            onOpenFolder: { prefix in
                if let folder = model.browser.folders.first(where: { $0.prefix == prefix }) {
                    model.openFolder(folder)
                }
            },
            onQuickLook: { key in
                model.selectForContextMenu(key)
                Task {
                    if let object = model.object(forKey: key) {
                        await model.quickLook(object)
                    } else {
                        await model.quickLookSelection()
                    }
                }
            },
            onCopy: { model.copyCloudSelection(clickedKey: $0) },
            onCut: { model.cutCloudSelection(clickedKey: $0) },
            onRename: { model.requestRename(key: $0) },
            onDelete: { key in
                model.requestDeleteSelection(
                    keys: model.menuActionKeys(clickedKey: key),
                    deferConfirmation: true
                )
            },
            onDownload: { key in
                model.selectForContextMenu(key)
                model.downloadSelection()
            },
            onToggleFavorite: { prefix in
                if let folder = model.browser.folders.first(where: { $0.prefix == prefix }) {
                    model.toggleFavorite(prefix: prefix, name: folder.name)
                }
            },
            onCopyLink: { key in
                model.selectForContextMenu(key)
                model.copyURLs(style: .plain)
            },
            onCopyMarkdown: { key in
                model.selectForContextMenu(key)
                model.copyURLs(style: .markdown)
            },
            onObjectProperties: { key in
                if let object = model.object(forKey: key) {
                    model.presentObjectProperties(for: object)
                }
            },
            onRevealInFolder: { key in
                if let object = model.object(forKey: key) {
                    Task { await model.openSearchResult(object) }
                }
            }
        )
    }

    static var disabled: BrowserContextActions {
        BrowserContextActions(
            pasteTitle: "粘贴",
            pasteIntoFolderTitle: "粘贴到此文件夹",
            canPaste: { false },
            hasCloudClipboard: { false },
            canDeselect: false,
            isOrganizing: false,
            tableItemIDs: [],
            viewMode: .grid,
            selectedKeys: { [] },
            isFavorite: { _ in false },
            deleteTitle: { _ in "删除" },
            downloadTitle: { _ in "下载" },
            showsRevealInFolder: false,
            usesSearchEmptyMenu: false,
            onHighlight: { _ in },
            onSelectItem: { _, _ in },
            onBackgroundClick: {},
            onOpenItem: { _ in },
            onPaste: {},
            onPasteInto: { _ in },
            onUpload: {},
            onPasteLocal: {},
            onNewFolder: {},
            onDownloadCurrent: {},
            onRefresh: {},
            onSelectAll: {},
            onDeselect: {},
            onOpenFolder: { _ in },
            onQuickLook: { _ in },
            onCopy: { _ in },
            onCut: { _ in },
            onRename: { _ in },
            onDelete: { _ in },
            onDownload: { _ in },
            onToggleFavorite: { _ in },
            onCopyLink: { _ in },
            onCopyMarkdown: { _ in },
            onObjectProperties: { _ in },
            onRevealInFolder: { _ in }
        )
    }
}
