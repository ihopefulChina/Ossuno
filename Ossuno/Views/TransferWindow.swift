import AppKit
import SwiftUI

enum TransferFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case paused
    case failed
    case completed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .active: "进行中"
        case .paused: "已暂停"
        case .failed: "失败"
        case .completed: "已完成"
        }
    }

    func filter(_ jobs: [TransferJob]) -> [TransferJob] {
        jobs.filter { job in
            switch self {
            case .all: true
            case .active: job.isActive
            case .paused: job.status == .paused
            case .completed: job.status == .completed
            case .failed: job.status == .failed
            }
        }
    }
}

extension TransferJob {
    var canRevealInFinder: Bool {
        status == .completed
            && kind == .download
            && localURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
    }

    var canCopyPublicURL: Bool {
        kind == .upload && status == .completed && publicURL != nil
    }
}

struct TransferWindow: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<UUID> = []

    private var jobs: [TransferJob] { model.transferFilter.filter(model.transfers.jobs) }

    var body: some View {
        @Bindable var model = model
        Group {
            if jobs.isEmpty {
                Text(emptyTitle)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(of: TransferJob.self, selection: $selection) {
                    TableColumn("名称") { job in
                        HStack(spacing: 8) {
                            Image(systemName: icon(for: job))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(iconColor(for: job))
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(job.title)
                                    .lineLimit(1)
                                Text(subtitle(for: job))
                                    .font(.caption)
                                    .foregroundStyle(job.status == .failed ? .red : .secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    TableColumn("大小") { job in
                        Text("\(Formatters.bytes(job.transferred)) / \(Formatters.bytes(job.total))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .width(min: 120, ideal: 150, max: 180)
                    TableColumn("状态") { job in
                        if job.status == .running || job.status == .paused {
                            ProgressView(value: job.progress)
                                .progressViewStyle(.linear)
                                .frame(width: 80)
                                .help(statusText(for: job))
                        } else {
                            Text(statusText(for: job))
                                .foregroundStyle(job.status == .failed ? .red : .secondary)
                                .lineLimit(1)
                        }
                    }
                    .width(min: 110, ideal: 140, max: 180)
                    TableColumn("操作") { job in
                        rowActions(job)
                    }
                    .width(56)
                } rows: {
                    ForEach(jobs) { job in
                        TableRow(job)
                            .contextMenu { contextMenu(job) }
                    }
                }
            }
        }
        .frame(minWidth: 680, minHeight: 400)
        .navigationTitle("传输")
        .navigationSubtitle(summaryText)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("筛选", selection: $model.transferFilter) {
                    ForEach(TransferFilter.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(minWidth: 320, idealWidth: 360)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.transfers.jobs.contains(where: { $0.status == .running }) {
                    Button("全部暂停", systemImage: "pause") {
                        model.transfers.pauseAll()
                    }
                }
                if model.transfers.jobs.contains(where: { $0.status == .paused }) {
                    Button("全部继续", systemImage: "play") {
                        model.transfers.resumeAll()
                    }
                }
                Menu {
                    Button("清除已结束的记录") { model.transfers.clearFinished() }
                        .disabled(!model.transfers.jobs.contains(where: \.isFinished))
                    Divider()
                    Button("取消未完成的传输", role: .destructive) { model.transfers.cancelAll() }
                        .disabled(!model.transfers.jobs.contains { $0.isActive || $0.status == .paused })
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
                .help("更多传输操作")
            }
        }
    }

    @ViewBuilder
    private func rowActions(_ job: TransferJob) -> some View {
        HStack(spacing: 2) {
            if job.status == .running {
                iconButton("pause.circle", help: "暂停") { model.transfers.pause(job.id) }
            } else if job.status == .paused {
                iconButton("play.circle", help: "继续") { model.transfers.resume(job.id) }
            } else if job.status == .failed, model.transfers.canRetry(job.id) {
                iconButton("arrow.clockwise", help: "重试") { model.transfers.retry(job.id) }
            } else if job.canRevealInFinder {
                iconButton("folder", help: "在访达中显示") { reveal(job) }
            }
        }
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private func contextMenu(_ job: TransferJob) -> some View {
        if job.status == .running {
            Button("暂停") { model.transfers.pause(job.id) }
        }
        if job.status == .paused {
            Button("继续") { model.transfers.resume(job.id) }
        }
        if job.status == .queued {
            Button("移到队列顶部") { model.transfers.moveToTop(job.id) }
        }
        if job.status == .failed, model.transfers.canRetry(job.id) {
            Button("重试") { model.transfers.retry(job.id) }
        }
        if job.canRevealInFinder {
            Button("在访达中显示") { reveal(job) }
        }
        if job.canCopyPublicURL {
            Button("复制链接") { copyLink(job) }
        }
        if job.isActive || job.status == .paused {
            Divider()
            Button("取消传输", role: .destructive) { model.transfers.cancel(job.id) }
        }
    }

    private var emptyTitle: String {
        model.transferFilter == .all ? "没有传输" : "没有\(model.transferFilter.title)的传输"
    }

    private var summaryText: String {
        let visible = jobs.count
        let active = model.transfers.activeCount
        if active > 0 {
            return "\(visible) 个任务 · 正在传输 \(active) 项"
        }
        return visible == 1 ? "1 个任务" : "\(visible) 个任务"
    }

    private func subtitle(for job: TransferJob) -> String {
        if let reason = model.transfers.unavailableRetryReason(job.id), !reason.isEmpty {
            return reason
        }
        if job.status == .failed, let error = job.errorMessage, !error.isEmpty {
            return error
        }
        return job.objectKey
    }

    private func statusText(for job: TransferJob) -> String {
        switch job.status {
        case .queued:
            return "排队"
        case .running:
            guard let rate = model.transfers.currentBytesPerSecond(job.id) else {
                return "传输中"
            }
            let rateText = Formatters.bytes(Int64(rate))
            if let remaining = model.transfers.estimatedRemaining(job.id) {
                return "\(rateText)/s · \(Self.duration(remaining))"
            }
            return "\(rateText)/s"
        case .paused:
            return "已暂停"
        case .completed:
            return job.integrityVerified ? "已校验" : "已完成"
        case .failed:
            return "失败"
        case .cancelled:
            return "已取消"
        }
    }

    private func icon(for job: TransferJob) -> String {
        switch job.status {
        case .queued: "clock"
        case .running: job.kind == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
        case .paused: "pause.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled: "minus.circle"
        }
    }

    private func iconColor(for job: TransferJob) -> Color {
        switch job.status {
        case .completed: .green
        case .failed: .red
        case .paused, .cancelled: .secondary
        default: .accentColor
        }
    }

    private func reveal(_ job: TransferJob) {
        guard let url = job.localURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copyLink(_ job: TransferJob) {
        guard let url = job.publicURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded()))
        if value < 60 { return "约 \(value) 秒" }
        if value < 3_600 { return "约 \(value / 60) 分钟" }
        return "约 \(value / 3_600) 小时"
    }
}
