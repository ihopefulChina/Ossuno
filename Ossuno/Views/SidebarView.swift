import SwiftUI

enum SidebarSelection: Hashable {
    case account(UUID)
    case bucket(String)
    case favorite(String)
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var accountToDelete: OSSAccount?

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(
            get: { model.sidebarSelection },
            set: { model.applySidebarSelection($0) }
        )) {
            Section("账号") {
                ForEach(model.accounts) { account in
                    SidebarItemLabel(
                        title: account.displayName,
                        subtitle: account.region.name,
                        systemImage: account.id == model.selectedAccountID ? "cloud.fill" : "cloud"
                    )
                    .tag(SidebarSelection.account(account.id))
                    .accessibilityValue(account.id == model.selectedAccountID ? "当前账号" : "")
                    .contextMenu {
                        Button("编辑…") {
                            model.editingAccount = account
                            model.showAccountSheet = true
                        }
                        Button("删除账号", role: .destructive) {
                            accountToDelete = account
                        }
                    }
                }
            }

            Section("存储空间") {
                if model.isLoadingBuckets {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在读取…")
                            .foregroundStyle(.secondary)
                    }
                } else if model.buckets.isEmpty {
                    Text("这个账号下还没有 Bucket")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.buckets) { bucket in
                        SidebarItemLabel(
                            title: bucket.name,
                            subtitle: bucket.regionLabel,
                            systemImage: "externaldrive"
                        )
                        .tag(SidebarSelection.bucket(bucket.name))
                    }
                }
            }

            if !model.favorites.items.isEmpty {
                Section("常用") {
                    ForEach(model.favorites.items) { favorite in
                        SidebarItemLabel(
                            title: favorite.name,
                            subtitle: favorite.bucketName,
                            systemImage: favorite.prefix.isEmpty ? "externaldrive" : "folder"
                        )
                        .tag(SidebarSelection.favorite(favorite.id))
                        .contextMenu {
                            Button("从常用中移除") {
                                model.favorites.remove(favorite)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 300)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.editingAccount = nil
                    model.showAccountSheet = true
                } label: {
                    Label("添加账号", systemImage: "plus")
                }
                .help("添加账号")
            }
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
                }
                accountToDelete = nil
            }
            Button("取消", role: .cancel) { accountToDelete = nil }
        } message: {
            Text("只删除这台 Mac 上的登录信息，不会改动云端数据。")
        }
    }
}

private struct SidebarItemLabel: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
        }
    }
}
