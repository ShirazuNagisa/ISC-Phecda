import SwiftUI
import ISCCore

/// 三栏骨架：左侧固定三块，右侧是对应内容。
struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 900, minHeight: 580)
        .overlay(alignment: .bottom) { banner }
        .sheet(isPresented: $model.showingNewService) {
            NewServiceView(model: model)
        }
        .sheet(isPresented: $model.showOnboarding) {
            FirstRunView(model: model)
        }
        .sheet(item: $model.requestedSheet) { sheet in
            switch sheet {
            case .credentials:
                CredentialListView(model: model)
            case .settings:
                SettingsView(model: model)
            case .ddns:
                DDNSTaskListView(model: model)
            }
        }
    }

    private var sidebar: some View {
        List(selection: $model.section) {
            Section {
                ForEach(AppSection.allCases) { item in
                    Label(item.title, systemImage: item.symbol).tag(item)
                }
            }
            Section {
                kernelRow
                if let settings = model.settings, settings.proxyEnabled == false {
                    Label(tr("反向代理未启用", "Reverse proxy off"), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            // 设置放在侧栏底部而不是第四个分区：侧栏只有三块是产品决定，
            // 而设置是偶尔用一次的东西。
            Section {
                Button {
                    model.requestedSheet = .settings
                } label: {
                    Label(tr("设置", "Settings"), systemImage: "gearshape")
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
    }

    @ViewBuilder private var kernelRow: some View {
        HStack(spacing: 8) {
            Circle().fill(kernelColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(tr("内核", "Kernel")).font(.caption)
                Text(kernelLabel).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isBusy { ProgressView().controlSize(.small) }
        }
    }

    private var kernelColor: Color {
        switch model.phase {
        case .running: .green
        case .failed: .red
        case .starting, .stopping: .orange
        case .stopped: .secondary
        }
    }

    private var kernelLabel: String {
        switch model.phase {
        case .running: tr("运行中", "running")
        case .starting: tr("启动中", "starting")
        case .stopping: tr("停止中", "stopping")
        case .failed: tr("启动失败", "failed")
        case .stopped: tr("未运行", "stopped")
        }
    }

    @ViewBuilder private var detail: some View {
        if let mismatch = model.versionMismatch {
            EmptyHint(symbol: "exclamationmark.triangle",
                      title: tr("内核与界面版本不匹配", "Kernel and app versions do not match"),
                      message: mismatch)
        } else if model.phase == .failed {
            EmptyHint(symbol: "xmark.octagon",
                      title: tr("内核没有启动", "The kernel did not start"),
                      message: model.errorMessage ?? tr("未知原因。", "Unknown reason."),
                      action: (tr("重试", "Try again"), { Task { await model.start() } }))
        } else if !model.running {
            EmptyHint(symbol: "power",
                      title: tr("内核未运行", "The kernel is not running"),
                      message: tr("启动内核后才能查看与管理你的站点。", "Start the kernel to see and manage your sites."),
                      action: (tr("启动内核", "Start kernel"), { Task { await model.start() } }))
        } else {
            switch model.section {
            case .home: HomeView(model: model)
            case .services: ServicesView(model: model)
            case .dns: DNSView(model: model)
            }
        }
    }

    /// 错误与提示只在有内容时占一行，并且**不挡住**下面的操作。
    @ViewBuilder private var banner: some View {
        if let message = model.errorMessage {
            BannerRow(text: message, symbol: "exclamationmark.triangle.fill", tint: .orange) {
                model.errorMessage = nil
            }
        } else if let message = model.notice {
            BannerRow(text: message, symbol: "info.circle.fill", tint: .blue) {
                model.notice = nil
            }
        }
    }
}

struct BannerRow: View {
    let text: String
    let symbol: String
    let tint: Color
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.callout).textSelection(.enabled).lineLimit(3)
            Spacer(minLength: 8)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .padding(14)
    }
}

// MARK: - 首页

struct HomeView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                metricsSection
                advisoriesSection
                servicesSection
                dnsSection
                domainSection
            }
            .padding(22)
        }
        .navigationTitle(AppSection.home.title)
    }

    @ViewBuilder private var metricsSection: some View {
        if let host = model.metrics?.host, host.isSupported {
            HStack(spacing: 14) {
                MetricCard(title: tr("CPU", "CPU"),
                           value: host.cpuPercent.formattedPercent,
                           caption: tr("整机占用", "whole machine"),
                           symbol: "cpu", tint: .blue,
                           fraction: host.cpuPercent / 100)
                MetricCard(title: tr("内存", "Memory"),
                           value: host.memoryUsedBytes.formattedBytes,
                           caption: tr("共 \(host.memoryTotalBytes.formattedBytes)", "of \(host.memoryTotalBytes.formattedBytes)"),
                           symbol: "memorychip", tint: .purple,
                           fraction: host.memoryFraction)
                MetricCard(title: tr("网络", "Network"),
                           value: host.netRxBytesPerSec.formattedRate,
                           caption: tr("发送 \(host.netTxBytesPerSec.formattedRate)", "up \(host.netTxBytesPerSec.formattedRate)"),
                           symbol: "arrow.up.arrow.down", tint: .teal)
            }
        } else {
            Text(tr("此平台暂不支持资源指标。", "Resource metrics are not available on this platform."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var advisoriesSection: some View {
        if !model.advisories.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("建议", "Suggestions")).font(.headline)
                ForEach(model.advisories) { advisory in
                    AdvisoryRow(advisory: advisory) { model.apply($0) }
                }
            }
        }
    }

    @ViewBuilder private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tr("我的站点", "My sites")).font(.headline)
                Spacer()
                Button(tr("发布新服务", "Publish a site")) { model.showingNewService = true }
                    .buttonStyle(.glass).controlSize(.small)
            }
            if model.apps.isEmpty {
                Text(tr("还没有站点。点右上角开始发布。", "No sites yet. Use the button above to publish one."))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(model.apps) { app in
                    Button {
                        model.selectedAppID = app.id
                        model.section = .services
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: app.isStatic ? "doc.text" : "server.rack")
                                .foregroundStyle(app.state.stateColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).font(.callout.weight(.medium))
                                Text(app.domainNames.first ?? "127.0.0.1:\(app.localPort)")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if let sample = model.metrics(for: app.id), sample.hasOwnProcess {
                                Text("\(sample.cpuPercent.formattedPercent) · \(sample.memoryBytes.formattedBytes)")
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            StatePill(state: app.state, health: app.health)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffect(.regular, in: .rect(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 域名解析状态：当前公网地址 + 每条动态解析任务上次跑成什么样。
    ///
    /// 这两样要放在一起才有意义 —— "解析不对"要么是地址变了没更新，
    /// 要么是更新失败了，单看其中一个都判断不出来。
    @ViewBuilder private var dnsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("域名解析", "DNS resolution")).font(.headline)
            HStack(spacing: 10) {
                Image(systemName: "network").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("当前公网地址", "Current public address")).font(.caption).foregroundStyle(.secondary)
                    Text(model.ipStatus?.summary ?? "—").font(.callout).monospacedDigit().textSelection(.enabled)
                }
                Spacer()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 10))

            if model.ddnsTasks.isEmpty {
                Text(tr("还没有动态解析任务；如果你的地址不常变，也可以手动维护解析。",
                        "No dynamic-DNS tasks yet. If your address rarely changes you can maintain the records by hand."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(model.ddnsTasks) { task in
                    HStack(spacing: 10) {
                        Image(systemName: ddnsSymbol(task)).foregroundStyle(ddnsTint(task))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(task.label).font(.callout)
                                if !task.enabled {
                                    Text(tr("已停用", "disabled")).font(.caption2)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(.quaternary, in: .capsule)
                                }
                            }
                            Text(ddnsCaption(task)).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.2), in: .rect(cornerRadius: 10))
                }
            }
        }
    }

    private func ddnsSymbol(_ task: DdnsTaskInfo) -> String {
        guard task.enabled else { return "pause.circle" }
        switch task.lastStatus {
        case "success": return "checkmark.circle.fill"
        case "failed": return "exclamationmark.triangle.fill"
        default: return "clock"
        }
    }

    private func ddnsTint(_ task: DdnsTaskInfo) -> Color {
        guard task.enabled else { return .secondary }
        switch task.lastStatus {
        case "success": return .green
        case "failed": return .orange
        default: return .secondary
        }
    }

    private func ddnsCaption(_ task: DdnsTaskInfo) -> String {
        if let message = task.lastMessage, !message.isEmpty { return message }
        let address = [task.lastIpv4, task.lastIpv6].compactMap { $0 }.filter { !$0.isEmpty }
        guard let last = task.lastRunAt else { return tr("尚未执行", "Never run") }
        let stamp = last.formatted(date: .abbreviated, time: .shortened)
        return address.isEmpty ? stamp : "\(address.joined(separator: " · ")) · \(stamp)"
    }

    @ViewBuilder private var domainSection: some View {
        if !model.certificates.isEmpty || !model.ddnsTasks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("域名与证书", "Domains and certificates")).font(.headline)
                ForEach(model.certificates) { cert in
                    HStack(spacing: 10) {
                        Image(systemName: cert.needsRenew ? "clock.badge.exclamationmark" : "lock.shield")
                            .foregroundStyle(cert.needsRenew ? .orange : .green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cert.domains.joined(separator: ", ")).font(.callout).lineLimit(1)
                            Text(certCaption(cert)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if cert.staging {
                            Text(tr("测试环境", "staging")).font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.orange.opacity(0.2), in: .capsule)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 10))
                }
            }
        }
    }

    private func certCaption(_ cert: CertificateInfo) -> String {
        if let error = cert.error, !error.isEmpty { return error }
        guard let days = cert.daysRemaining else { return tr("尚未签发", "Not issued yet") }
        return tr("还有 \(days) 天到期", "expires in \(days) day(s)")
    }
}
