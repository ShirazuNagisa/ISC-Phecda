import SwiftUI
import ISCCore

/// 任务与审计。
///
/// 这两样放在一起是因为它们回答的是同一个问题："内核刚才做了什么，做完了
/// 没有"。此前部署进度只在首页横幅里一闪而过，失败了也看不到原因；而
/// 内核一直有 `/v1/jobs` 与 `/v1/audit`，只是界面没有入口。
struct JobsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case jobs, audit
        var id: String { rawValue }
        var title: String {
            switch self {
            case .jobs: tr("任务", "Tasks")
            case .audit: tr("审计", "Audit")
            }
        }
    }

    @State private var tab: Tab = .jobs
    @State private var entries: [AuditEntry] = []
    @State private var loadingAudit = false
    @State private var onlyFailures = false
    @State private var cancelling: String?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                Spacer()
                if tab == .audit {
                    Toggle(tr("只看失败", "Failures only"), isOn: $onlyFailures)
                        .toggleStyle(.checkbox)
                        .onChange(of: onlyFailures) { _, _ in Task { await loadAudit() } }
                }
                Button {
                    Task { await refresh() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
            }
            .padding(16)
            Divider()

            switch tab {
            case .jobs: jobList
            case .audit: auditList
            }

            if let failure {
                Divider()
                Text(failure).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).padding(16)
            }

            Divider()
            HStack {
                Spacer()
                Button(tr("完成", "Done")) { dismiss() }
            }
            .padding(16)
        }
        .frame(width: 660, height: 540)
        .task { await loadAudit() }
    }

    // MARK: 任务

    @ViewBuilder private var jobList: some View {
        if model.jobs.isEmpty {
            EmptyHint(symbol: "list.bullet.rectangle",
                      title: tr("还没有任务", "No tasks yet"),
                      message: tr("部署、准备运行时这类耗时操作会出现在这里。",
                                  "Long-running work such as deploys and runtime provisioning shows up here."))
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.jobs) { job in
                        jobRow(job)
                    }
                }
                .padding(16)
            }
        }
    }

    private func jobRow(_ job: JobInfo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: jobSymbol(job)).foregroundStyle(jobTint(job))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(kindLabel(job.kind)).font(.callout.weight(.medium))
                    Text(job.status).font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                }
                if let message = job.message, !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let reason = job.failedMessage, !reason.isEmpty {
                    Text(reason).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if !job.isFinished, let progress = job.progress, progress > 0 {
                    ProgressView(value: min(max(progress, 0), 1))
                        .frame(maxWidth: 320)
                }
                Text(stamp(job)).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if !job.isFinished {
                if cancelling == job.id {
                    ProgressView().controlSize(.small)
                } else {
                    Button(tr("取消", "Cancel")) { Task { await cancel(job) } }
                        .buttonStyle(.glass).controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.2), in: .rect(cornerRadius: 10))
    }

    private func jobSymbol(_ job: JobInfo) -> String {
        switch job.status {
        case "succeeded": "checkmark.circle.fill"
        case "failed": "xmark.octagon.fill"
        case "canceled": "slash.circle"
        default: "clock"
        }
    }

    private func jobTint(_ job: JobInfo) -> Color {
        switch job.status {
        case "succeeded": .green
        case "failed": .red
        case "canceled": .secondary
        default: .orange
        }
    }

    private func kindLabel(_ kind: String) -> String {
        switch kind {
        case "app.deploy": tr("部署站点", "Deploy a site")
        case "app.start": tr("启动站点", "Start a site")
        case "runtime.provision": tr("准备运行时", "Provision a runtime")
        case "debug.noop": tr("自检", "Self-check")
        default: kind
        }
    }

    private func stamp(_ job: JobInfo) -> String {
        let start = job.createdAt?.formatted(date: .abbreviated, time: .standard) ?? ""
        guard let finished = job.finishedAt else { return start }
        return start + " → " + finished.formatted(date: .omitted, time: .standard)
    }

    // MARK: 审计

    @ViewBuilder private var auditList: some View {
        if loadingAudit && entries.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            EmptyHint(symbol: "doc.text.magnifyingglass",
                      title: tr("没有审计记录", "No audit entries"),
                      message: tr("内核做过的改动会记录在这里。", "Changes the kernel makes are recorded here."))
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(entries) { entry in
                        auditRow(entry)
                    }
                }
                .padding(16)
            }
        }
    }

    private func auditRow(_ entry: AuditEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.failed ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .foregroundStyle(entry.failed ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(actionLabel(entry.action)).font(.callout)
                    if let target = entry.target, !target.isEmpty {
                        Text(target).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(entry.ts.formatted(date: .abbreviated, time: .standard))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.15), in: .rect(cornerRadius: 8))
    }

    /// 动作名是稳定的机器标识（`app.deploy`），界面负责把它说成人话。
    private func actionLabel(_ action: String) -> String {
        switch action {
        case "app.create": tr("登记站点", "Registered a site")
        case "app.deploy": tr("部署站点", "Deployed a site")
        case "app.stop": tr("停止站点", "Stopped a site")
        case "app.delete": tr("删除站点", "Deleted a site")
        case "hosting.source_inspect": tr("识别源码", "Inspected a source folder")
        case "hosting.runtime_provision": tr("准备运行时", "Provisioned a runtime")
        case "hosting.runtime_remove": tr("删除运行时", "Removed a runtime")
        case "credential.create", "credential.update": tr("修改服务商", "Changed a credential")
        case "proxy.routes": tr("修改转发规则", "Changed proxy routes")
        case "cert.renew": tr("续期证书", "Renewed a certificate")
        default: action
        }
    }

    // MARK: 数据

    private func refresh() async {
        failure = nil
        await model.refreshAll()
        await loadAudit()
    }

    private func loadAudit() async {
        loadingAudit = true
        do {
            entries = try await model.kernel.audit(result: onlyFailures ? "failure" : nil)
        } catch {
            failure = error.localizedDescription
        }
        loadingAudit = false
    }

    private func cancel(_ job: JobInfo) async {
        cancelling = job.id
        failure = nil
        do {
            try await model.kernel.cancelJob(job.id)
            await model.refreshAll()
        } catch {
            failure = error.localizedDescription
        }
        cancelling = nil
    }
}
