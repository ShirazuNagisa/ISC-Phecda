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
            case .jobs:
                JobsView(model: model)
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
            case .remote: RemoteView(model: model)
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
            // lineLimit 管住高度，frame(maxWidth:) 管住**理想宽度**：
            // 一条没有空格可断的长错误会把自己的理想宽度一路传给整个窗口，
            // 侧栏就是被这么挤掉的（见 EmptyHint.messageMaxWidth）。
            Text(text).font(.callout).textSelection(.enabled).lineLimit(3)
                .frame(maxWidth: EmptyHint.messageMaxWidth, alignment: .leading)
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
                activeJobsSection
                metricsSection
                advisoriesSection
                servicesSection
                dnsSection
                domainSection
            }
            .padding(22)
        }
        .navigationTitle(AppSection.home.title)
        .toolbar {
            ToolbarItem {
                Button {
                    model.requestedSheet = .jobs
                } label: {
                    if model.activeJobs.isEmpty {
                        Label(tr("任务", "Tasks"), systemImage: "list.bullet.rectangle")
                    } else {
                        Label(tr("任务（\(model.activeJobs.count) 进行中）",
                                 "Tasks (\(model.activeJobs.count) running)"),
                              systemImage: "list.bullet.rectangle")
                    }
                }
            }
        }
    }

    /// 进行中的任务。
    ///
    /// 单独一块而不是只转个圈：一次部署包含准备运行时、装依赖、构建、启动
    /// 好几步，用户需要知道现在卡在哪一步 —— 尤其当某一步要下载几百 MB 时。
    @ViewBuilder private var activeJobsSection: some View {
        if !model.activeJobs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("进行中", "In progress")).font(.headline)
                ForEach(model.activeJobs) { job in
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(job.kind == "app.deploy" ? tr("部署站点", "Deploying a site")
                                 : job.kind == "runtime.provision" ? tr("准备运行时", "Provisioning a runtime")
                                 : job.kind)
                                .font(.callout)
                            if let message = job.message, !message.isEmpty {
                                Text(message).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 8)
                        if let progress = job.progress, progress > 0 {
                            Text(progress.formattedPercent).font(.caption).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Button(tr("查看", "View")) { model.requestedSheet = .jobs }
                            .buttonStyle(.glass).controlSize(.small)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                }
            }
        }
    }

    /// 硬件信息栏。
    ///
    /// # 口径
    ///
    /// CPU / 内存 / 网络 是 **Phecda 自己的占用**（内核 + 站点进程树），
    /// 不是整台机器 —— 用户看到"CPU 60%"时的第一反应是"Phecda 吃了这么多"，
    /// 所以主数字就该是它的。整机数字留在 caption 里当对照：机器卡的时候
    /// 用户真正要做的比较是"是它干的，还是别的程序"。
    ///
    /// GPU 是唯一的例外，而且是**不得不**的：macOS 没有按进程归因 GPU 的
    /// 途径，只能拿设备级利用率。因此它带一个"整机 GPU"的标注 ——
    /// 两种口径并排摆着而不说明，比不显示更糟。
    ///
    /// # 换行
    ///
    /// 用自适应网格而不是 HStack：四张卡在窄窗口里排不下时**自动换行**，
    /// 而不是把每张挤到读不出数字（窗口最小宽度是 900）。
    @ViewBuilder private var metricsSection: some View {
        if let host = model.metrics?.host, host.isSupported {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)],
                      alignment: .leading, spacing: 14) {
                cpuCard(host)
                gpuCard(host)
                memoryCard(host)
                networkCard(host)
            }
        } else {
            Text(tr("此平台暂不支持资源指标。", "Resource metrics are not available on this platform."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// footprint 缺席只可能发生在旧内核上（新内核一定会发）。
    private var footprint: FootprintMetrics? { model.metrics?.footprint }

    private func cpuCard(_ host: HostMetrics) -> some View {
        MetricCard(title: tr("CPU", "CPU"),
                   value: footprint.map { $0.cpuPercent.formattedPercent } ?? "—",
                   detail: .fraction(footprint?.cpuFraction ?? 0),
                   caption: tr("Phecda 占用 · 整机 \(host.cpuPercent.formattedPercent)",
                               "Phecda · device \(host.cpuPercent.formattedPercent)"),
                   symbol: "cpu", tint: .blue,
                   note: footprint == nil ? tr("需要更新内核", "Kernel update needed") : nil)
    }

    private func gpuCard(_ host: HostMetrics) -> some View {
        MetricCard(title: "GPU",
                   value: host.gpu?.utilizationPercent.map(\.formattedPercent) ?? "—",
                   detail: .fraction((host.gpu?.utilizationPercent ?? 0) / 100),
                   caption: tr("整机 GPU\(host.gpu?.name.map { " · \($0)" } ?? "")",
                               "Device GPU\(host.gpu?.name.map { " · \($0)" } ?? "")"),
                   symbol: "cube.transparent", tint: .orange,
                   note: gpuNote(host))
    }

    private func gpuNote(_ host: HostMetrics) -> String? {
        guard let gpu = host.gpu else { return tr("这台机器没有可采样的 GPU", "No samplable GPU") }
        if !gpu.isSupported { return tr("此平台不支持", "Not supported here") }
        if gpu.utilizationPercent == nil { return tr("本次未读到", "No reading this time") }
        return nil
    }

    private func memoryCard(_ host: HostMetrics) -> some View {
        MetricCard(title: tr("内存", "Memory"),
                   value: footprint?.memoryBytes.formattedBytes ?? "—",
                   detail: .text(tr("共 \(host.memoryTotalBytes.formattedBytes)",
                                    "of \(host.memoryTotalBytes.formattedBytes)")),
                   caption: tr("Phecda 占用 · 整机 \(host.memoryUsedBytes.formattedBytes)",
                               "Phecda · device \(host.memoryUsedBytes.formattedBytes)"),
                   symbol: "memorychip", tint: .purple,
                   note: footprint == nil ? tr("需要更新内核", "Kernel update needed") : nil)
    }

    private func networkCard(_ host: HostMetrics) -> some View {
        // 网络是三态的：没读到要显示"未读到"而不是 0 —— 否则用户会以为
        // Phecda 不占网络。整机速率留在 caption 里当对照。
        let fp = footprint
        let value = (fp?.hasNetwork == true ? fp?.netRxBytesPerSec : nil)?.formattedRate ?? "—"
        let detail: MetricCard.Detail = fp?.hasNetwork == true
            ? .text(tr("↑ \((fp?.netTxBytesPerSec ?? 0).formattedRate)",
                       "↑ \((fp?.netTxBytesPerSec ?? 0).formattedRate)"))
            : .text(tr("Phecda 流量", "Phecda traffic"))
        return MetricCard(title: tr("网络", "Network"),
                          value: value,
                          detail: detail,
                          caption: tr("整机 ↓ \(host.netRxBytesPerSec.formattedRate) · ↑ \(host.netTxBytesPerSec.formattedRate)",
                                      "Device ↓ \(host.netRxBytesPerSec.formattedRate) · ↑ \(host.netTxBytesPerSec.formattedRate)"),
                          symbol: "arrow.up.arrow.down", tint: .teal,
                          note: networkNote)
    }

    private var networkNote: String? {
        guard let fp = footprint else { return tr("需要更新内核", "Kernel update needed") }
        if fp.hasNetwork { return nil }
        switch fp.netBackend {
        case "unsupported": return tr("此平台不支持按进程统计", "Per-process traffic not supported here")
        case "unavailable": return tr("本次未读到", "No reading this time")
        default: return tr("暂无数据", "No data")
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
                            if let reach = model.reachability(for: app) { reachabilityBadge(reach) }
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

    /// 公网可达性指示。
    ///
    /// # 为什么"不可信"要单独画出来
    ///
    /// 没有隧道时，内核那次检查走的是 NAT 发夹 —— 运营商放不放行都会
    /// "成功"。把它画成一个绿色的勾，用户会以为公网已经通了，然后在
    /// 真的从外面打不开时完全摸不着头脑。因此那一档不显示成"通过"，
    /// 而是显示成"本机可达"，并说清楚它证明了什么、没证明什么。
    @ViewBuilder private func reachabilityBadge(_ item: ReachabilityItem) -> some View {
        let tint: Color = item.isFailing ? .red : (item.trustworthy ? .green : .secondary)
        HStack(spacing: 4) {
            Image(systemName: item.isFailing ? "exclamationmark.triangle.fill"
                  : (item.trustworthy ? "globe" : "house"))
                .font(.caption2)
                .foregroundStyle(tint)
            if let ms = item.latencyMs, item.ok {
                Text("\(ms) ms").font(.caption2).monospacedDigit().foregroundStyle(tint)
            }
        }
        .help(reachabilityHelp(item))
    }

    private func reachabilityHelp(_ item: ReachabilityItem) -> String {
        if let error = item.error, !error.isEmpty {
            return tr("\(item.domain) 公网不可达（连续 \(item.consecutiveFailures) 次）：\(error)",
                      "\(item.domain) is not reachable from the internet (\(item.consecutiveFailures) failures): \(error)")
        }
        if !item.ok {
            let code = item.statusCode.map { "HTTP \($0)" } ?? tr("无响应", "no response")
            return tr("\(item.domain) 返回 \(code)", "\(item.domain) returned \(code)")
        }
        if !item.trustworthy {
            return tr("\(item.domain) 在本机可访问；这次检查走的是本机路径，不能证明公网可达。开启 Cloudflare 自动中继后这个检查才有公网意义。",
                      "\(item.domain) answers locally. This check went through the local path and does not prove public reachability — enable the Cloudflare relay to make it meaningful.")
        }
        return tr("\(item.domain) 已从公网确认可达。", "\(item.domain) is confirmed reachable from the internet.")
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
