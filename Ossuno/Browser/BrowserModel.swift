import Foundation
import Observation

enum BrowserViewMode: String, CaseIterable, Identifiable {
    case grid
    case list
    var id: String { rawValue }
    var title: String { self == .grid ? "网格" : "列表" }
    var symbol: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
}

struct BrowserSelectionModifiers: OptionSet, Sendable {
    let rawValue: Int

    static let toggle = BrowserSelectionModifiers(rawValue: 1 << 0)
    static let extendRange = BrowserSelectionModifiers(rawValue: 1 << 1)
}

enum BrowserSelectionDirection: Sendable {
    case previous
    case next
}

enum BrowserSortField: String, CaseIterable, Identifiable, Hashable, Sendable {
    case name
    case modified
    case size
    case kind

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "名称"
        case .modified: "修改时间"
        case .size: "大小"
        case .kind: "种类"
        }
    }
}

enum BrowserSortDirection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case ascending
    case descending

    var id: String { rawValue }
    var title: String { self == .ascending ? "升序" : "降序" }
    var symbol: String { self == .ascending ? "arrow.up" : "arrow.down" }
}

@MainActor
@Observable
final class BrowserModel {
    private let defaults: UserDefaults

    var prefix = "" {
        didSet {
            guard prefix != oldValue else { return }
            transientlyRevealedKey = nil
            searchText = ""
            isListingTruncated = false
            clearSelection()
        }
    }
    var folders: [OSSFolder] = []
    var objects: [OSSObject] = []
    private(set) var selectedKeys: Set<String> = [] {
        didSet {
            selectionEpoch += 1
            if let renameSession, selectedKeys != [renameSession.key] {
                self.renameSession = nil
            }
        }
    }
    var selectionEpoch = 0
    private(set) var selectionAnchorKey: String?
    private(set) var focusedKey: String?
    private(set) var renameSession: BrowserRenameSession?
    var viewMode: BrowserViewMode = .grid
    var sortField: BrowserSortField {
        didSet { defaults.set(sortField.rawValue, forKey: Keys.sortField) }
    }
    var sortDirection: BrowserSortDirection {
        didSet { defaults.set(sortDirection.rawValue, forKey: Keys.sortDirection) }
    }
    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            transientlyRevealedKey = nil
            reconcileVisibleState()
        }
    }
    var isLoading = false
    var isListingTruncated = false
    var errorMessage: String?
    var dropTargets: Set<String> = []

    var activeDropPrefix: String? {
        dropTargets.max(by: { $0.count < $1.count })
    }

    func setDropTarget(_ prefix: String, active: Bool) {
        if active {
            dropTargets.insert(prefix)
        } else {
            dropTargets.remove(prefix)
        }
    }
    var lastRefresh: Date?
    var backStack: [String] = []
    var forwardStack: [String] = []

    /// Optional media-focused browser filter. OSS itself can contain arbitrary
    /// object types, so a new browser must never hide objects by default.
    var imagesOnly = false {
        didSet {
            guard imagesOnly != oldValue else { return }
            transientlyRevealedKey = nil
            reconcileVisibleState()
        }
    }
    /// A search result outside the optional material filter remains visible in
    /// its containing folder long enough to be located and acted on. This is a
    /// session-only exception and never changes the persisted filter setting.
    private(set) var transientlyRevealedKey: String?
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.sortField = defaults.string(forKey: Keys.sortField)
            .flatMap(BrowserSortField.init(rawValue:)) ?? .name
        self.sortDirection = defaults.string(forKey: Keys.sortDirection)
            .flatMap(BrowserSortDirection.init(rawValue:)) ?? .ascending
    }

    var visibleFolders: [OSSFolder] {
        filtered(folders, name: \.name).sorted { lhs, rhs in
            ordered(lhs.name.localizedStandardCompare(rhs.name))
        }
    }

    var visibleObjects: [OSSObject] {
        let source = imagesOnly
            ? objects.filter { $0.isSupported || $0.key == transientlyRevealedKey }
            : objects
        return filtered(source, name: \.name).sorted(by: objectsAreOrdered)
    }

    var selectedObjects: [OSSObject] {
        visibleObjects.filter { selectedKeys.contains($0.key) }
    }

    var selectedFolders: [OSSFolder] {
        visibleFolders.filter { selectedKeys.contains($0.prefix) }
    }

    var visibleKeys: Set<String> {
        Set(visibleFolders.map(\.prefix)).union(visibleObjects.map(\.key))
    }

    var orderedVisibleKeys: [String] {
        visibleFolders.map(\.prefix) + visibleObjects.map(\.key)
    }

    var actionableSelectionKeys: Set<String> {
        selectedKeys.intersection(visibleKeys)
    }

    func selectAllVisible() {
        selectedKeys = visibleKeys
    }

    var primarySelection: OSSObject? {
        if let focusedKey, selectedKeys.contains(focusedKey),
           let focused = visibleObjects.first(where: { $0.key == focusedKey }) {
            return focused
        }
        return visibleObjects.first(where: { selectedKeys.contains($0.key) })
    }

    func select(key: String, modifiers: BrowserSelectionModifiers) {
        let ordered = orderedVisibleKeys
        guard let targetIndex = ordered.firstIndex(of: key) else { return }

        if modifiers.contains(.extendRange) {
            let anchor = selectionAnchorKey ?? focusedKey ?? key
            let anchorIndex = ordered.firstIndex(of: anchor) ?? targetIndex
            let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
            let rangeKeys = Set(range.map { ordered[$0] })
            if modifiers.contains(.toggle) {
                selectedKeys.formUnion(rangeKeys)
            } else {
                selectedKeys = rangeKeys
            }
            selectionAnchorKey = anchor
            focusedKey = key
            return
        }

        if modifiers.contains(.toggle) {
            if selectedKeys.contains(key) {
                selectedKeys.remove(key)
            } else {
                selectedKeys.insert(key)
            }
            focusedKey = key
            selectionAnchorKey = selectedKeys.contains(key)
                ? key
                : ordered.first(where: { selectedKeys.contains($0) })
            return
        }

        selectedKeys = [key]
        selectionAnchorKey = key
        focusedKey = key
    }

    func replaceSelection(_ keys: Set<String>) {
        let visible = keys.intersection(visibleKeys)
        selectedKeys = visible
        let first = orderedVisibleKeys.first(where: { visible.contains($0) })
        focusedKey = first
        selectionAnchorKey = first
    }

    func selectForContextMenu(key: String) {
        guard visibleKeys.contains(key) else { return }
        if selectedKeys.contains(key) {
            focusedKey = key
            if selectionAnchorKey == nil {
                selectionAnchorKey = key
            }
            selectionEpoch += 1
            return
        }
        select(key: key, modifiers: [])
    }

    func moveSelection(_ direction: BrowserSelectionDirection, extending: Bool) {
        let ordered = orderedVisibleKeys
        guard !ordered.isEmpty else { return }
        let current = focusedKey.flatMap { ordered.firstIndex(of: $0) }
            ?? ordered.firstIndex(where: { selectedKeys.contains($0) })
            ?? (direction == .next ? -1 : ordered.count)
        let targetIndex: Int
        switch direction {
        case .previous:
            targetIndex = max(0, current - 1)
        case .next:
            targetIndex = min(ordered.count - 1, current + 1)
        }
        select(
            key: ordered[targetIndex],
            modifiers: extending ? [.extendRange] : []
        )
    }

    func clearSelection() {
        selectedKeys = []
        selectionAnchorKey = nil
        focusedKey = nil
    }

    func revealObjectTemporarily(_ key: String) {
        transientlyRevealedKey = key
        reconcileVisibleState()
    }

    @discardableResult
    func beginRenaming(key requestedKey: String? = nil) -> Bool {
        guard !isLoading else { return false }
        if let requestedKey {
            guard visibleKeys.contains(requestedKey) else { return false }
            select(key: requestedKey, modifiers: [])
        }
        guard selectedKeys.count == 1,
              let key = selectedKeys.first,
              visibleKeys.contains(key)
        else { return false }
        if renameSession?.key == key {
            return true
        }
        if let folder = visibleFolders.first(where: { $0.prefix == key }) {
            renameSession = BrowserRenameSession(key: key, name: folder.name, kind: .folder)
            return true
        }
        if let object = visibleObjects.first(where: { $0.key == key }) {
            renameSession = BrowserRenameSession(key: key, name: object.name, kind: .object)
            return true
        }
        return false
    }

    func updateRenameDraft(_ draft: String) {
        guard renameSession?.isCommitting == false else { return }
        renameSession?.draft = draft
    }

    func setRenameCommitting(_ isCommitting: Bool) {
        renameSession?.isCommitting = isCommitting
    }

    func cancelRenaming() {
        guard renameSession?.isCommitting != true else { return }
        renameSession = nil
    }

    func finishRenaming() {
        renameSession = nil
    }

    func reset() {
        transientlyRevealedKey = nil
        prefix = ""
        folders = []
        objects = []
        isListingTruncated = false
        clearSelection()
        errorMessage = nil
        isLoading = false
        backStack = []
        forwardStack = []
    }

    func navigate(to newPrefix: String, record: Bool = true) {
        guard newPrefix != prefix else {
            clearSelection()
            return
        }
        if record {
            backStack.append(prefix)
            forwardStack.removeAll()
        }
        prefix = newPrefix
        clearSelection()
    }

    func goBack() -> Bool {
        guard let previous = backStack.popLast() else { return false }
        forwardStack.append(prefix)
        prefix = previous
        clearSelection()
        return true
    }

    func goForward() -> Bool {
        guard let next = forwardStack.popLast() else { return false }
        backStack.append(prefix)
        prefix = next
        clearSelection()
        return true
    }

    func apply(_ listing: ObjectListing, imagesOnly: Bool) {
        self.imagesOnly = imagesOnly
        folders = listing.folders
        objects = listing.objects
        isListingTruncated = listing.isTruncated
        reconcileVisibleState()
        lastRefresh = .now
        errorMessage = nil
    }

    private func reconcileVisibleState() {
        let visible = visibleKeys
        let retainedSelection = selectedKeys.intersection(visible)
        if retainedSelection != selectedKeys {
            selectedKeys = retainedSelection
        }
        if let focusedKey, !visible.contains(focusedKey) {
            self.focusedKey = nil
        }
        if let selectionAnchorKey, !visible.contains(selectionAnchorKey) {
            self.selectionAnchorKey = nil
        }
        if let renameSession, !visible.contains(renameSession.key) {
            self.renameSession = nil
        }
    }

    private func filtered<T>(_ items: [T], name: KeyPath<T, String>) -> [T] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter { $0[keyPath: name].localizedCaseInsensitiveContains(query) }
    }

    private func objectsAreOrdered(_ lhs: OSSObject, _ rhs: OSSObject) -> Bool {
        let primary: ComparisonResult
        switch sortField {
        case .name:
            primary = lhs.name.localizedStandardCompare(rhs.name)
        case .modified:
            primary = compare(lhs.lastModified ?? .distantPast, rhs.lastModified ?? .distantPast)
        case .size:
            primary = compare(lhs.size, rhs.size)
        case .kind:
            primary = ImageKind.displayKind(for: lhs.key)
                .localizedStandardCompare(ImageKind.displayKind(for: rhs.key))
        }
        let result = primary == .orderedSame
            ? lhs.name.localizedStandardCompare(rhs.name)
            : primary
        return ordered(result)
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private func ordered(_ result: ComparisonResult) -> Bool {
        switch sortDirection {
        case .ascending: result == .orderedAscending
        case .descending: result == .orderedDescending
        }
    }

    private enum Keys {
        static let sortField = "browser.sortField"
        static let sortDirection = "browser.sortDirection"
    }
}
