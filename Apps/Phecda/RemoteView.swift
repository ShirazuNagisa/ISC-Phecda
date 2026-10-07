import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import ISCCore

/// 「远程访问」页 —— 手机端（ISC Mizar）接入这台服务端的入口。
///
/// # 为什么这一页值得单独存在
///
/// 它开启的不是一个设置开关，而是**把内核的管理面在网络上暴露一份**。
/// 因此这一页需要回答三个问题，而且都要用看得见的东西回答：
///
///   1. 现在到底开着没有（不是"设置里是 true"，而是"端口真的在听"）；
///   2. 手机怎么接进来（二维码 + 六位码 + 一条条候选地址）；
///   3. 接进来的是谁（设备列表 + 访问日志）。
///
/// 界面本身不做任何功能性判断：开关、角色、二维码内容、设备状态全部来自
/// 内核。这一页只负责把它们画出来 —— 这也是它能被信任的原因。
struct RemoteView: View {
    @Bindable var model: AppModel

    /// 待吊销的设备（点"吊销"之后先确认一次）。
    @State private var pendingRevoke: RemoteDevice?
    @State private var roleSelection = "viewer"
    @State private var showingPairing = false
    @State private var showingApns = false
    @State private var pushTestResult: ServiceActionResult?
    @State private var publicDomains: [RemotePublicDomain] = []
    @State private var busy = false

