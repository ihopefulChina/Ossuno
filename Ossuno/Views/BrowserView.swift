import AppKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct BrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var showFileImporter: Bool
    @State private var photos: [PhotosPickerItem] = []

    var body: some View {
        @Bindable var model = model
        // Resolve the AppModel ONCE here. Closures that execute later —
        // toolbar button actions, drop handlers, and especially Table cell
        // content — run in AppKit hosting contexts where reading
        // `@Environment(AppModel.self)` can trap ("No Observable object of
        // type AppModel found"), so they must use this captured reference.
        let modelRef = model
        VStack(spacing: 0) {
            if showsSearchChrome {
                searchScopeBar
            }
            ZStack(alignment: .bottom) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Keep the final list row clear of the overlaid Finder-style
                    // path bar. Using an overlay also avoids the macOS 15 issue
                    // where a trailing flexible VStack sibling can disappear.
                    .padding(.bottom, modelRef.selectedBucket == nil ? 0 : FinderChrome.barHeight)
                if modelRef.selectedBucket != nil {
                    PathBar(showFileImporter: $showFileImporter)
                }
            }
        }
        // Keep the transfer status bar in the detail column only, like Finder's
        // path/status bars, so the sidebar material runs to the window bottom.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if modelRef.transfers.hasJobs {
                TransferTray()
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : Motion.chrome, value: modelRef.transfers.hasJobs)
        .background(BrowserShortcutScopeProbe())
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .searchable(text: $model.browser.searchText, placement: .toolbar, prompt: searchPrompt)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    modelRef.goBack()
                } label: {
                    Label("后退", systemImage: "chevron.left")
                }
                .disabled(!modelRef.browser.canGoBack)
                .help("后退")

                Button {
                    modelRef.goForward()
                } label: {
                    Label("前进", systemImage: "chevron.right")
                }
                .disabled(!modelRef.browser.canGoForward)
                .help("前进")
            }
        }
        .onChange(of: model.searchScope) { _, scope in
            if scope == .folder {
                modelRef.searchFilter = .all
            }
        }
        .overlay {
            if let prefix = modelRef.browser.activeDropPrefix, prefix == modelRef.browser.prefix {
                dropScrim(title: "放到当前文件夹")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            modelRef.upload(urls: urls, to: modelRef.browser.prefix, applyTemplate: modelRef.browser.prefix.isEmpty)
            return true
        } isTargeted: { targeted in
            modelRef.browser.setDropTarget(modelRef.browser.prefix, active: targeted)
        }
        .dropDestination(for: CloudDragPayload.self) { payloads, _ in
            guard let payload = payloads.first else { return false }
            modelRef.moveCloudItems(payload, to: modelRef.browser.prefix)
            return true
        } isTargeted: { targeted in
            modelRef.browser.setDropTarget(modelRef.browser.prefix, active: targeted)
        }
        .onPasteCommand(of: [UTType.ossunoCloudItems, .image, .fileURL, .gif, .webP, .png, .jpeg]) { _ in
            modelRef.paste()
        }
        .onChange(of: photos) { _, items in
            Task { await importPhotos(modelRef, items: items) }
        }
        .task(id: searchRequest) {
            #if DEBUG
            if ScreenshotDemo.currentMode == .browser { return }
            #endif
            guard modelRef.isBucketSearchActive else {
                modelRef.clearBucketSearch()
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                await modelRef.runBucketSearch()
            } catch {
                modelRef.cancelBucketSearch()
            }
        }
        .overlay(alignment: .top) {
            if modelRef.isOrganizingCloud {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在整理云端项目…")
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.bar, in: Capsule())
                .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let modelRef = model
        if modelRef.selectedBucket == nil {
            Text("在左侧选择一个存储空间")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if modelRef.isBucketSearchActive {
            BucketSearchView()
        } else if modelRef.browser.isLoading && modelRef.browser.objects.isEmpty && modelRef.browser.folders.isEmpty {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = modelRef.browser.errorMessage, modelRef.browser.objects.isEmpty && modelRef.browser.folders.isEmpty {
            VStack(spacing: 8) {
                Text("无法读取这个文件夹")
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                Button("再试一次") { Task { await modelRef.refreshListing() } }
                    .buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if modelRef.browser.visibleFolders.isEmpty && modelRef.browser.visibleObjects.isEmpty {
            emptyState
        } else if modelRef.browser.viewMode == .grid {
            grid
        } else {
            table
        }
    }

    private var title: String {
        if model.isBucketSearchActive {
            return model.selectedBucket?.name ?? "搜索"
        }
        if model.browser.prefix.isEmpty {
            return model.selectedBucket?.name ?? "素材"
        }
        return PathTemplate.lastComponent(model.browser.prefix)
    }

    private var subtitle: String {
        if model.isBucketSearchActive {
            let progress = model.searchController.progress
            return model.searchController.isSearching
                ? "正在搜索当前 Bucket"
                : "找到 \(progress.matched) 项"
        }
        let folders = model.browser.visibleFolders.count
        let files = model.browser.visibleObjects.count
        var parts: [String] = []
        if folders > 0 { parts.append("\(folders) 个文件夹") }
        if files > 0 { parts.append("\(files) 项") }
        return parts.joined(separator: " · ")
    }

    private var searchPrompt: String {
        model.searchScope == .folder ? "搜索当前文件夹" : "搜索当前 Bucket"
    }

    private var showsSearchChrome: Bool {
        model.showsSearchChrome
    }

    private var searchScopeBar: some View {
        @Bindable var model = model
        return HStack(spacing: 10) {
            Picker("搜索范围", selection: $model.searchScope) {
                ForEach(BucketSearchScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 220)

            if model.searchScope == .bucket {
                if model.searchController.isSearching {
                    ProgressView()
                        .controlSize(.small)
                    Text("已扫描 \(model.searchController.progress.scanned) 项")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("停止") { model.cancelBucketSearch() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                } else if model.isBucketSearchActive {
                    Text(model.searchController.snapshot?.isIncomplete == true
                         ? "找到 \(model.searchController.progress.matched) 项，结果可能不完整"
                         : "找到 \(model.searchController.progress.matched) 项")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Spacer(minLength: 8)

            if model.searchScope == .bucket {
                BucketSearchFilterMenu()
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var searchRequest: BucketSearchRequest {
        BucketSearchRequest(
            accountID: model.selectedAccountID,
            bucketName: model.selectedBucketName,
            text: model.browser.searchText,
            scope: model.searchScope,
            filter: model.searchFilter
        )
    }

    private var emptyState: some View {
        let modelRef = model
        return VStack(spacing: 10) {
            Image(systemName: "photo")
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text(model.browser.searchText.isEmpty ? "此文件夹为空" : "没有匹配的项目")
                .foregroundStyle(.secondary)
            if model.browser.searchText.isEmpty {
                Text("拖入文件，或从工具栏上传。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("选取文件…") { showFileImporter = true }
                        .buttonStyle(.borderedProminent)
                    PhotosPicker(selection: $photos, maxSelectionCount: 80, matching: .images) {
                        Text("从照片选取")
                    }
                }
                .controlSize(.regular)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .contextMenu { backgroundMenu(modelRef) }
        .overlay { backgroundMenuOverlay(modelRef).allowsHitTesting(false) }
    }

    private var grid: some View {
        let modelRef = model
        let selected = modelRef.browser.selectedKeys
        let _ = modelRef.browser.selectionEpoch
        return GeometryReader { geo in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                        .contentShape(Rectangle())
                        .contextMenu { backgroundMenu(modelRef) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 8)], spacing: 12) {
                    ForEach(modelRef.browser.visibleFolders) { folder in
                        FolderCell(
                            folder: folder,
                            selected: selected.contains(folder.prefix),
                            dropTargeted: modelRef.browser.activeDropPrefix == folder.prefix,
                            renameSession: renameSession(modelRef: modelRef, for: folder.prefix),
                            renameText: renameTextBinding(modelRef: modelRef),
                            onRenameCommit: { commitRename(with: modelRef) },
                            onRenameCancel: { modelRef.browser.cancelRenaming() }
                        )
                        .contentShape(Rectangle())
                        .contextMenu {
                            folderMenu(modelRef, folder: folder)
                        }
                        .modifier(BrowserFolderDropModifier(
                            folder: folder,
                            onUpload: { urls, prefix in
                                modelRef.upload(urls: urls, to: prefix, applyTemplate: prefix.isEmpty)
                            },
                            onMoveCloudItems: { payload, prefix in
                                modelRef.moveCloudItems(payload, to: prefix)
                            },
                            onSetDropTarget: { prefix, active in
                                modelRef.browser.setDropTarget(prefix, active: active)
                            }
                        ))
                        .onDrag {
                            modelRef.finderItemProvider(clickedKey: folder.prefix)
                        } preview: {
                            dragPreview(name: folder.name, symbol: "folder.fill")
                        }
                    }
                    ForEach(modelRef.browser.visibleObjects) { object in
                        AssetCell(
                            object: object,
                            selected: selected.contains(object.key),
                            renameSession: renameSession(modelRef: modelRef, for: object.key),
                            renameText: renameTextBinding(modelRef: modelRef),
                            onRenameCommit: { commitRename(with: modelRef) },
                            onRenameCancel: { modelRef.browser.cancelRenaming() },
                            loadClient: { modelRef.makeClient() }
                        )
                        .contentShape(Rectangle())
                        .contextMenu {
                            objectMenu(modelRef, object: object)
                        }
                        .onDrag {
                            modelRef.finderItemProvider(clickedKey: object.key)
                        } preview: {
                            dragPreview(name: object.name, symbol: object.isImage ? "photo" : "doc")
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .contentMargins(.all, 0, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay { backgroundMenuOverlay(modelRef).allowsHitTesting(false) }
    }

    private var table: some View {
        // Cell content is rendered by the AppKit table in its own hosting
        // context; capture the model reference up front and never touch
        // @Environment inside the cell closures.
        let modelRef = model
        return Table(of: BrowserRow.self, selection: tableSelection(modelRef)) {
            TableColumn("名称") { row in
                let renameSession = modelRef.browser.renameSession.flatMap {
                    $0.key == row.id ? $0 : nil
                }
                HStack(spacing: 6) {
                    if row.isFolder {
                        FinderFolderIcon(size: 16)
                    } else if let object = row.object, object.isImage {
                        ThumbnailView(object: object, style: .row, loadClient: { modelRef.makeClient() })
                            .frame(width: 18, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    } else if let object = row.object {
                        FinderFileIcon(key: object.key, size: 16)
                    } else {
                        Image(systemName: row.symbol)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                    }
                    if let renameSession {
                        FinderRenameField(
                            text: Binding(
                                get: { modelRef.browser.renameSession?.draft ?? "" },
                                set: { modelRef.browser.updateRenameDraft($0) }
                            ),
                            initialSelection: renameSession.initialSelection,
                            alignment: .left,
                            isCommitting: renameSession.isCommitting,
                            onCommit: { commitRename(with: modelRef) },
                            onCancel: { modelRef.browser.cancelRenaming() }
                        )
                        .frame(maxWidth: .infinity, minHeight: 20)
                    } else {
                        Text(row.name)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityIdentifier("ossuno.browser.item")
                .onDrag {
                    modelRef.finderItemProvider(clickedKey: row.id)
                } preview: {
                    dragPreview(name: row.name, symbol: row.symbol)
                }
                .modifier(BrowserFolderDropModifier(
                    folder: row.folder,
                    onUpload: { urls, prefix in
                        modelRef.upload(urls: urls, to: prefix, applyTemplate: prefix.isEmpty)
                    },
                    onMoveCloudItems: { payload, prefix in
                        modelRef.moveCloudItems(payload, to: prefix)
                    },
                    onSetDropTarget: { prefix, active in
                        modelRef.browser.setDropTarget(prefix, active: active)
                    }
                ))
            }
            TableColumn("大小") { row in
                Text(row.sizeLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(80)
            TableColumn("种类") { row in
                Text(row.kind)
                    .foregroundStyle(.secondary)
            }
            .width(90)
            TableColumn("修改时间") { row in
                Text(row.date)
                    .foregroundStyle(.secondary)
            }
            .width(160)
        } rows: {
            ForEach(tableRows) { row in
                TableRow(row)
                    .contextMenu {
                        if let object = row.object {
                            objectMenu(modelRef, object: object)
                        } else if let folder = row.folder {
                            folderMenu(modelRef, folder: folder)
                        }
                    }
            }
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.enabled)
        .overlay { backgroundMenuOverlay(modelRef).allowsHitTesting(false) }
    }

    private var tableRows: [BrowserRow] {
        model.browser.visibleFolders.map(BrowserRow.init) + model.browser.visibleObjects.map(BrowserRow.init)
    }

    private func tableSelection(_ modelRef: AppModel) -> Binding<Set<BrowserRow.ID>> {
        Binding(
            get: { modelRef.browser.selectedKeys },
            set: { modelRef.browser.replaceSelection($0) }
        )
    }

    private func dropScrim(title: String) -> some View {
        Rectangle()
            .fill(Color.accentColor.opacity(0.08))
            .overlay {
                Text(title)
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.bar, in: Capsule())
            }
            .allowsHitTesting(false)
    }

    private func backgroundMenuOverlay(_ modelRef: AppModel) -> BrowserBackgroundMenuOverlay {
        BrowserBackgroundMenuOverlay(
            actions: .live(
                model: modelRef,
                kind: .folderListing,
                showFileImporter: { showFileImporter = true }
            )
        )
    }

    @ViewBuilder
    private func backgroundMenu(_ modelRef: AppModel) -> some View {
        Button(modelRef.pasteMenuTitle) { modelRef.paste() }
            .disabled(!modelRef.canPaste)
        Divider()
        Button("上传") { showFileImporter = true }
        Button("从剪贴板上传") { modelRef.pasteFromClipboard() }
        Button("新建文件夹") { modelRef.wantsNewFolder = true }
        Divider()
        Button("下载当前文件夹") { modelRef.downloadCurrentPrefix() }
        Button("刷新") { Task { await modelRef.refreshListing() } }
        Divider()
        Button("全选") { modelRef.selectAllVisible() }
        if !modelRef.browser.selectedKeys.isEmpty {
            Button("取消选择") { modelRef.clearVisibleSelection() }
        }
    }

    @ViewBuilder
    private func folderMenu(_ modelRef: AppModel, folder: OSSFolder) -> some View {
        Button("打开") {
            modelRef.openFolder(folder)
        }
        .onAppear { modelRef.selectForContextMenu(folder.prefix) }
        Button(modelRef.deleteMenuTitle(clickedKey: folder.prefix), role: .destructive) {
            modelRef.requestDeleteSelection(
                keys: modelRef.menuActionKeys(clickedKey: folder.prefix),
                deferConfirmation: true
            )
        }
        .disabled(modelRef.isOrganizingCloud)
        Divider()
        Button(modelRef.isFavorite(prefix: folder.prefix) ? "从常用中移除" : "添加到常用") {
            modelRef.toggleFavorite(prefix: folder.prefix, name: folder.name)
        }
        Button(modelRef.downloadMenuTitle(clickedKey: folder.prefix)) {
            modelRef.selectForContextMenu(folder.prefix)
            modelRef.downloadSelection()
        }
        Button("复制") {
            modelRef.selectForContextMenu(folder.prefix)
            modelRef.copyCloudSelection(clickedKey: folder.prefix)
        }
        Button("剪切") {
            modelRef.selectForContextMenu(folder.prefix)
            modelRef.cutCloudSelection(clickedKey: folder.prefix)
        }
        Button(modelRef.pasteIntoFolderTitle) {
            modelRef.paste(into: folder.prefix)
        }
        .disabled(!modelRef.canPaste)
        Button("重命名") {
            modelRef.requestRename(key: folder.prefix)
        }
        .disabled(modelRef.isOrganizingCloud)
    }

    @ViewBuilder
    private func objectMenu(_ modelRef: AppModel, object: OSSObject) -> some View {
        BrowserObjectContextMenu(model: modelRef, object: object)
    }

    private func renameTextBinding(modelRef: AppModel) -> Binding<String> {
        Binding(
            get: { modelRef.browser.renameSession?.draft ?? "" },
            set: { modelRef.browser.updateRenameDraft($0) }
        )
    }

    private func renameSession(modelRef: AppModel, for key: String) -> BrowserRenameSession? {
        guard modelRef.browser.renameSession?.key == key else { return nil }
        return modelRef.browser.renameSession
    }

    private func commitRename(with modelRef: AppModel) {
        guard let session = modelRef.browser.renameSession,
              !session.isCommitting
        else { return }
        modelRef.browser.setRenameCommitting(true)
        Task { @MainActor in
            let succeeded: Bool
            switch session.kind {
            case .object:
                guard let object = modelRef.browser.objects.first(where: { $0.key == session.key }) else {
                    modelRef.browser.finishRenaming()
                    return
                }
                succeeded = await modelRef.rename(object, to: session.draft)
            case .folder:
                guard let folder = modelRef.browser.folders.first(where: { $0.prefix == session.key }) else {
                    modelRef.browser.finishRenaming()
                    return
                }
                succeeded = await modelRef.renameFolder(folder, to: session.draft)
            }
            if succeeded {
                modelRef.browser.finishRenaming()
            } else {
                modelRef.browser.setRenameCommitting(false)
            }
        }
    }

    private func dragPreview(name: String, symbol: String) -> some View {
        Label(name, systemImage: symbol)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.bar, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func importPhotos(_ modelRef: AppModel, items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        var urls: [URL] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                let url = FileManager.default.temporaryDirectory.appending(path: "photo-\(UUID().uuidString).\(ext)")
                try? data.write(to: url)
                urls.append(url)
            }
        }
        photos = []
        if !urls.isEmpty {
            modelRef.upload(urls: urls, ownedTemporaryURLs: Set(urls))
        }
    }
}

private struct BucketSearchRequest: Hashable {
    var accountID: UUID?
    var bucketName: String?
    var text: String
    var scope: BucketSearchScope
    var filter: BucketSearchFilter
}

private struct PathBar: View {
    @Environment(AppModel.self) private var model
    @Binding var showFileImporter: Bool

    var body: some View {
        let crumbs = model.selectedBucket.map { PathTemplate.crumbs(bucket: $0.name, prefix: model.browser.prefix) } ?? []
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.compact.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        Button {
                            if crumb.prefix != model.browser.prefix {
                                model.goToPrefix(crumb.prefix)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if index == 0 {
                                    Image(systemName: "externaldrive")
                                        .font(.caption)
                                } else {
                                    Image(nsImage: SystemIcons.folderSmall)
                                        .resizable()
                                        .frame(width: 13, height: 13)
                                }
                                Text(crumb.title)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(index == crumbs.count - 1 ? .primary : .secondary)
                        .background {
                            if model.browser.activeDropPrefix == crumb.prefix, crumb.prefix != model.browser.prefix {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.2))
                            }
                        }
                        .contextMenu {
                            pathMenu(prefix: crumb.prefix, isCurrent: crumb.prefix == model.browser.prefix)
                        }
                        .dropDestination(for: URL.self) { urls, _ in
                            model.upload(urls: urls, to: crumb.prefix, applyTemplate: crumb.prefix.isEmpty)
                            return true
                        } isTargeted: { targeted in
                            model.browser.setDropTarget(crumb.prefix, active: targeted)
                        }
                        .dropDestination(for: CloudDragPayload.self) { payloads, _ in
                            guard let payload = payloads.first else { return false }
                            model.moveCloudItems(payload, to: crumb.prefix)
                            return true
                        } isTargeted: { targeted in
                            model.browser.setDropTarget(crumb.prefix, active: targeted)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.browser.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .help("正在刷新")
            } else {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .frame(height: FinderChrome.barHeight)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
        .contextMenu {
            pathMenu(prefix: model.browser.prefix, isCurrent: true)
        }
    }

    private var statusText: String {
        if model.isBucketSearchActive {
            let progress = model.searchController.progress
            return model.searchController.isSearching
                ? "已扫描 \(progress.scanned) 项"
                : "找到 \(progress.matched) 项"
        }
        let selected = model.browser.selectedKeys.count
        if selected > 0 { return "已选 \(selected) 项" }
        let visible = model.browser.visibleFolders.count + model.browser.visibleObjects.count
        let query = model.browser.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? "\(visible) 项" : "找到 \(visible) 项"
    }

    @ViewBuilder
    private func pathMenu(prefix: String, isCurrent: Bool) -> some View {
        Button(model.pasteMenuTitle) {
            model.paste(into: prefix)
        }
        .disabled(!model.canPaste)
        Divider()
        Button("复制路径") {
            model.copyFolderPath(prefix, includeBucket: false)
        }
        Button("复制完整路径") {
            model.copyFolderPath(prefix, includeBucket: true)
        }
        Button("复制链接") {
            model.copyFolderURL(prefix)
        }
        Divider()
        if !isCurrent {
            Button("转到此处") {
                model.goToPrefix(prefix)
            }
        }
        Button("上传到此处") {
            if !isCurrent {
                model.goToPrefix(prefix)
            }
            showFileImporter = true
        }
        Button("在此处新建文件夹") {
            if !isCurrent {
                model.goToPrefix(prefix)
            }
            model.wantsNewFolder = true
        }
        Button("下载此文件夹") {
            if isCurrent {
                model.downloadCurrentPrefix()
            } else {
                model.downloadFolder(OSSFolder(prefix: prefix))
            }
        }
    }
}


private struct BrowserFolderDropModifier: ViewModifier {
    var folder: OSSFolder?
    var onUpload: ([URL], String) -> Void
    var onMoveCloudItems: (CloudDragPayload, String) -> Void
    var onSetDropTarget: (String, Bool) -> Void

    func body(content: Content) -> some View {
        if let folder {
            content
                .dropDestination(for: URL.self) { urls, _ in
                    onUpload(urls, folder.prefix)
                    return true
                } isTargeted: { targeted in
                    onSetDropTarget(folder.prefix, targeted)
                }
                .dropDestination(for: CloudDragPayload.self) { payloads, _ in
                    guard let payload = payloads.first else { return false }
                    onMoveCloudItems(payload, folder.prefix)
                    return true
                } isTargeted: { targeted in
                    onSetDropTarget(folder.prefix, targeted)
                }
        } else {
            content
        }
    }
}

private struct FolderCell: View {
    let folder: OSSFolder
    var selected: Bool
    var dropTargeted: Bool
    var renameSession: BrowserRenameSession?
    @Binding var renameText: String
    var onRenameCommit: () -> Void
    var onRenameCancel: () -> Void

    var body: some View {
        let highlighted = selected || dropTargeted
        ZStack(alignment: .bottom) {
            VStack(spacing: 4) {
                FinderFolderIcon(size: 64)
                    .padding(8)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(highlighted ? Color.accentColor.opacity(dropTargeted ? 0.4 : 0.3) : Color.clear)
                    }
                    .overlay {
                        if dropTargeted {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 2)
                        }
                    }

                Text(folder.name)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(highlighted ? Color.accentColor : Color.clear)
                    }
                    .foregroundStyle(highlighted ? Color.white : Color.primary)
                    .opacity(renameSession == nil ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())

            if let renameSession {
                FinderRenameField(
                    text: $renameText,
                    initialSelection: renameSession.initialSelection,
                    alignment: .center,
                    isCommitting: renameSession.isCommitting,
                    onCommit: onRenameCommit,
                    onCancel: onRenameCancel
                )
                .frame(height: 20)
                .padding(.horizontal, 3)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .help(folder.name)
        .overlay {
            BrowserItemMarker(id: "ossuno.folder:\(folder.prefix)")
                .allowsHitTesting(false)
        }
        .accessibilityIdentifier("ossuno.browser.item")
        .accessibilityLabel("文件夹，\(folder.name)")
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityHint("双击打开")
    }
}

private struct AssetCell: View {
    let object: OSSObject
    var selected: Bool
    var renameSession: BrowserRenameSession?
    @Binding var renameText: String
    var onRenameCommit: () -> Void
    var onRenameCancel: () -> Void
    var loadClient: () -> OSSClient?

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 4) {
                ThumbnailView(object: object, loadClient: loadClient)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3)
                    }
                    .clipped()
                Text(object.name)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .frame(maxWidth: .infinity)
                    .opacity(renameSession == nil ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())

            if let renameSession {
                FinderRenameField(
                    text: $renameText,
                    initialSelection: renameSession.initialSelection,
                    alignment: .center,
                    isCommitting: renameSession.isCommitting,
                    onCommit: onRenameCommit,
                    onCancel: onRenameCancel
                )
                .frame(height: 20)
                .padding(.horizontal, 3)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .help(object.name)
        .overlay {
            BrowserItemMarker(id: "ossuno.file:\(object.key)")
                .allowsHitTesting(false)
        }
        .accessibilityIdentifier("ossuno.browser.item")
        .accessibilityLabel("\(ImageKind.displayKind(for: object.key))，\(object.name)")
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityHint("双击快速查看")
    }
}

private struct BrowserRow: Identifiable, Hashable {
    var id: String
    var name: String
    var symbol: String
    var sizeLabel: String
    var kind: String
    var date: String
    var isFolder: Bool
    var object: OSSObject?
    var folder: OSSFolder?

    init(_ folder: OSSFolder) {
        self.id = folder.prefix
        self.name = folder.name
        self.symbol = "folder.fill"
        self.sizeLabel = "—"
        self.kind = "文件夹"
        self.date = "—"
        self.isFolder = true
        self.folder = folder
    }

    init(_ object: OSSObject) {
        self.id = object.key
        self.name = object.name
        self.symbol = object.isImage ? "photo" : "doc"
        self.sizeLabel = Formatters.bytes(object.size)
        self.kind = ImageKind.displayKind(for: object.key)
        self.date = Formatters.date(object.lastModified)
        self.isFolder = false
        self.object = object
    }
}
