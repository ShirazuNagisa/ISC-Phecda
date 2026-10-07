import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import ISCCore

/// 「Mizar 配置」页 —— 手机端（ISC Mizar）接入这台服务端的入口。
///
/// # 为什么这一页只留三块
///
/// 它开启的不是一个设置开关，而是**把内核的管理面在网络上暴露一份**。
/// 因此这一页要回答的问题只有三个，而且都要用看得见的东西回答：
///
///   1. 现在到底开着没有；
///   2. 怎么把一台新手机接进来（二维码 + 配对链接）；
///   3. 接进来的是谁，以及怎么把它请出去。
///
/// 其余的东西都有更该待的地方：推送凭据归独立模块 ISC-Ap，访问日志要查的
/// 时候走 `isc remote status`，公网子域名的记录由内核自己维护。把它们堆在
/// 这里，只会让"手机怎么连上"这一个问题变长。
///
/// 界面本身不做任何功能性判断：开关、角色、二维码内容、设备状态全部来自
/// 内核。这一页只负责把它们画出来 —— 这也是它能被信任的原因。
struct RemoteView: View {
    @Bindable var model: AppModel

    /// 待吊销的设备（点"吊销"之后先确认一次）。
    @State private var pendingRevoke: RemoteDevice?
    @State private var roleSelection = "viewer"
    @State private var showingPairing = false
    /// 能承载公网子域名的域名。
    ///
    /// 这一页不为此提供选择器，只在开启公网访问时用它补上"挑一个"这一步 ——
    /// 列表里只有一个域名时，它就是唯一的选择。
    @State private var publicDomains: [RemotePublicDomain] = []
    @State private var busy = false

    private var status: RemoteStatus? { model.remoteStatus }

    /// 页面名。页面内的标题与窗口标题共用一处，避免两处各写一遍而漂移。
    private var pageTitle: String { tr("Mizar 配置", "Mizar") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                intro
                statusCard
                if status?.enabled == true {
                    pairingCard
                    devicesCard
                } else {
                    disabledHint
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(pageTitle)
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
        VStack(alignment: .leading, spacing: 6) {
            Text(pageTitle)
                .font(.title2.weight(.semibold))
            Text(tr("使用 iOS 移动端 ISC Mizar 远程访问这台机器上 Phecda 的资源占用与服务状态，以及简略配置 DNS。",
                    "Use ISC Mizar on iOS to remotely check Phecda's resource usage and service status on this machine, and to make quick changes to DNS."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 开关

    /// 这一块只回答"要不要开"：先开监听，再决定这个口子露在哪里。
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
            }

            if status?.hasError == true {
                Label(status?.lastError ?? "", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // 公网访问与上面的开关同处一块，而不是单独一张卡。
            //
            // 两者讲的是同一件事的两面：开关决定"要不要开一个口子"，
            // 公网访问决定"这个口子露在哪里"。它并不比开关更值得占一块地方。
            HStack(spacing: 12) {
                Toggle(tr("公网访问", "Public access"), isOn: publicEnabledBinding)
                    .toggleStyle(.switch)
                    .disabled(busy)
                Spacer()
                if let host = status?.public?.host, !host.isEmpty {
                    Label(host, systemImage: "globe")
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Text(tr("默认开启：在你自己的域名下建一条随机子域名，指向这台机器的公网 IPv6，并给它签一张受信任的证书，手机因此在任何网络下都能连上。代价是全世界都能扫到这个监听 —— 域名还会出现在证书透明日志里，那不是秘密；安全完全靠设备令牌与限流。",
                    "On by default: it creates a random subdomain under your own domain, pointing at this machine's public IPv6 with a trusted certificate, so the phone can connect from any network. The trade-off is that the internet can find this listener — and the domain shows up in Certificate Transparency logs, so it is not a secret. Security rests entirely on device tokens and rate limiting."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 开关开着却没有域名：差的就是这一步。不说清楚的话，用户只会
            // 看到一个"已开启"却什么都没发生。
            if let publicStatus = status?.public, publicStatus.enabled,
               (publicStatus.domain ?? "").isEmpty {
                Text(tr("还没有能承载公网地址的域名：先去 DNS 页添加一个服务商，再回来重新打开这个开关。",
                        "No domain can host the public address yet — add a provider in the DNS section, then turn this switch on again."))
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 内核跑在 Phecda 进程里，这一点必须显式地说：不说的话，用户会
            // 以为关掉窗口之后手机还能连上。
            Text(tr("提示：内核随 Phecda 一起运行。关掉 Phecda 之后手机就联系不上它；需要长期可用，请把内核安装为系统服务。",
                    "Note: the kernel runs inside Phecda. Closing Phecda makes it unreachable from your phone. For always-on access, install the kernel as a system service."))
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

            Text(tr("用 ISC Mizar 扫二维码接入；扫不了码时，可以复制配对链接，粘到 Mizar 里。",
                    "Scan the QR code with ISC Mizar — or, if scanning is not possible, copy the pairing link and paste it into Mizar."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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

    /// 公网访问当前是否开着。
    ///
    /// 缺失时按**开**呈现：默认值是内核的事（现在是开），界面这一层必须与
    /// 它一致 —— 写成 `?? false` 会让一台还没上报这一项的机器显示成"关"，
    /// 与它实际在做的事正好相反。
    private var publicEnabled: Bool { status?.public?.enabled ?? true }

    /// 公网访问开关。
    ///
    /// 用 Binding 包装而不是直接绑 status：`status` 是只读的远端快照，
    /// 而开关要先提交再刷新。
    private var publicEnabledBinding: Binding<Bool> {
        Binding(
            get: { publicEnabled },
            set: { setPublicEnabled($0) }
        )
    }

    private func setPublicEnabled(_ enabled: Bool) {
        // 开启时必须有一个域名来承载子域名，而这一页不再提供域名选择器：
        // 列表里只有一个域名时它就是唯一的选择，多个时取第一个 ——
        // 结果会立刻显示在开关旁边的 host 上。
        if enabled, (status?.public?.domain ?? "").isEmpty, let first = publicDomains.first {
            patchPublic(enabled: true, domain: first.domain)
            return
        }
        patchPublic(enabled: enabled, domain: nil)
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

    private func refreshPublicDomains() async {
        publicDomains = (try? await model.kernel.remotePublicDomains()) ?? []
    }
}

// MARK: - 配对二维码

/// 配对弹窗：二维码 + 可复制的配对链接 + 倒计时。
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
                          message: tr("请重新生成一次；下面的配对链接也可以直接复制到 Mizar 里粘贴配对。",
                                      "Generate it again — or copy the pairing link below and paste it into Mizar."))
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

            // 配对密钥只走二维码与配对链接：指纹随链接一起交给 Mizar，
            // 核对是内建的。把指纹摆在这里只会让用户以为还得自己比一遍。
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
