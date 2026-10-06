import SwiftUI
import ISCCore

/// 站点的状态色。
///
/// 只按状态给颜色，不按"用户希望它是什么样"给 —— 一个 failed 的站点
/// 不应该看起来和 running 的一样。
extension String {
    var stateColor: Color {
        switch self {
        case "running": .green
        case "failed": .red
        case "stopped", "draft": .secondary
        case "provisioning", "installing", "building", "starting", "stopping": .orange
        default: .secondary
        }
    }

    var stateLabel: String {
        switch self {
        case "draft": tr("未部署", "Not deployed")
        case "provisioning": tr("准备运行时", "Preparing runtime")
        case "installing": tr("安装依赖", "Installing")
        case "building": tr("构建中", "Building")
        case "starting": tr("启动中", "Starting")
        case "running": tr("运行中", "Running")
        case "stopping": tr("停止中", "Stopping")
        case "stopped": tr("已停止", "Stopped")
        case "failed": tr("失败", "Failed")
        default: self
        }
    }

    var healthSymbol: String {
        switch self {
        case "healthy": "checkmark.circle.fill"
        case "unhealthy": "exclamationmark.triangle.fill"
        case "starting": "clock"
        default: "questionmark.circle"
        }
    }

    var healthColor: Color {
        switch self {
        case "healthy": .green
        case "unhealthy": .orange
        default: .secondary
        }
    }

    var severityColor: Color {
        switch self {
        case "blocking": .red
        case "warning": .orange
        default: .blue
        }
    }

    var severitySymbol: String {
        switch self {
        case "blocking": "exclamationmark.octagon.fill"
        case "warning": "exclamationmark.triangle.fill"
        default: "info.circle.fill"
        }
    }
}

struct StatePill: View {
    let state: String
    let health: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(state.stateColor).frame(width: 7, height: 7)
            Text(state.stateLabel).font(.caption).foregroundStyle(.secondary)
            if state == "running" {
                Image(systemName: health.healthSymbol)
                    .font(.caption2)
                    .foregroundStyle(health.healthColor)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.quaternary.opacity(0.4), in: .capsule)
    }
}

/// 首页上的一张指标卡。
///
/// 几张卡必须**一样高**。此前网络那张少一行（CPU 与内存有占比条、网络没有），
/// 于是它比另外两张矮一截 —— 并排的卡参差不齐，看起来像是网络那张
/// 出了问题。修法不是给它硬塞一个没有意义的占比条，而是让第三行**两种形态
/// 高度一致**：有占比就画条，没有就放一行说明。
struct MetricCard: View {
    /// 第三行显示什么。
    enum Detail {
        /// 0...1 的占比。
        case fraction(Double)
        /// 一行说明（用在没有占比可言的指标上，例如网络速率）。
        case text(String)
    }

    let title: String
    let value: String
    /// 第三行。
    let detail: Detail
    /// 第四行：补充说明。
    let caption: String?
    let symbol: String
    let tint: Color
    /// 非空表示"这个数现在没有"，此时**不显示** value 与 detail，只显示它。
    ///
    /// # 为什么不能用"0"或"—"顶替
    ///
    /// 指标有若干种"没有值"，而它们要说的话完全不同：平台不支持、这次
    /// 没读到、这台机器没有这个设备。统一显示成 0 会被读成"什么都没占用"，
    /// 显示成"—"则是让用户自己去猜是哪种。因此由调用方给一句明确的话。
    var note: String? = nil