    private var status: RemoteStatus? { model.remoteStatus }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                intro
                statusCard
                if status?.enabled == true {
                    // 公网访问紧挨着开关，而不是埋在配对卡片下面。
                    //
                    // 两者讲的是同一件事的两面：开关决定"要不要开一个口子"，
                    // 公网访问决定"这个口子露在哪里"。而配对卡片很长
                    // （它带着二维码），放在它下面会让这一整块落在
                    // 折叠线以下 —— 用户根本不知道它存在。
                    publicCard
                    pairingCard
                    devicesCard
                    pushCard
                    logCard
                } else {
                    disabledHint
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showingPairing) {
            if let session = model.pairingSession {
                PairingSheet(session: session) {
                    // 关掉时顺手取消会话：一个被关闭的窗口背后留着一个
                    // 有效的配对码，是那种"看起来什么都没发生"的风险。
                    if let id = model.pairingSession?.id {
                        Task { try? await model.kernel.cancelRemotePairing(id) }
                    }
                    model.pairingSession = nil
                    showingPairing = false
                }
            }
        }
        .confirmationDialog(
            tr("吊销这台设备？", "Revoke this device?"),
            isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }),
            presenting: pendingRevoke
        ) { device in
            Button(tr("吊销", "Revoke"), role: .destructive) { revoke(device) }
            Button(tr("取消", "Cancel"), role: .cancel) { pendingRevoke = nil }
        } message: { device in
            Text(device.isDerived
                 ? tr("它是由另一台设备派生出来的，吊销后需要重新配对。",
                      "It was derived from another device; it will need to pair again.")
                 : tr("它会立即断开，并且一并断掉由它派生的设备（例如手表）。",
                      "It disconnects immediately, along with any device derived from it (such as a watch)."))
        }
    }

    // MARK: - 说明

    private var intro: some View {
        // 强调用手写的三段拼接，而不是字符串里的 `**`：`Text` 只在
        // **字面量**上解析 Markdown，而 `tr(zh, en)` 返回的是运行时
        // 字符串 —— 那时 `**` 会原样显示在界面上。
        //
        // 拼接用插值而不是 `Text + Text`：后者从 macOS 26 起被弃用，
        // 而 `\(Text(...).bold())` 仍然保留中间那段的加粗。
        //
        // 三段先落到常量里，是因为插值表达式不能跨行 —— 直接写在
        // 字符串里的话，那段换行的长文案会把字面量截断。
        let lead = tr("这是一条", "This is a ")
        let strong = tr("独立的监听与认证链", "separate listener with its own auth chain")
        let tail = tr("：自签证书、按设备签发的令牌，与本地管理通道互不影响。本地令牌永远不会离开这台机器。",
                      ": a self-signed certificate and per-device tokens. It does not touch the local management channel, and the local token never leaves this machine.")

        return VStack(alignment: .leading, spacing: 6) {
            Text(tr("远程访问", "Remote Access"))
                .font(.title2.weight(.semibold))
            Text(tr("让 iPhone、iPad 与 Apple Watch 上的 ISC Mizar 查看这台机器的服务状态与资源占用，并远程改动 DNS 解析。手机在同一个局域网里直接连；服务端有公网地址时，手机在任何网络下都能连（见下面的公网访问）。",
                    "Let ISC Mizar on iPhone, iPad and Apple Watch watch this machine's services and resource usage, and edit DNS records from afar. The phone connects directly when it is on the same network, and from anywhere once this machine has a public address (see public access below)."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(Text(lead))\(Text(strong).bold())\(Text(tail))")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 状态与开关

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Toggle(tr("开启远程访问", "Enable remote access"), isOn: Binding(
                    get: { status?.enabled ?? false },
                    set: { setEnabled($0) }))
                    .toggleStyle(.switch)
                    .disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }

            // 端口输入框已去掉。
            //
            // 端口是**固定的 8788**，而改它需要同时改防火墙与已配对设备
            // 里的记录 —— 一个能被误触的输入框在这里只会制造支持问题。
            // 需要改的话走 `isc settings set --remote-port`。

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                row(tr("状态", "State"), stateText)
                if status?.enabled == true {
                    // 公钥指纹与证书有效期不再显示。
                    //
                    // 指纹当初是给"手输六位码"那条路人工核对用的，
                    // 而六位码已删除 —— 二维码与配对链接自带指纹，
                    // 核对是内建的。
                    row(tr("已配对设备", "Paired devices"), String(status?.deviceCount ?? 0))
                }
            }

            // 候选地址列表已去掉：二维码与配对链接里都带着它们，
            // 而"手机可以尝试的地址"原本是给手输那条路抄的。
            // 需要排查时用 `isc remote status`。

            if status?.hasError == true {
                Label(status?.lastError ?? "", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 这一条必须显式地说：内核跑在 Phecda 进程里，而手机关掉之后
            // 只有系统服务能把它拉回来。
            Text(tr("提示：内核随 Phecda 一起运行。关掉 Phecda 之后手机就联系不上它（也收不到推送）；需要长期可用，请把内核安装为系统服务。",
                    "Note: the kernel runs inside Phecda. Closing Phecda makes it unreachable from your phone (and stops push). For always-on access, install the kernel as a system service."))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        // 域名列表只在进入这一页时拉一次：它可能打服务商的 API，
        // 而用户不会在这一页上停留到需要它过期。
        .task { await refreshPublicDomains() }
    }

    private var disabledHint: some View {
        EmptyHint(
            symbol: "antenna.radiowaves.left.and.right.slash",
            title: tr("远程访问未开启", "Remote access is off"),
            message: tr("开启之后，手机才能连上这台机器。默认关闭：在网络上开一个口子是需要你明确决定的动作。",
                        "Turn it on so your phone can reach this machine. It is off by default: opening a port should be a deliberate choice."))
    }

    // MARK: - 配对

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("配对一台新设备", "Pair a new device")).font(.headline)

            HStack(spacing: 12) {
                Picker(tr("权限", "Role"), selection: $roleSelection) {
                    Text(tr("只读监控", "Read-only")).tag("viewer")
                    Text(tr("可改 DNS", "Can edit DNS")).tag("operator")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                Button {
                    startPairing()
                } label: {
                    Label(tr("生成配对二维码", "Show pairing code"), systemImage: "qrcode")
                }
                .buttonStyle(.glassProminent)
                .disabled(busy)

                Spacer()
            }

            Text(roleSelection == "operator"
                 ? tr("可改 DNS：除只读监控外，还能增删改 DNS 记录、启停解析任务与站点、手动续期证书。",
                      "Can edit DNS: everything read-only can do, plus creating, updating and deleting DNS records, starting/stopping DDNS tasks and sites, and renewing certificates.")
                 : tr("只读监控：只能看，改不了任何东西。手表用的就是这个级别。",
                      "Read-only: it can look but not touch. This is the level the watch uses."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    // MARK: - 公网访问

    private var publicCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(tr("公网访问", "Public access")).font(.headline)
                Spacer()
                if let publicStatus = status?.public, publicStatus.enabled {
                    Label(publicStatus.host ?? tr("正在建立", "Setting up"),
                          systemImage: "globe")
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            // 这一段的措辞是**刻意**的：公网访问与局域网监听不是同一件事，
            // 代价也不同。用户在这里做的决定会把内核暴露在互联网上。
            Text(tr("在**你自己的**域名下建一条随机子域名，指向这台机器的公网 IPv6，并给它签一张受信任的证书。这样手机在任何网络上都能连上。",
                    "Creates a random subdomain under **your own** domain, pointing at this machine's public IPv6 with a trusted certificate, so the phone can connect from any network."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(tr("开启公网访问", "Enable public access"), isOn: publicEnabledBinding)
                .toggleStyle(.switch)
                .disabled(busy)

            if status?.public?.enabled == true {
                publicDetails
            } else {
                Text(tr("默认关闭。开启之后全世界都能扫到这个监听 —— 域名还会出现在证书透明日志里，那不是秘密。安全完全靠设备令牌与限流。",
                        "Off by default. Once on, the internet can find this listener — and the domain appears in Certificate Transparency logs, so it is not a secret. Security rests entirely on device tokens and rate limiting."))
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private var publicDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 域名选择器。
            //
            // 让用户只回答一个他能回答的问题：**挂在哪个域名下**。
            // 哪把凭据、哪个区域由这个域名唯一决定 —— 让他填两个内部
            // ID 是在要求他心算一件内核明明知道的事，而他没有任何
            // 办法验证自己填对了。
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text(tr("挂在域名下", "Under domain")).foregroundStyle(.secondary)
                    if publicDomains.isEmpty {
                        Text(tr("还没有能建记录的域名，先去 DNS 页添加一个服务商",
                                "No domain can host records yet — add a credential in the DNS section"))
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Picker("", selection: publicDomainBinding) {
                            Text(tr("未选择", "Not selected")).tag("")
                            ForEach(publicDomains) { item in
                                Text("\(item.domain) · \(item.provider)").tag(item.domain)
                            }
                        }
                        .labelsHidden()
                        .disabled(busy)
                    }
                }
                if let host = status?.public?.host {
                    row(tr("子域名", "Subdomain"), host)
                }
                if let ipv6 = status?.public?.ipv6 {
                    row(tr("AAAA", "AAAA"), ipv6)
                }
                if let ipv4 = status?.public?.ipv4 {
                    row(tr("A", "A"), ipv4)
                }
            }

            if let check = status?.public?.lastCheck {
                Label(check.detail ?? "",
                      systemImage: check.isReachable ? "checkmark.seal.fill"
                                 : (check.isUnknown ? "questionmark.circle" : "exclamationmark.triangle"))
                    .font(.caption)
                    .foregroundStyle(check.isReachable ? Color.green
                                     : (check.isUnknown ? Color.secondary : Color.orange))
                    .fixedSize(horizontal: false, vertical: true)
            } else if status?.public?.host != nil {
                Text(tr("可达性还没测过。最准的测法是：**手机关掉 Wi-Fi 用蜂窝数据**，打开子域名看一眼能不能连上。",
                        "Reachability has not been tested. The most accurate test: turn off Wi-Fi on your phone, use cellular data, and open the subdomain."))
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // IPv6 是这条路唯一的地基，而它不总是通的。
            Text(tr("需要一条能从外网路由进来的公网 IPv6，以及路由器放行这个端口。手机也必须在有 IPv6 的网络上（蜂窝数据通常有）。",
                    "Needs a globally routable IPv6 address and a router that lets the port through. The phone must also be on a network with IPv6 (cellular usually is)."))
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(tr("立即同步", "Sync now")) { syncPublic() }
                    .disabled(busy || (status?.public?.domain ?? "").isEmpty)
                Button(tr("删除子域名与记录", "Delete subdomain and records"), role: .destructive) {
                    deletePublic()
                }
                .disabled(busy)
            }
        }
    }

    // MARK: - 设备

    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tr("已配对的设备", "Paired devices")).font(.headline)
                Spacer()
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(tr("刷新", "Refresh"))
            }

            if model.remoteDevices.isEmpty {
                Text(tr("还没有设备配对。点上面的按钮生成一个二维码。",
                        "No devices yet. Use the button above to show a pairing code."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.remoteDevices) { device in
                    deviceRow(device)
                    if device.id != model.remoteDevices.last?.id { Divider() }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private func deviceRow(_ device: RemoteDevice) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // 派生的设备缩进一格：用户看到手表时会想知道"它是从哪来的"，
            // 而那个问题的答案决定了吊销哪一台。
            Image(systemName: device.isDerived ? "applewatch" : "iphone")
                .foregroundStyle(device.revoked ? .secondary : .primary)
                .padding(.leading, device.isDerived ? 16 : 0)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(device.label).font(.callout).fontWeight(.medium)
                    Text(device.revoked ? tr("已吊销", "Revoked") : roleLabel(device.role))
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(device.revoked ? Color.secondary.opacity(0.2) : Color.accentColor.opacity(0.15),
                                    in: .capsule)
                }
                Text(detailLine(device))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if device.isDerived, let parent = device.parentDeviceId {
                    Text(tr("派生自 \(parent.prefix(8))…", "Derived from \(parent.prefix(8))…"))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if !device.revoked {
                if status?.apnsConfigured == true {
                    Button {
                        testPush(device)
                    } label: {
                        Image(systemName: "paperplane")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help(tr("给这台设备发一条测试推送", "Send a test push to this device"))
                }
                Button(tr("吊销", "Revoke"), role: .destructive) { pendingRevoke = device }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
    }

    private func detailLine(_ device: RemoteDevice) -> String {
        var parts: [String] = []
        if let platform = device.platform, !platform.isEmpty {
            parts.append(device.model?.isEmpty == false ? "\(platform) \(device.model!)" : platform)
        }
        if let os = device.osVersion, !os.isEmpty { parts.append(os) }
        if let seen = device.lastSeenAt {
            parts.append(tr("最后访问 \(seen.formatted(date: .abbreviated, time: .shortened))",
                            "last seen \(seen.formatted(date: .abbreviated, time: .shortened))"))
        } else {
            parts.append(tr("从未访问过", "never seen"))
        }
        if let ip = device.lastSeenIp, !ip.isEmpty { parts.append(ip) }
        return parts.joined(separator: " · ")
    }

    // MARK: - 推送

    private var pushCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tr("推送通知", "Push notifications")).font(.headline)
                Spacer()
                if status?.apnsConfigured == true {
                    Label(tr("已配置", "Configured"), systemImage: "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(.green)
                }
            }

            Text(tr("站点挂了、证书签发失败、解析更新失败时，内核会直接推到你的手机上 —— 手机在后台被系统挂起时没有能力自己轮询。",
                    "When a site goes down, a certificate fails or a DNS update fails, the kernel pushes straight to your phone — a backgrounded phone cannot poll by itself."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if status?.apnsConfigured == true {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    row(tr("Team ID", "Team ID"), status?.apnsStatus?.teamId ?? "—")
                    row(tr("Key ID", "Key ID"), status?.apnsStatus?.keyId ?? "—")
                    row(tr("Bundle ID", "Bundle ID"), status?.apnsStatus?.bundleId ?? "—")
                }
                Text(tr("私钥已加密存储，不会再被读出来。",
                        "The private key is stored encrypted and is never read back out."))
                    .font(.caption2).foregroundStyle(.tertiary)

                HStack {
                    Button(tr("替换凭据…", "Replace credentials…")) { showingApns = true }
                    Button(tr("删除", "Delete"), role: .destructive) {
                        model.execute { try await self.model.kernel.deleteApnsCredentials() }
                    }
                }
            } else {
                // 说清楚**前提**：APNs 需要付费的 Apple Developer 账号。
                // 不说的话，用户会以为是自己哪里填错了。
                Text(tr("需要一份 .p8 鉴权密钥（在付费的 Apple Developer 账号下创建）。填好之后，已配对的手机才会收到推送。",
                        "Requires a .p8 authorisation key, created under a paid Apple Developer account. Paired phones receive push only after it is set."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    showingApns = true
                } label: {
                    Label(tr("填入 APNs 凭据…", "Enter APNs credentials…"), systemImage: "key")
                }
                .buttonStyle(.glassProminent)
            }

            if let result = pushTestResult {
                Label(result.message ?? "", systemImage: result.ok ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(result.ok ? Color.green : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .sheet(isPresented: $showingApns) {
            ApnsCredentialsSheet(model: model) { showingApns = false }
        }
    }

    // MARK: - 访问日志

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tr("访问日志", "Access log")).font(.headline)
                Spacer()
                Button {
                    loadLog()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(tr("刷新", "Refresh"))
            }

            if model.remoteAudit.isEmpty {
                Text(tr("还没有记录。配对、吊销与设备上的写操作都会出现在这里。",
                        "Nothing yet. Pairing, revocation and writes made from a device show up here."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.remoteAudit) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Text(entry.ts.formatted(date: .abbreviated, time: .standard))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 150, alignment: .leading)
                        Text(actionLabel(entry.action))
                            .font(.caption)
                            .frame(width: 150, alignment: .leading)
                        Text(entry.remote ?? "—")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .task { loadLog() }
    }

    // MARK: - 小工具

    private var stateText: String {
        switch status?.state {
        case "running": tr("正在监听", "Listening")
        case "starting": tr("正在启动", "Starting")
        case "failed": tr("启动失败", "Failed to start")
        default: tr("未开启", "Off")
        }
    }

    private func roleLabel(_ role: String) -> String {
        role == "operator" ? tr("可改 DNS", "Can edit DNS") : tr("只读监控", "Read-only")
    }

    /// 审计里的动作名翻译成人话。
    ///
    /// 认不出来的动作**原样显示**而不是隐藏：那是一条真实发生过的记录，
    /// 而"这个我不认识"恰恰是排查时最该看到的信息。
    private func actionLabel(_ action: String) -> String {
        switch action {
        case "remote.pair": tr("配对", "Paired")
        case "remote.pair_failed": tr("配对失败", "Pairing failed")
        case "remote.revoke": tr("吊销设备", "Revoked a device")
        case "remote.unpair": tr("设备自我解绑", "Device unpaired itself")
        case "remote.derive": tr("派生设备", "Derived a device")
        case "remote.settings": tr("改动设置", "Changed settings")
        case "remote.device_update": tr("改动设备", "Changed a device")
        default: action
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.callout).monospacedDigit().textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 动作

    private func setEnabled(_ enabled: Bool) {
        busy = true
        Task {
            // 开关与端口一起提交：分两次会让"刚开的监听"在瞬间用一个
            // 用户已经改过的端口，而那期间手机可能正好在扫码。
            var patch = RemoteSettingsPatch()
            patch.enabled = enabled
            // 端口不进 patch：界面不再提供改它的入口。它是固定 8788 ——
            // 改它要同时改防火墙与已配对设备里的记录，需要时走
            // `isc settings set --remote-port`。
            do { model.remoteStatus = try await model.kernel.updateRemoteSettings(patch) }
            catch { model.errorMessage = error.localizedDescription }
            busy = false
            await model.refreshAll()
        }
    }

    private func startPairing() {
        busy = true
        Task {
            do {
                model.pairingSession = try await model.kernel.startRemotePairing(
                    role: roleSelection, label: nil)
                showingPairing = true
            } catch { model.errorMessage = error.localizedDescription }
            busy = false
        }
    }

    private func revoke(_ device: RemoteDevice) {
        pendingRevoke = nil
        model.execute { try await self.model.kernel.revokeRemoteDevice(device.id) }
    }

    /// 公网访问开关。
    ///
    /// 用 Binding 包装而不是直接绑 status：`status` 是只读的远端快照，
    /// 而开关要先提交再刷新。
    private var publicEnabledBinding: Binding<Bool> {
        Binding(
            get: { status?.public?.enabled ?? false },
            set: { setPublicEnabled($0) }
        )
    }

    private var publicDomainBinding: Binding<String> {
        Binding(
            get: { status?.public?.domain ?? "" },
            set: { setPublicDomain($0) }
        )
    }

    private func setPublicEnabled(_ enabled: Bool) {
        if enabled && (status?.public?.domain ?? "").isEmpty, let first = publicDomains.first {
            // 开启时若还没选域名，用列表里的第一个 —— 只有一个域名时
            // 这就是唯一的选择，而让用户"先选域名再开开关"是多一步。
            setPublicDomain(first.domain, enabled: true)
            return
        }
        patchPublic(enabled: enabled, domain: nil)
    }

    private func setPublicDomain(_ domain: String, enabled: Bool? = nil) {
        patchPublic(enabled: enabled ?? (status?.public?.enabled ?? false), domain: domain)
    }

    private func patchPublic(enabled: Bool, domain: String?) {
        busy = true
        Task {
            var patch = KernelSettings()
            patch.remotePublicEnabled = enabled
            if let domain { patch.remotePublicDomain = domain }
            do {
                _ = try await model.kernel.updateSettings(patch)
                await model.refreshAll()
                if enabled { await refreshPublicDomains() }
            } catch {
                model.errorMessage = error.localizedDescription
            }
            busy = false
        }
    }

    private func syncPublic() {
        busy = true
        Task {
            do {
                model.remoteStatus = try await model.kernel.syncRemotePublic()
            } catch {
                model.errorMessage = error.localizedDescription
            }
            busy = false
        }
    }

    private func deletePublic() {
        busy = true
        Task {
            do {
                try await model.kernel.deleteRemotePublic()
                await model.refreshAll()
            } catch {
                // 删除失败**不是**"什么都没做"：台账已清空，但区域里
                // 可能留下一条记录。让用户能据此去 DNS 后台确认。
                model.errorMessage = error.localizedDescription
            }
            busy = false
        }
    }

    private func refreshPublicDomains() async {
        publicDomains = (try? await model.kernel.remotePublicDomains()) ?? []
    }

    private func testPush(_ device: RemoteDevice) {
        pushTestResult = nil
        Task {
            do {
                pushTestResult = try await model.kernel.testPush(deviceID: device.id)
            } catch {
                // 接口本身失败（例如没配凭据）—— 与"发送失败"是两回事，
                // 因此用一条临时结果把它显示在同一处。
                pushTestResult = ServiceActionResult(ok: false, message: error.localizedDescription)
            }
        }
    }

    private func loadLog() {
        Task {
            if let entries = try? await model.kernel.remoteAudit(limit: 50) {
                model.remoteAudit = entries
            }
        }
    }
}

// MARK: - 配对二维码

/// 配对弹窗：二维码 + 六位码 + 倒计时。
///
/// 二维码的**像素**在这里生成，但内容完全来自内核：payload 是契约的一部分，
/// 两个实现意味着两处会漂移，而漂移的后果是"某个版本的 App 扫不出来"。
private struct PairingSheet: View {
    let session: RemotePairingSession
    let onClose: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(spacing: 16) {
            Text(tr("用 ISC Mizar 扫码", "Scan with ISC Mizar"))
                .font(.title3.weight(.semibold))

            if let image = Self.qrImage(from: session.qrPayload) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 260, height: 260)
                    .padding(10)
                    .background(.white, in: .rect(cornerRadius: 12))
            } else {
                EmptyHint(symbol: "qrcode",
                          title: tr("二维码生成失败", "Could not render the QR code"),
                          message: tr("请改用下面的六位码手动配对。",
                                      "Use the six-character code below instead."))
                    .frame(width: 280)
            }

            // 复制配对链接。
            //
            // 它是给"新设备没法扫码"准备的：点一下、发给自己、在新设备上
            // 粘一次即可 —— 那条链接里装着地址、指纹与密钥三样东西，
            // 用户全程不用碰地址。
            if let link = session.qrLink, !link.isEmpty {
                VStack(spacing: 6) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link, forType: .string)
                        copied = true
                    } label: {
                        Label(copied
                              ? tr("已复制", "Copied")
                              : tr("复制配对链接", "Copy pairing link"),
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.glass)

                    // 必须说清楚它的安全属性。
                    //
                    // 链接里带着密钥 —— 在它有效的五分钟里，谁拿到它
                    // 谁就能配对。写一句"别发到聊天软件里"比事后解释
                    // "为什么多了一台不认识的设备"便宜得多。
                    Text(tr("链接里带着配对密钥。五分钟内有效、用一次即失效 —— 别发到聊天软件或群里。",
                            "The link carries the pairing secret. Valid for five minutes, single use — do not post it in a chat."))
                        .font(.caption2).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 320)
            }

            // 六位码与公钥指纹都不再显示。
            //
            // 六位码已删除：它只有约 10 亿种可能、靠按来源锁定兜底，
            // 而二维码与配对链接里的密钥是 256 位。
            //
            // 指纹也不再显示，因为**它不再需要人工核对** ——
            // 指纹当初要"两端比一比"，正是因为六位码不携带任何身份
            // 信息。二维码与链接里装着指纹，核对是内建的。
            Text(session.role == "operator"
                 ? tr("这台设备将获得「可改 DNS」权限", "This device will get DNS editing rights")
                 : tr("这台设备将获得「只读监控」权限", "This device will get read-only access"))
                .font(.caption).foregroundStyle(.secondary)

            // 倒计时用 TimelineView 而不是自己起一个 Task：它由系统按
            // 需要刷新，窗口不可见时不会继续跑。
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(session.expiresAt.timeIntervalSince(context.date)))
                Text(remaining > 0
                     ? tr("还有 \(remaining) 秒过期", "Expires in \(remaining)s")
                     : tr("已过期，请重新生成", "Expired — generate a new one"))
                    .font(.caption)
                    // 两个分支必须是同一个类型：`.secondary` 与 `.orange`
                    // 是两种不同的 ShapeStyle，三元表达式推不出共同类型。
                    .foregroundStyle(remaining > 0 ? Color.secondary : Color.orange)
            }

            Text(tr("手输配对时，手机屏幕上会显示它算出的指纹 —— 上面这串必须与它一致，不一致就取消。",
                    "When typing the code, your phone will show the fingerprint it computed. It must match the one above; if it does not, cancel."))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)

            Button(tr("完成", "Done"), action: onClose)
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 460)
    }

    private static func qrImage(from payload: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        // 纠错级别 M：二维码可能被手机斜着扫、或者在反光的屏幕上，
        // 而 payload 只有几百字节，多出来的冗余完全放得下。
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}

/// 填写 APNs 凭据。
///
/// # 私钥走文件选择器，不从文本框读
///
/// `.p8` 是一把能给**所有用户的手机**发推送的钥匙。让人把它粘进一个
/// 文本框，它就会进剪贴板历史、进而可能进 iCloud 剪贴板同步 ——
/// 而那是一条谁都不会想到要检查的泄漏路径。
struct ApnsCredentialsSheet: View {
    let model: AppModel
    let onClose: () -> Void

    @State private var teamID = ""
    @State private var keyID = ""
    @State private var bundleID = ""
    @State private var keyContents = ""
    @State private var keyFileName = ""
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("APNs 凭据", "APNs credentials")).font(.title3.weight(.semibold))

            Text(tr("在 Apple Developer 后台的 Keys 页面创建一把启用「Apple Push Notifications service」的密钥，下载得到的 .p8 文件就是下面这一份。",
                    "Create a key with “Apple Push Notifications service” enabled on Apple Developer's Keys page; the .p8 you download is the file below."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            labeled(tr("Team ID", "Team ID"), $teamID, placeholder: "ABCDE12345")
            labeled(tr("Key ID", "Key ID"), $keyID, placeholder: "FGHIJ67890")
            labeled(tr("Bundle ID", "Bundle ID"), $bundleID, placeholder: "app.isc.mizar")

            HStack {
                Text(tr(".p8 文件", ".p8 file")).frame(width: 90, alignment: .leading)
                Text(keyFileName.isEmpty ? tr("尚未选择", "Not selected") : keyFileName)
                    .font(.callout)
                    .foregroundStyle(keyFileName.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(tr("选择…", "Choose…")) { choose() }
            }

            if let failure {
                Text(failure).font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(tr("取消", "Cancel"), action: onClose)
                Button(tr("保存", "Save")) { save() }
                    .buttonStyle(.glassProminent)
                    .disabled(busy || teamID.isEmpty || keyID.isEmpty || bundleID.isEmpty || keyContents.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func labeled(_ title: String, _ binding: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            TextField(placeholder, text: binding)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = []
        panel.message = tr("选择从 Apple Developer 下载的 .p8 文件",
                           "Choose the .p8 file downloaded from Apple Developer")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            keyContents = try String(contentsOf: url, encoding: .utf8)
            keyFileName = url.lastPathComponent
            failure = nil
        } catch {
            failure = tr("无法读取这个文件：\(error.localizedDescription)",
                         "Could not read that file: \(error.localizedDescription)")
        }
    }

    private func save() {
        busy = true
        failure = nil
        Task {
            do {
                _ = try await model.kernel.setApnsCredentials(
                    teamID: teamID.trimmingCharacters(in: .whitespaces),
                    keyID: keyID.trimmingCharacters(in: .whitespaces),
                    bundleID: bundleID.trimmingCharacters(in: .whitespaces),
                    privateKey: keyContents)
                await model.refreshAll()
                onClose()
            } catch {
                failure = error.localizedDescription
            }
            busy = false
        }
    }
}
