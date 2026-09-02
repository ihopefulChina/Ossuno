import SwiftUI

struct BucketSearchView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Table cells are hosted by AppKit; capture the model reference up
        // front so cell closures never read @Environment.
        let modelRef = model
        return Group {
            if let error = modelRef.searchController.errorMessage {
                VStack(spacing: 8) {
                    Text("无法完成搜索")
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                    Button("再试一次") { Task { await modelRef.runBucketSearch() } }
                        .buttonStyle(.borderless)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contextMenu { searchBackgroundMenu(modelRef) }
            } else if modelRef.searchController.results.isEmpty && !modelRef.searchController.isSearching {
                Text("没有匹配的项目")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contextMenu { searchBackgroundMenu(modelRef) }
            } else {
                resultsTable(modelRef)
                    .overlay {
                        BrowserBackgroundMenuOverlay(
                            actions: .live(
                                model: modelRef,
                                kind: .bucketSearch,
                                showFileImporter: {}
                            )
                        )
                        .allowsHitTesting(false)
                    }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func resultsTable(_ modelRef: AppModel) -> some View {
        Table(of: OSSObject.self, selection: searchSelection(modelRef)) {
            TableColumn("名称") { object in
                HStack(spacing: 6) {
                    if object.isImage {
                        ThumbnailView(object: object, style: .row, loadClient: { modelRef.makeClient() })
                            .frame(width: 18, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    } else {
                        FinderFileIcon(key: object.key, size: 16)
                    }
                    Text(object.name)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onDrag {
                    modelRef.finderItemProvider(clickedKey: object.key)
                } preview: {
                    Label(object.name, systemImage: object.isImage ? "photo" : "doc")
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.bar, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            TableColumn("位置") { object in
                Text(location(modelRef, of: object))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            TableColumn("大小") { object in
                Text(Formatters.bytes(object.size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(80)
            TableColumn("修改时间") { object in
                Text(object.lastModified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(150)
        } rows: {
            ForEach(modelRef.searchController.results) { object in
                TableRow(object)
            }
        }
    }

    private func searchSelection(_ modelRef: AppModel) -> Binding<Set<String>> {
        Binding(
            get: { modelRef.searchSelectedKeys },
            set: { modelRef.selectSearchKeys($0) }
        )
    }

    @ViewBuilder
    private func searchBackgroundMenu(_ modelRef: AppModel) -> some View {
        Button("全选") { modelRef.selectAllVisible() }
        if !modelRef.searchSelectedKeys.isEmpty {
            Button("取消选择") { modelRef.clearVisibleSelection() }
        }
        Divider()
        Button("再试一次") { Task { await modelRef.runBucketSearch() } }
    }

    private func location(_ modelRef: AppModel, of object: OSSObject) -> String {
        let prefix = PathTemplate.parentPrefix(object.key)
        return prefix.isEmpty ? (modelRef.selectedBucketName ?? "/") : prefix
    }
}

struct BucketSearchFilterMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Menu content can be rendered in a separate hosting context; use the
        // resolved reference instead of the environment.
        let modelRef = model
        Menu {
            Section("类型") {
                ForEach(BucketSearchKind.allCases) { kind in
                    Button {
                        modelRef.searchFilter.kind = kind
                    } label: {
                        if modelRef.searchFilter.kind == kind {
                            Label(kind.title, systemImage: "checkmark")
                        } else {
                            Text(kind.title)
                        }
                    }
                }
            }
            Section("大小") {
                filterButton(modelRef, "任意大小", minimum: nil, maximum: nil)
                filterButton(modelRef, "至少 10 MB", minimum: 10 * 1_024 * 1_024, maximum: nil)
                filterButton(modelRef, "至少 100 MB", minimum: 100 * 1_024 * 1_024, maximum: nil)
                filterButton(modelRef, "不超过 1 MB", minimum: nil, maximum: 1 * 1_024 * 1_024)
            }
            Section("修改时间") {
                dateButton(modelRef, "任意时间", range: .any)
                dateButton(modelRef, "最近 24 小时", range: .lastDays(1))
                dateButton(modelRef, "最近 7 天", range: .lastDays(7))
                dateButton(modelRef, "最近 30 天", range: .lastDays(30))
            }
            if modelRef.searchFilter != .all {
                Divider()
                Button("清除筛选") { modelRef.searchFilter = .all }
            }
        } label: {
            Label("筛选", systemImage: modelRef.searchFilter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("筛选搜索结果")
    }

    private func filterButton(
        _ modelRef: AppModel,
        _ title: String,
        minimum: Int64?,
        maximum: Int64?
    ) -> some View {
        Button {
            modelRef.searchFilter.minimumSize = minimum
            modelRef.searchFilter.maximumSize = maximum
        } label: {
            if modelRef.searchFilter.minimumSize == minimum,
               modelRef.searchFilter.maximumSize == maximum {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func dateButton(
        _ modelRef: AppModel,
        _ title: String,
        range: BucketSearchDateRange
    ) -> some View {
        Button {
            modelRef.searchFilter.modified = range
        } label: {
            if modelRef.searchFilter.modified == range {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}
