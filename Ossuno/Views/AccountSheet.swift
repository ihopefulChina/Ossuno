import AppKit
import SwiftUI

struct AccountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State var draft: AccountDraft
    @State private var isTesting = false
    @State private var failure: AccountFormFailure?
    @State private var showAdvanced: Bool
    @State private var showSecret = false
    @State private var showToken = false
    @State private var pendingACL: ObjectACL?
    @State private var showACLConfirmation = false
    @FocusState private var focusedFailureAction: FailureAction?

    private enum FailureAction: Hashable {
        case retry
    }

    /// Editing must start with the persisted account identity before any
    /// Keychain lookup. A Keychain error must never leave an edit sheet backed
    /// by a fresh UUID, otherwise re-entering the credentials would append a
    /// duplicate account instead of updating the selected one.
    static func initialDraft(editing account: OSSAccount?) -> AccountDraft {
        guard let account else { return .fresh() }
        return .from(account, secret: "", token: "")
    }

    init(draft: AccountDraft) {
        _draft = State(initialValue: draft)
        #if DEBUG
        _showAdvanced = State(initialValue: ScreenshotDemo.accountShowsAdvanced)
        #else
        _showAdvanced = State(initialValue: false)
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            Form {
                Section {
                    TextField("显示名称", text: $draft.name, prompt: Text("工作室、主账号…"))
                    TextField("AccessKey ID", text: $draft.accessKeyId)
                        .textContentType(.username)
                    secretField(
                        title: "AccessKey Secret",
                        text: $draft.secret,
                        revealed: $showSecret,
                        showHelp: "显示密钥",
                        hideHelp: "隐藏密钥",
                        showAccessibility: "显示 AccessKey Secret",
                        hideAccessibility: "隐藏 AccessKey Secret"
                    )
                } header: {
                    Text("账号信息")
                }

                Section {
                    Picker("地域", selection: $draft.regionID) {
                        ForEach(OSSRegion.all) { region in
                            Text(region.name).tag(region.id)
                        }
                    }
                    Toggle("传输加速", isOn: $draft.useTransferAccelerate)
                    Picker("默认权限", selection: aclSelection) {
                        ForEach(commonACLs) { acl in
                            Text(acl.title).tag(acl)
                        }
                    }
                    if draft.defaultACL.isPublic {
                        Label("公开权限会允许通过公网链接读取对象，请只用于明确需要公开分发的内容。", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("权限警告：对象可通过公网链接读取")
                    }
                } header: {
                    Text("存储空间")
                } footer: {
                    Text(draft.defaultACL.detail)
                }

                Section {
                    TextField("路径模板", text: $draft.prefixTemplate, prompt: Text("assets/{yyyy}/{MM}/{dd}/"))
                } header: {
                    Text("上传")
                } footer: {
                    Text("留空则传到当前文件夹。可用 {yyyy} {MM} {dd} {filename}。")
                }

                Section {
                    DisclosureGroup(isExpanded: $showAdvanced) {
                        EmptyView()
                    } label: {
                        Text("高级")
                    }
                }

                if showAdvanced {
                    Section {
                        secretField(
                            title: "STS Token",
                            text: $draft.token,
                            revealed: $showToken,
                            showHelp: "显示 STS Token",
                            hideHelp: "隐藏 STS Token",
                            showAccessibility: "显示 STS Token",
                            hideAccessibility: "隐藏 STS Token"
                        )
                        TextField("自定义 Endpoint", text: $draft.endpointOverride, prompt: Text("oss-cn-hangzhou.aliyuncs.com"))
                        TextField("CDN 域名", text: $draft.cdnDomain, prompt: Text("cdn.example.com"))
                        Button("使用公共读写权限…", role: .destructive) {
                            proposeACL(.publicReadWrite)
                        }
                        .disabled(draft.defaultACL == .publicReadWrite)
                    }
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
            .animation(reduceMotion ? nil : Motion.chrome, value: showAdvanced)

            if let failure {
                failureFeedback(failure)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            Divider()

            HStack(spacing: 12) {
                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在验证连接…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(model.editingAccount == nil ? "连接" : "保存") {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave || isTesting)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 540, idealWidth: 560, maxWidth: 620)
        .confirmationDialog(
            pendingACL?.title ?? "确认公开权限",
            isPresented: $showACLConfirmation,
            titleVisibility: .visible
        ) {
            Button("确认使用\(pendingACL?.title ?? "公开权限")") {
                if let pendingACL {
                    draft.defaultACL = pendingACL
                }
                self.pendingACL = nil
            }
            Button("取消", role: .cancel) {
                pendingACL = nil
            }
        } message: {
            if let pendingACL {
                Text(AccountACLConfirmation.message(for: pendingACL))
            }
        }
        .task(id: model.editingAccount?.id) {
            #if DEBUG
            if let screenshotFailure = ScreenshotDemo.accountFailure {
                failure = screenshotFailure
                return
            }
            if ScreenshotDemo.accountShowsAdvanced {
                showAdvanced = true
            }
            #endif
            if let account = model.editingAccount {
                // Keep this defensive assignment even though every production
                // caller uses initialDraft(editing:). It preserves the existing
                // account ID if a future caller accidentally supplies .fresh().
                if draft.id != account.id {
                    draft = Self.initialDraft(editing: account)
                }
                do {
                    let secret = try SecretStore.read(account: AccountStore.secretAccount(account.id)) ?? ""
                    let token = try SecretStore.read(account: AccountStore.tokenAccount(account.id)) ?? ""
                    draft.secret = secret
                    draft.token = token
                } catch {
                    presentFailure(error, operation: .loadingCredentials)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: model.editingAccount == nil ? "person.crop.circle.badge.plus" : "person.crop.circle")
                .font(.system(size: 34, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.editingAccount == nil ? "添加账号" : "编辑账号")
                    .font(.title2.weight(.semibold))
                Label("密钥只保存在这台 Mac 的钥匙串中", systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var canSave: Bool {
        draft.isReadyToSave
    }

    @ViewBuilder
    private func secretField(
        title: String,
        text: Binding<String>,
        revealed: Binding<Bool>,
        showHelp: String,
        hideHelp: String,
        showAccessibility: String,
        hideAccessibility: String
    ) -> some View {
        HStack(spacing: 8) {
            Group {
                if revealed.wrappedValue {
                    TextField(title, text: text)
                } else {
                    SecureField(title, text: text)
                }
            }
            .textContentType(.password)
            .privacySensitive()
            Button {
                revealed.wrappedValue.toggle()
            } label: {
                Image(systemName: revealed.wrappedValue ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(revealed.wrappedValue ? hideHelp : showHelp)
            .accessibilityLabel(revealed.wrappedValue ? hideAccessibility : showAccessibility)
        }
    }

    private func failureFeedback(_ failure: AccountFormFailure) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text(failure.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(failure.message)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    Text(failure.recoverySuggestion)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(failure.accessibilityAnnouncement)

            HStack(spacing: 10) {
                if failure.shouldOfferKeychainAccess,
                   NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess") != nil {
                    Button {
                        openKeychainAccess()
                    } label: {
                        Label("打开钥匙串访问", systemImage: "key.fill")
                    }
                    .help("打开“钥匙串访问”，检查登录钥匙串是否已解锁")
                }

                Spacer()

                Button {
                    retry(failure.operation)
                } label: {
                    Label(failure.retryTitle, systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .focused($focusedFailureAction, equals: .retry)
                .help(failure.retryHelp)
            }
        }
        .padding(14)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.red.opacity(0.45), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var commonACLs: [ObjectACL] {
        var values: [ObjectACL] = [.default, .private, .publicRead]
        if draft.defaultACL == .publicReadWrite {
            values.append(.publicReadWrite)
        }
        return values
    }

    private var aclSelection: Binding<ObjectACL> {
        Binding(
            get: { draft.defaultACL },
            set: { proposeACL($0) }
        )
    }

    private func proposeACL(_ acl: ObjectACL) {
        guard AccountACLConfirmation.requiresConfirmation(from: draft.defaultACL, to: acl) else {
            draft.defaultACL = acl
            return
        }
        pendingACL = acl
        showACLConfirmation = true
    }

    private func save() async {
        isTesting = true
        clearFailure()
        do {
            try await model.saveAccount(draft)
            dismiss()
        } catch {
            presentFailure(error, operation: .savingAccount)
        }
        isTesting = false
    }

    private func retry(_ operation: AccountFormFailure.Operation) {
        switch operation {
        case .savingAccount:
            Task { await save() }
        case .loadingCredentials:
            clearFailure()
            guard let account = model.editingAccount else { return }
            do {
                let secret = try SecretStore.read(account: AccountStore.secretAccount(account.id)) ?? ""
                let token = try SecretStore.read(account: AccountStore.tokenAccount(account.id)) ?? ""
                draft.secret = secret
                draft.token = token
            } catch {
                presentFailure(error, operation: .loadingCredentials)
            }
        }
    }

    private func presentFailure(_ error: Error, operation: AccountFormFailure.Operation) {
        let failure = AccountFormFailure(operation: operation, error: error)
        self.failure = failure

        Task { @MainActor in
            await Task.yield()
            focusedFailureAction = .retry
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: failure.accessibilityAnnouncement,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue
                ]
            )
        }
    }

    private func clearFailure() {
        failure = nil
        focusedFailureAction = nil
    }

    private func openKeychainAccess() {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.keychainaccess"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