    /// 第三行的固定高度。
    ///
    /// 写死是刻意的：`ProgressView` 与一行文字的自然高度不同，靠它们各自
    /// 撑出来的高度就不可能一致，而"一致"正是这里要的东西。
    private let detailHeight: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(note ?? value)
                .font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(note == nil ? .primary : .secondary)
            Group {
                if note != nil {
                    Color.clear
                } else {
                    switch detail {
                    case .fraction(let fraction):
                        ProgressView(value: min(max(fraction, 0), 1)).tint(tint)
                    case .text(let text):
                        Text(text).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .frame(height: detailHeight)
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

/// 一条建议。
struct AdvisoryRow: View {
    let advisory: Advisory
    let apply: (Advisory) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: advisory.severity.severitySymbol)
                .foregroundStyle(advisory.severity.severityColor)
                .font(.callout)
            VStack(alignment: .leading, spacing: 3) {
                Text(advisory.title).font(.callout.weight(.medium))
                if let detail = advisory.detail, !detail.isEmpty {
                    // 建议的正文常常是底层工具的原样报错（可能很长且没有空格），
                    // 必须按可用宽度换行，而不是反过来要求更多宽度。
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let action = advisory.action {
                Button(action.label) { apply(advisory) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(advisory.severity.severityColor.opacity(0.07), in: .rect(cornerRadius: 10))
    }
}

struct EmptyHint: View {
    let symbol: String
    let title: String
    let message: String
    var action: (label: String, run: () -> Void)?

    /// 正文的最大宽度。
    ///
    /// 这个上限不是为了好看，是为了**别把左侧栏挤没**：正文里常常是服务商
    /// 或内核抛回来的错误（一条长得没有空格可断的 URL），而 Text 的理想宽度
    /// 就是它一行排开的宽度。理想宽度会一路往上传，NavigationSplitView 只好
    /// 从侧栏抽宽度去满足它 —— 结果就是 DNS 服务商一出错，整个左侧栏变空。
    /// 给正文钉一个上限，这条传导链就断了。
    static let messageMaxWidth: CGFloat = 460

    /// 行数上限。宽度上限挡不住"在零宽提案下算出几百行高"这种情况，
    /// 行数上限可以 —— 两个方向都钉住，正文才彻底不参与布局博弈。
    static let messageMaxLines = 8

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .lineLimit(Self.messageMaxLines)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 0, maxWidth: Self.messageMaxWidth)
                .clipped()
            if let action {
                Button(action.label, action: action.run).buttonStyle(.glassProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - DNS 凭据字段（共享）

/// 凭据草稿的校验与构造。
///
/// # 为什么抽出来而不是留在表单里
///
/// 首启向导的第二页与「添加凭据」的 sheet 是同一件事的两个入口。规则有
/// 两条容易写歪：必填项的判定，以及"只提交填过的字段"（空字符串会被内核
/// 当成**显式清空**，而用户只是没填可选项）。复制两份就是给以后留一个
/// "向导里建出来的凭据和表单里建出来的不一样"的坑。
enum CredentialDraft {
    static func isValid(provider: Provider?, label: String, values: [String: String]) -> Bool {
        guard let provider, !label.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return provider.credentialFields
            .filter(\.required)
            .allSatisfy { !(values[$0.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    static func input(provider: Provider, label: String, values: [String: String]) -> CredentialInput {
        let filled = values.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        return CredentialInput(provider: provider.name, label: label, fields: filled)
    }
}

/// 凭据表单的**字段部分**：服务商、名称、各服务商的动态字段。
///
/// 只有这些 —— 保存按钮、取消按钮、标题栏留在各自的容器里（sheet 有自己
/// 的表头与底栏，向导有右下角的上一步/下一步）。
struct CredentialFieldsView: View {
    @Bindable var model: AppModel
    @Binding var providerName: String?
    @Binding var label: String
    @Binding var values: [String: String]
    /// 本次已经替用户打开过配置页的服务商，用来去重。
    @Binding var openedCredentialPages: Set<String>

    var provider: Provider? {
        model.providers.first { $0.name == providerName }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker(tr("服务商", "Provider"), selection: $providerName) {
                Text(tr("请选择", "Select")).tag(String?.none)
                ForEach(model.providers) { item in
                    Text(item.displayName).tag(String?.some(item.name))
                }
            }
            .onChange(of: providerName) { previous, _ in
                providerChanged(from: model.providers.first { $0.name == previous })
            }

            TextField(tr("名称（自己认得就行）", "Label (anything you recognise)"), text: $label)
                .textFieldStyle(.roundedBorder)

            if let provider {
                credentialPageButton(provider)
                ForEach(provider.credentialFields) { field in
                    fieldInput(field)
                }
                capabilitiesHint(provider)
            }
        }
    }

    /// 选完服务商之后要做两件事：把名字填好、把用户送到拿凭据的那一页。
    ///
    /// 都是"能替用户做就替用户做"的部分：名字几乎总是服务商名，而 API
    /// 凭据页面这几家都藏得不浅（Cloudflare 在"我的个人资料 → API 令牌"
    /// 下面两层），让用户自己找一遍纯属摩擦 —— 找错地方还会顺手把权限
    /// 过大的 Global API Key 抄出来。
    private func providerChanged(from previous: Provider?) {
        values = [:]
        guard let provider else { return }
        let current = label.trimmingCharacters(in: .whitespaces)
        if current.isEmpty || current == previous?.displayName {
            label = provider.displayName
        }
        openCredentialPage(provider)
    }

    private func openCredentialPage(_ provider: Provider) {
        guard let url = provider.credentialPageURL,
              openedCredentialPages.insert(provider.name).inserted else { return }
        NSWorkspace.shared.open(url)
    }

    /// 配置页的入口按钮。
    ///
    /// 自动打开之外仍然留一个按钮：用户可能把标签页关掉了，或者浏览器
    /// 拦下了这次打开；没有按钮的话就只剩"重选一次服务商"这种笨办法。
    @ViewBuilder private func credentialPageButton(_ provider: Provider) -> some View {
        if let url = provider.credentialPageURL {
            HStack(spacing: 6) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label(tr("打开 \(provider.displayName) 的 API 凭据页面",
                             "Open the \(provider.displayName) API credentials page"),
                          systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.glass).controlSize(.small)
                Text(tr("在那里创建好凭据，再粘回下面的输入框。",
                        "Create the credential there, then paste it below."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func fieldInput(_ field: ProviderField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(field.label).font(.callout)
                if field.required {
                    Text("*").font(.caption).foregroundStyle(.red)
                }
            }
            if field.secret {
                SecureField(field.placeholder ?? "", text: binding(field.key))
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField(field.placeholder ?? "", text: binding(field.key))
                    .textFieldStyle(.roundedBorder)
            }
            if let help = field.help, !help.isEmpty {
                Text(help).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func capabilitiesHint(_ provider: Provider) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !provider.capabilities.dns01 {
                Label(tr("该服务商不支持 DNS-01，无法用它签发证书。",
                         "This provider does not support DNS-01, so it cannot be used to issue certificates."),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !provider.capabilities.canManageRecords {
                Label(tr("该服务商不支持列区域或列记录，因此不能在这里管理解析条目。",
                         "This provider cannot list zones or records, so records cannot be managed here."),
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }
}


// MARK: - Cloudflare 中继（共享）

/// Cloudflare 中继的开关与状态。
///
/// 设置页与首启向导的第三页共用。抽出来的理由是那段**状态文案**：缺
/// cloudflared、缺账号授权、启动失败三种情况要用户做的事完全不同，而
/// 它们在一个布尔量里长得一模一样。复制两份必然漂移，而漂移的表现是
/// "向导里说得好好的，设置页里却是另一句话"。
struct TunnelControls: View {
    @Bindable var model: AppModel
    /// 是否显示标题与说明。向导页自己有标题，因此传 false。
    var showsHeader: Bool = true

    @State private var enabled = false
    @State private var status: TunnelStatus?
    @State private var busy = false
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsHeader {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Cloudflare 自动中继", "Cloudflare relay")).font(.headline)
                    Text(tr("本机没有公网地址时，让站点仍然能从公网访问。",
                            "Keeps sites reachable from the internet when this machine has no public address."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Toggle(tr("启用", "Enabled"), isOn: binding)
                .toggleStyle(.switch)
                .disabled(busy)

            Text(tr("本机主动向 Cloudflare 建一条长连接，外面来的请求顺着它进来。不需要公网地址，也不用在路由器上开端口 —— 校园网、公司网、大内网宽带都能用。",
                    "This machine opens a long-lived connection to Cloudflare, and incoming requests travel back along it. No public address and no router port forwarding — works on campus, corporate and carrier-grade NAT networks."))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let status {
                statusRow(status)
                if let reason = blockingReason(status) {
                    Text(reason).font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task {
            // 只加载一次：视图会因为父级的重绘被重建，而每次重建都去问一遍
            // 内核既浪费又会让开关在加载期间闪一下。
            guard !loaded else { return }
            loaded = true
            enabled = model.settings?.tunnelEnabled ?? false
            status = try? await model.kernel.tunnelStatus()
        }
    }

    @ViewBuilder private func statusRow(_ status: TunnelStatus) -> some View {
        HStack(spacing: 8) {
            Circle().fill(status.isRunning ? .green : (status.isBlocked ? .orange : .secondary))
                .frame(width: 7, height: 7)
            Text(summary(status)).font(.caption)
            Spacer(minLength: 0)
            if status.isRunning {
                Text(tr("\(status.connections) 条连接", "\(status.connections) connections"))
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private func summary(_ status: TunnelStatus) -> String {
        switch status.state {
        case "running": return tr("运行中", "Running")
        case "starting": return tr("正在连接 Cloudflare…", "Connecting to Cloudflare…")
        case "disabled": return tr("未开启", "Off")
        case "no_binary": return tr("未就绪", "Not ready")
        case "no_account": return tr("需要授权", "Authorization needed")
        case "failed": return tr("启动失败", "Failed to start")
        default: return status.state
        }
    }

    /// 卡住的原因，以及**下一步该做什么**。
    private func blockingReason(_ status: TunnelStatus) -> String? {
        switch status.state {
        case "no_binary":
            return tr("内核没有找到 cloudflared。装一个（brew install cloudflared）之后重开即可。",
                      "The kernel could not find cloudflared. Install it (brew install cloudflared) and try again.")
        case "no_account":
            return tr("还差一次账号授权：在终端里跑一次 cloudflared tunnel login。",
                      "One authorization step is missing: run `cloudflared tunnel login` once in a terminal.")
        case "failed":
            return status.lastError
        default:
            return nil
        }
    }

    /// 开关：走专门的端点而不是 PATCH 设置。
    ///
    /// 开关与"真的把它跑起来"是同一件事的两半，发两次请求会让中间那一刻的
    /// 状态没有意义（设置说开着、进程没起来）。
    private var binding: Binding<Bool> {
        Binding(
            get: { enabled },
            set: { want in
                enabled = want
                Task { await apply(want) }
            })
    }

    private func apply(_ want: Bool) async {
        busy = true
        defer { busy = false }
        do {
            let next = want
                ? try await model.kernel.enableTunnel()
                : try await model.kernel.disableTunnel()
            status = next
            enabled = next.enabled
            await model.refreshAll()
        } catch {
            // 失败时把开关拨回去：留着一个"开着但什么都没发生"的开关，
            // 比明确报错更让人困惑。
            enabled = !want
            model.errorMessage = error.localizedDescription
        }
    }
}
