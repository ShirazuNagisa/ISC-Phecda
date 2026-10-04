import SwiftUI
import ISCCore

struct ServicesView: View {
    @Bindable var model: AppModel

    var body: some View {
        HSplitView {
            list
            Group {
                if let app = model.selectedApp {
                    ServiceDetailView(model: model, app: app)
                } else {
                    EmptyHint(symbol: "square.stack.3d.up",
                              title: tr("选择一个站点", "Select a site"),
                              message: tr("左侧列出你发布的所有站点。", "Your published sites are listed on the left."))
                }
            }
            .frame(minWidth: 420)
        }
        .navigationTitle(AppSection.services.title)
        .toolbar {
            ToolbarItem {
                Button {
                    model.showingNewService = true
                } label: {
                    Label(tr("发布新服务", "Publish a site"), systemImage: "plus")
                }
            }
        }
    }

    @ViewBuilder private var list: some View {
        Group {
            if model.apps.isEmpty {
                EmptyHint(symbol: "plus.rectangle.on.folder",
                          title: tr("还没有站点", "No sites yet"),
                          message: tr("给出源码目录，Phecda 会识别技术栈并完成部署。",
                                      "Point Phecda at a source folder and it will detect the stack and deploy it."),
                          action: (tr("发布新服务", "Publish a site"), { model.showingNewService = true }))
            } else {
                List(selection: $model.selectedAppID) {
                    ForEach(model.apps) { app in
                        HStack(spacing: 10) {
                            Image(systemName: app.isStatic ? "doc.text" : "server.rack")
                                .foregroundStyle(app.state.stateColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).font(.callout)
                                Text(app.domainNames.first ?? tr("仅本机", "local only"))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            StatePill(state: app.state, health: app.health)
                        }
                        .tag(app.id)
                    }
                }
                .frame(minWidth: 260)
            }
        }
    }
}

struct ServiceDetailView: View {
    @Bindable var model: AppModel
    let app: AppRecord

    @State private var logs: [String] = []
    @State private var logsError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let error = app.lastError ?? app.healthDetail, !error.isEmpty {
                    detailBox(error, tint: .orange)
                }
                facts
                if !app.domainNames.isEmpty { domains }
                actions
                logSection
            }
            .padding(22)
        }
        .task(id: app.id) { await loadLogs() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: app.isStatic ? "doc.text" : "server.rack")
                .font(.title2).foregroundStyle(app.state.stateColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.title3.weight(.semibold))
                Text(app.sourcePath).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            Spacer()
            StatePill(state: app.state, health: app.health)
        }
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 8) {
            factRow(tr("本地端口", "Local port"), "\(app.localPort)")
            factRow(tr("预设", "Preset"), app.presetId)
            if let runtime = app.runtime {
                factRow(tr("运行时", "Runtime"), "\(runtime.kind) \(runtime.version) (\(runtime.source))")
            } else if app.isStatic {
                factRow(tr("运行时", "Runtime"), tr("不需要（内核直接托管）", "none (served by the kernel)"))
            }
            if let sample = model.metrics(for: app.id) {
                if sample.hasOwnProcess {
                    factRow(tr("占用", "Usage"),
                            "\(sample.cpuPercent.formattedPercent) · \(sample.memoryBytes.formattedBytes) · PID \(sample.pid)")
                }
                factRow(tr("运行时长", "Uptime"), Int64(sample.uptimeSeconds).formattedDuration)
            }
            factRow(tr("崩溃重启", "Restarts"), "\(app.restartCount ?? 0) / \(app.maxRestarts ?? 0)")
        }
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            Text(value).font(.callout).monospacedDigit().textSelection(.enabled)
            Spacer()
        }
    }

    @ViewBuilder private var domains: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("公网访问", "Public access")).font(.headline)
            ForEach(app.domains ?? []) { domain in
                HStack(spacing: 10) {
                    Image(systemName: (domain.routeReady ?? false) ? "arrow.triangle.branch" : "exclamationmark.triangle")
                        .foregroundStyle((domain.routeReady ?? false) ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(domain.name).font(.callout)
                        Text(domainCaption(domain)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 10))
            }
        }
    }

    private func domainCaption(_ domain: AppDomain) -> String {
        if let error = domain.certError, !error.isEmpty { return error }
        if !(domain.routeReady ?? false) { return tr("反向代理里还没有这条规则", "No reverse-proxy rule yet") }
        if let expires = domain.certExpiresAt {
            let days = Calendar.current.dateComponents([.day], from: Date(), to: expires).day ?? 0
            return tr("证书还有 \(days) 天到期", "certificate expires in \(days) day(s)")
        }
        return tr("等待签发证书", "Waiting for a certificate")
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(tr("重新部署", "Redeploy")) {
                model.execute { _ = try await model.kernel.deployApp(app.id) }
            }
            .buttonStyle(.glassProminent)
            .disabled(app.isBusy)

            if app.isRunning {
                Button(tr("停止", "Stop")) {
                    model.execute { try await model.kernel.stopApp(app.id) }
                }
                .disabled(app.isBusy)
            } else {
                Button(tr("启动", "Start")) {
                    model.execute { _ = try await model.kernel.startApp(app.id) }
                }
                .disabled(app.isBusy)
            }

            Button(tr("重启", "Restart")) {
                model.execute { _ = try await model.kernel.restartApp(app.id) }
            }
            .disabled(app.isBusy)

            Spacer()

            Button(role: .destructive) {
                model.execute {
                    try await model.kernel.deleteApp(app.id)
                    model.selectedAppID = nil
                }
            } label: { Text(tr("删除", "Delete")) }
        }
        .buttonStyle(.glass)
    }

    @ViewBuilder private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tr("日志", "Logs")).font(.headline)
                Spacer()
                Button {
                    Task { await loadLogs() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
            }
            if let logsError {
                Text(logsError).font(.caption).foregroundStyle(.orange)
            } else if logs.isEmpty {
                Text(tr("还没有输出。", "No output yet.")).font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                }
                .frame(height: 220)
                .background(.black.opacity(0.18), in: .rect(cornerRadius: 10))
            }
        }
    }

    private func detailBox(_ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(tint)
            Text(text).font(.callout).textSelection(.enabled)
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: 10))
    }

    private func loadLogs() async {
        do {
            logs = try await model.kernel.appLogs(app.id, tail: 300)
            logsError = nil
        } catch {
            logsError = error.localizedDescription
        }
    }
}
