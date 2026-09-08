import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var accountChecks: [OSSAccount.ID: AccountCheckState] = [:]
    @State private var accountToDelete: OSSAccount?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        TabView {
            generalSettings
                .tabItem { Label("通用", systemImage: "gear") }

            transferSettings
                .tabItem { Label("传输", systemImage: "arrow.up.arrow.down") }

            accountSettings
                .tabItem { Label("账号", systemImage: "person.crop.circle") }
        }
        .padding(8)
        .sheet(isPresented: $model.showAccountSheet) {
            AccountSheet(draft: AccountSheet.initialDraft(editing: model.editingAccount))
                .environment(model)
        }
        .confirmationDialog(
            "删除账号“\(accountToDelete?.displayName ?? "")”？",
            isPresented: Binding(
                get: { accountToDelete != nil },
                set: { if !$0 { accountToDelete = nil } }
            )
        ) {
            Button("删除", role: .destructive) {
                if let accountToDelete {
                    model.deleteAccount(accountToDelete)
                    accountChecks[accountToDelete.id] = nil
                }
                accountToDelete = nil
            }
            Button("取消", role: .cancel) { accountToDelete = nil }
        } message: {
            Text("账号配置和这台 Mac 钥匙串中的对应密钥会被移除，OSS 中的文件不会受到影响。")
        }
    }

    private var generalSettings: some View {
        @Bindable var model = model
        return Form {
            Section("浏览") {
                Picker("外观", selection: $model.settings.appearance) {
                    ForEach(AppAppearance.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Picker("默认视图", selection: Binding(
                    get: { model.settings.preferredViewMode },
                    set: { model.applyPreferredViewModeToAllSessions($0) }
                )) {
                    ForEach(BrowserViewMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("浏览时只显示素材文件", isOn: $model.settings.imagesOnly)
                    .onChange(of: model.settings.imagesOnly) { _, value in
                        for session in AppServices.shared.sessions {
                            session.browser.imagesOnly = value
                        }
                    }
                Text("默认显示 OSS 中的所有对象。开启后仅收窄浏览列表，不会限制上传的文件类型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("更新") {
                LabeledContent("当前版本", value: AppVersion.current)
                Toggle("自动检查更新", isOn: Binding(
                    get: { model.settings.checkUpdatesAutomatically },
                    set: { enabled in
                        model.settings.checkUpdatesAutomatically = enabled
                        model.updates.automaticallyChecksForUpdates = enabled
                    }
                ))
                Button("检查更新…") {
                    model.updates.checkForUpdates()
                }
                .disabled(!model.updates.canCheckForUpdates)
                Text("新版本安装完成后，Ossuno 会自动重新打开。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("关于") {
                Text("把阿里云 OSS 变成一扇更像访达的窗口。密钥只保存在这台 Mac 上。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Link("Ossuno 官网", destination: AppLinks.website)
                Link("GitHub 仓库", destination: AppLinks.github)
                Link("问题与反馈", destination: AppLinks.issues)
            }
        }
        .formStyle(.grouped)
    }

    private var transferSettings: some View {
        @Bindable var model = model
        return Form {
            Section("上传") {
                Stepper(value: $model.settings.concurrentUploads, in: 1...6) {
                    Text("同时上传 \(model.settings.concurrentUploads) 个文件")
                }
                .onChange(of: model.settings.concurrentUploads) { _, value in
                    model.transfers.concurrency = value
                }
                Picker("上传速度", selection: $model.settings.uploadSpeedLimit) {
                    ForEach(Self.speedLimits, id: \.self) { limit in
                        Text(limit.title).tag(limit)
                    }
                }
                .onChange(of: model.settings.uploadSpeedLimit) { _, value in
                    model.transfers.uploadSpeedLimit = value
                }
                Toggle("将 HEIC 转为 JPEG", isOn: $model.settings.convertHEIC)
                Text("转换会生成有损 JPEG，可能丢失 HDR、实况图和元数据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("下载") {
                Stepper(value: $model.settings.concurrentDownloads, in: 1...6) {
                    Text("同时下载 \(model.settings.concurrentDownloads) 个文件")
                }
                .onChange(of: model.settings.concurrentDownloads) { _, value in
                    model.transfers.downloadConcurrency = value
                }
                Picker("下载速度", selection: $model.settings.downloadSpeedLimit) {
                    ForEach(Self.speedLimits, id: \.self) { limit in
                        Text(limit.title).tag(limit)
                    }
                }
                .onChange(of: model.settings.downloadSpeedLimit) { _, value in
                    model.transfers.downloadSpeedLimit = value
                }
                Picker("默认位置", selection: $model.settings.downloadLocation) {
                    ForEach(DownloadLocation.allCases) { location in
                        Text(location.title).tag(location)
                    }
                }
            }

            Section("同名文件") {
                Picker("处理方式", selection: $model.settings.transferConflictPolicy) {
                    ForEach(TransferConflictPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                Text("“保留两者”会像访达一样自动添加 2、3 等编号。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("进行传输时") {
                Toggle("传输完成时播放提示音", isOn: $model.settings.playCompleteSound)
                Toggle("在菜单栏显示传输状态", isOn: $model.settings.showMenuBarWhileTransferring)
                    .onChange(of: model.settings.showMenuBarWhileTransferring) { _, enabled in
                        model.showMenuBarExtra = enabled && model.transfers.activeCount > 0
                    }
                Toggle("全部完成时显示通知", isOn: Binding(
                    get: { model.settings.notifyWhenTransfersFinish },
                    set: { enabled in
                        if enabled {
                            requestNotificationPermission()
                        } else {
                            model.settings.notifyWhenTransfersFinish = false
                        }
                    }
                ))
            }

            Section {
                Button("打开传输中心") { openWindow(id: "transfers") }
            }

            Section("历史记录") {
                LabeledContent("已结束的传输", value: "\(finishedTransferCount) 项")
                Button("清除已结束的记录", role: .destructive) {
                    model.transfers.clearFinished()
                }
                .disabled(finishedTransferCount == 0)
                Text("正在进行或已暂停的项目不会被清除。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var accountSettings: some View {
        Form {
            Section("已保存的账号") {
                if model.accounts.isEmpty {
                    Text("还没有账号")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.accounts) { account in
                        accountRow(account)
                    }
                }
            }

            Section {
                Button {
                    model.editingAccount = nil
                    model.showAccountSheet = true
                } label: {
                    Label("添加账号…", systemImage: "plus")
                }
                Text("验证连接只会读取存储空间列表，不会修改云端内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func accountRow(_ account: OSSAccount) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .lineLimit(1)
                Text("\(account.region.name) · \(account.defaultACL.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            accountCheckLabel(account)

            Button("验证") {
                check(account)
            }
            .buttonStyle(.borderless)
            .disabled(accountChecks[account.id] == .checking)

            Menu {
                Button("编辑…") {
                    model.editingAccount = account
                    model.showAccountSheet = true
                }
                Divider()
                Button("删除账号…", role: .destructive) {
                    accountToDelete = account
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("账号操作")
        }
    }

    @ViewBuilder
    private func accountCheckLabel(_ account: OSSAccount) -> some View {
        switch accountChecks[account.id] {
        case .checking:
            ProgressView()
                .controlSize(.small)
                .help("正在验证连接")
        case .success(let bucketCount):
            Label("\(bucketCount) 个", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .help("连接正常，共 \(bucketCount) 个存储空间")
        case .failed(let message):
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .help(message)
                .accessibilityLabel("连接失败：\(message)")
        case nil:
            EmptyView()
        }
    }

    private var finishedTransferCount: Int {
        model.transfers.jobs.filter(\.isFinished).count
    }

    private static let speedLimits: [TransferSpeedLimit] = [
        .unlimited,
        .megabytesPerSecond(1),
        .megabytesPerSecond(5),
        .megabytesPerSecond(10),
        .megabytesPerSecond(50),
    ]

    private func requestNotificationPermission() {
        Task {
            model.settings.notifyWhenTransfersFinish = await TransferNotifier.shared.requestAuthorization()
        }
    }

    private func check(_ account: OSSAccount) {
        accountChecks[account.id] = .checking
        Task {
            do {
                let count = try await model.testAccount(account)
                accountChecks[account.id] = .success(count)
            } catch {
                accountChecks[account.id] = .failed(error.localizedDescription)
            }
        }
    }
}

private enum AccountCheckState: Equatable {
    case checking
    case success(Int)
    case failed(String)
}
