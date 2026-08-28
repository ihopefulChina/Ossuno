import AppKit
import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("信息")
                        .font(.title2.weight(.semibold))
                    Text(contextTitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            informationContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()

            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(
            minWidth: 460,
            idealWidth: 460,
            maxWidth: 460,
            minHeight: 440,
            idealHeight: 560,
            maxHeight: 680
        )
    }

    @ViewBuilder
    private var informationContent: some View {
        switch model.inspectorSurface {
        case .multiple(_, let folderCount, let objects):
            selectionInfo(folderCount: folderCount, objects: objects)
        case .object(let object):
            objectInfo(object)
        case .folder:
            folderInfo
        case .searchEmpty:
            ContentUnavailableView(
                "没有可显示的信息",
                systemImage: "magnifyingglass",
                description: Text("在搜索结果中选择一个项目。")
            )
        case .unavailable:
            ContentUnavailableView(
                "没有可显示的信息",
                systemImage: "info.circle",
                description: Text("先选择一个存储空间。")
            )
        }
    }

    private var contextTitle: String {
        switch model.inspectorSurface {
        case .multiple(let count, _, _):
            return "已选择 \(count) 项"
        case .object(let object):
            return object.name
        case .searchEmpty:
            return "搜索结果"
        case .folder:
            if !model.browser.prefix.isEmpty {
                return PathTemplate.lastComponent(model.browser.prefix)
            }
            return model.selectedBucket?.name ?? "当前项目"
        case .unavailable:
            return "当前项目"
        }
    }

    private func selectionInfo(folderCount: Int, objects: [OSSObject]) -> some View {
        let bytes = objects.reduce(Int64(0)) { $0 + $1.size }

        return VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 44, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)

            Text("已选择 \(folderCount + objects.count) 项")
                .font(.title3.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                if folderCount > 0 { infoRow("文件夹", "\(folderCount)") }
                if !objects.isEmpty { infoRow("文件", "\(objects.count)") }
                if bytes > 0 { infoRow("文件大小", Formatters.bytes(bytes)) }
            }
            .font(.callout)

            HStack(spacing: 8) {
                Button("下载") { model.downloadSelection() }
                Spacer()
                Button("删除", role: .destructive) { model.requestDeleteSelection() }
                    .disabled(model.isOrganizingCloud)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func objectInfo(_ object: OSSObject) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if object.isText, let text = model.inspectorText {
                    ScrollView {
                        Text(text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    ThumbnailView(object: object, style: .inspector, loadClient: { model.makeClient() })
                        .frame(height: object.isImage ? 168 : 96)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .clipped()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(object.name)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    Text(object.key)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    infoRow("大小", Formatters.bytes(object.size))
                    infoRow("种类", ImageKind.displayKind(for: object.key))
                    infoRow("修改", Formatters.date(object.lastModified))
                    if let head = model.inspectorHead {
                        if let type = head.contentType { infoRow("类型", type) }
                        if let acl = head.acl { infoRow("权限", acl) }
                        if let storage = head.storageClass { infoRow("存储", storage) }
                    }
                }
                .font(.callout)

                if let account = model.selectedAccount,
                   let bucket = model.selectedBucket,
                   let url = account.publicURL(bucketName: bucket.name, bucket: bucket, key: object.key) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("链接")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(url.absoluteString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(4)
                        HStack {
                            Button("复制链接") { model.copyURLs(style: .plain) }
                            Button("Markdown") { model.copyURLs(style: .markdown) }
                        }
                        .controlSize(.small)
                    }
                }

                HStack(spacing: 8) {
                    Button("快速查看") {
                        Task { await model.quickLookSelection() }
                    }
                    Button("下载") {
                        model.downloadSelection()
                    }
                    Spacer()
                    Button("删除", role: .destructive) {
                        model.requestDeleteSelection()
                    }
                    .disabled(model.isOrganizingCloud)
                    .tint(.red)
                }
                .controlSize(.regular)
            }
            .padding(20)
        }
    }

    private var folderInfo: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 48, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            Text(model.browser.prefix.isEmpty ? (model.selectedBucket?.name ?? "存储空间") : PathTemplate.lastComponent(model.browser.prefix))
                .font(.title3.weight(.semibold))
            Text(model.browser.prefix.isEmpty ? "/" : "/" + model.browser.prefix)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                infoRow("文件夹", "\(model.browser.folders.count)")
                infoRow("对象", "\(model.browser.objects.count)")
                if let region = model.selectedBucket?.regionLabel {
                    infoRow("地域", region)
                }
            }
            .font(.callout)
            Text("把图片、JSON 或文本拖进窗口，就会上传到这里。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Button("下载当前文件夹") {
                model.downloadCurrentPrefix()
            }
            .controlSize(.regular)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
