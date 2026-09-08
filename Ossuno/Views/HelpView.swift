import AppKit
import SwiftUI

struct HelpView: View {
    @State private var topic: HelpTopic? = .gettingStarted
    @State private var copied = false

    var body: some View {
        NavigationSplitView {
            List(HelpTopic.allCases, selection: $topic) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationTitle("Ossuno 帮助")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    let selected = topic ?? .gettingStarted
                    Text("ossuno / help / \(selected.path)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(selected.title)
                        .font(.title.weight(.semibold))
                    topicContent(selected)
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(32)
                .textSelection(.enabled)
            }
            .navigationTitle(topic?.title ?? "Ossuno 帮助")
            .toolbar {
                ToolbarItem {
                    Button {
                        copyDiagnostics()
                    } label: {
                        Label(copied ? "已复制" : "复制诊断信息", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .help("复制不含账号、Bucket、对象路径或密钥的诊断摘要")
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    @ViewBuilder
    private func topicContent(_ topic: HelpTopic) -> some View {
        switch topic {
        case .gettingStarted:
            helpSection("连接 OSS") {
                Text("先在阿里云创建只允许访问所需 Bucket 的 RAM 用户，再把 AccessKey ID 与 Secret 添加到 Ossuno。新账号默认继承存储空间权限；改为公共读或公共读写前会再次确认。密钥只保存在这台 Mac 的钥匙串中。")
                Text("建议从只读或单 Bucket 读写权限开始，需要上传、删除或移动时再补充对应权限。不要使用主账号 AccessKey。")
            }
            helpSection("像访达一样浏览") {
                Text("单击选择，双击打开文件夹或预览文件。按住 Command 多选，Shift 连续选择；Return 重命名，空格快速查看，Command–1 / Command–2 切换网格与列表。")
                Text("搜索栏可切换“当前文件夹”和“当前 Bucket”。Bucket 搜索会显示扫描进度，可按类型、大小和修改日期筛选，也可随时停止。")
                Text("把云端文件或文件夹直接拖到访达，Ossuno 会在放下后安全下载；多选会放进“Ossuno 下载”文件夹。")
            }
        case .transfers:
            helpSection("暂停、继续与恢复") {
                Text("从“传输 › 打开传输中心”查看完整队列。大文件上传会保存已完成分片，下载会保存已完成字节范围；暂停或重新打开 Ossuno 后可从检查点继续。取消会清理对应临时数据。")
                Text("若原文件、下载目录权限或云端对象状态已经变化，Ossuno 会保留记录并说明为何不能继续。")
            }
            helpSection("同名项目") {
                Text("可在设置中选择每次询问、替换、跳过或保留两者。保留两者会像访达一样生成带编号的名称；下载不会静默覆盖本地文件。")
            }
        case .recovery:
            helpSection("撤销云端整理") {
                Text("重命名和移动成功后，可以立即按 Command–Z 撤销。撤销只在原账号与原 Bucket 中生效。")
            }
            helpSection("撤销删除") {
                Text("Bucket 已开启版本控制时，刚删除的项目可以立即按 Command–Z 撤销。未开启版本控制时，删除是永久的。")
            }
            helpSection("对象属性与跨 Bucket 整理") {
                Text("“对象属性”写回 OSS 上的文件类型、缓存、下载文件名、自定义元数据和最多十个标签。保存后对这个对象立即生效；已开启版本控制的 Bucket 会因此产生一个新版本。")
                Text("剪切后切换文件夹或 Bucket 再粘贴，即可移动。复制后粘贴则留下副本。跨 Bucket 时会先显示来源、目标、数量、大小和传输方式；同账号同地域走云端复制，其他情况经由这台 Mac。移动总是在全部复制成功后才删除来源。")
            }
            helpSection("账号配置恢复") {
                Text("Ossuno 会为可读取的账号配置保留上一份备份。主配置损坏时会自动恢复并保留损坏文件；若备份也不可读，请复制诊断信息并通过支持入口反馈。诊断信息不包含账号标识或密钥。")
            }
        case .updates:
            helpSection("自动更新") {
                Text("Ossuno 使用 Sparkle 检查 GitHub Releases。发现新版本后可以直接安装，安装完成会退出并重新打开应用。自动检查可在“设置 › 通用”关闭。")
                Link("查看发布记录", destination: AppLinks.releases)
            }
        case .shortcuts:
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                shortcut("Command–N", "新建窗口")
                shortcut("Command–O", "上传")
                shortcut("Command–X", "剪切，再粘贴即可移动")
                shortcut("Command–C", "复制选中的对象或文件夹")
                shortcut("Command–V", "粘贴；剪切后粘贴为移动")
                shortcut("Shift–Command–A", "添加账号")
                shortcut("Shift–Command–V", "从剪贴板上传")
                shortcut("Shift–Command–N", "新建文件夹")
                shortcut("Option–Command–L", "打开传输中心")
                shortcut("Command–Z", "撤销上一步可恢复的云端操作")
                shortcut("Command–1 / Command–2", "网格 / 列表")
                shortcut("Command–[ / Command–]", "后退 / 前进")
                shortcut("Command–R", "刷新")
                shortcut("Space", "快速查看")
                shortcut("Return", "重命名")
            }
        case .privacyAndSupport:
            helpSection("隐私") {
                Text("AccessKey Secret 与 STS Token 存在 macOS 钥匙串；账号偏好和传输历史保存在本机。诊断摘要不会包含账号名、AccessKey ID、Bucket、对象键、本地路径、URL、请求 ID、Secret 或 Token。")
                Link("阅读隐私说明", destination: AppLinks.privacy)
            }
            helpSection("获得支持") {
                Link("支持与常见问题", destination: AppLinks.support)
                Link("问题与功能建议", destination: AppLinks.issues)
                Link("安全政策", destination: AppLinks.security)
                Link("私密报告安全问题", destination: AppLinks.privateSecurityReport)
                Link("Ossuno 官网", destination: AppLinks.website)
            }
        }
    }

    private func helpSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
                .font(.body)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
        }
    }

    private func shortcut(_ keys: String, _ action: String) -> some View {
        GridRow {
            Text(keys)
                .font(.body.monospaced())
                .foregroundStyle(.primary)
            Text(action)
                .foregroundStyle(.secondary)
        }
    }

    private func copyDiagnostics() {
        let report = DiagnosticsReport.make()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

private enum HelpTopic: String, CaseIterable, Identifiable {
    case gettingStarted
    case transfers
    case recovery
    case updates
    case shortcuts
    case privacyAndSupport

    var id: String { rawValue }
    var path: String { rawValue }

    var title: String {
        switch self {
        case .gettingStarted: "开始使用"
        case .transfers: "传输与冲突"
        case .recovery: "撤销与恢复"
        case .updates: "软件更新"
        case .shortcuts: "键盘快捷键"
        case .privacyAndSupport: "隐私与支持"
        }
    }

    var symbol: String {
        switch self {
        case .gettingStarted: "sparkles"
        case .transfers: "arrow.up.arrow.down"
        case .recovery: "arrow.uturn.backward.circle"
        case .updates: "arrow.triangle.2.circlepath"
        case .shortcuts: "command"
        case .privacyAndSupport: "lock.shield"
        }
    }
}
