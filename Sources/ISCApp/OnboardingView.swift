import SwiftUI
import AppKit
import ISCCore

/// 首次安装之后的引导。
///
/// # 形态
///
/// 它**铺满整个窗口**，而不是一个 sheet：四页里有两页要用户真的填东西
/// （凭据、站点），sheet 的尺寸与圆角让那些输入框挤在一小块里，而旁边
/// 就是空着的窗口。
///
/// 每页左边是 Phecda 的图标、右边是控件，上一步/下一步在右下角。
///
/// # 四页各自要让用户得到什么
///
///   1. **欢迎** —— 知道这是什么、内核起没起来；
///   2. **DNS 服务商** —— 建出第一个凭据（没有它，后面什么都做不了）；
///   3. **网络环境** —— 这台机器外面连不进来时，把中继开起来；
///   4. **第一个服务** —— 真的发布一个站点（可跳过）。
///
/// 每一步都有退路：右上角常驻「跳过引导」。一个把人卡在第三步的向导，
/// 比没有向导更糟 —— 他会在还没用上产品之前先学会讨厌它。
struct OnboardingView: View {
    @Bindable var model: AppModel

    @State private var page: Page = .welcome

    enum Page: Int, CaseIterable {
        case welcome, provider, network, firstService
    }

    var body: some View {
        HStack(spacing: 0) {
            markPane
            Divider()
            contentPane
        }
        .frame(minWidth: 900, minHeight: 580)
        .background(.background)
    }

    // MARK: - 左：图标

    /// 图标栏。
    ///
    /// 用资源目录里的 `AppMark` 而不是 `NSApp.applicationIconImage`：从
    /// Xcode 跑 SwiftPM 包时进程没有应用包，那个属性会退化成通用图标 ——
    /// 也就是这半边的意义整个消失。
    ///
    /// 必须显式指定 `bundle: .module`。资源目录是 ISCApp 的 SwiftPM 资源，
    /// 编译进的是 `ISCPhecda_ISCApp.bundle`，而 `Image("…")` 默认只在**主
    /// bundle** 里找 —— 从 Xcode 跑时主 bundle 里什么都没有，结果是左半边
    /// 一片空白，且不报任何错。
    private var markPane: some View {
        VStack(spacing: 18) {
            Spacer()
            Image("AppMark", bundle: .module)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 168, height: 168)
                .clipShape(.rect(cornerRadius: 36))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            Text("ISC Phecda")
                .font(.title3.weight(.semibold))
            Spacer()
            pageDots
            Spacer().frame(height: 22)
        }
        .frame(width: 320)
        .frame(maxHeight: .infinity)
        .background(.quaternary.opacity(0.35))
    }

    private var pageDots: some View {
        HStack(spacing: 7) {
            ForEach(Page.allCases, id: \.rawValue) { item in
                Circle()
                    .fill(item == page ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
    }

    // MARK: - 右：内容

    private var contentPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button(tr("跳过引导", "Skip setup")) { finish(goToServices: false) }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)

            // 滚动区吃掉**剩余的全部高度**，底栏才能被顶到窗口底部。
            //
            // 不显式撑开的话，VStack 按内容的自然高度收拢，整块内容在
            // HStack 里被垂直居中，而底栏就落到了窗口外面 —— 表现是
            // "上一步/下一步不见了"，但代码里一切正常。
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch page {
                    case .welcome: welcomePage
                    case .provider: providerPage
                    case .network: networkPage
                    case .firstService: firstServicePage
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 内核没起来时，后面三页都做不了事。明说，而不是让控件静默失灵。
    @ViewBuilder private var kernelNotice: some View {
        if model.phase != .running {
            Label(tr("内核还没有就绪，这一页上的操作暂时不可用。",
                     "The kernel is not ready yet, so this page cannot be used."),
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    // MARK: - 第一页

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading(tr("欢迎使用 ISC Phecda", "Welcome to ISC Phecda"),
                    tr("它把一台普通的 Mac 变成能对外提供服务的机器：跑你的站点、自动配好域名与证书、并从公网访问。",
                       "It turns an ordinary Mac into a machine that serves the internet: runs your sites, wires up DNS and certificates, and makes them reachable from outside."))

            VStack(alignment: .leading, spacing: 10) {
                bullet("server.rack", tr("站点跑在本地", "Sites run locally"),
                       tr("给一个源码目录，Phecda 认得技术栈并把它跑起来。",
                          "Point at a source folder; Phecda detects the stack and runs it."))
                bullet("lock.shield", tr("域名与证书自动配", "DNS and certificates, handled"),
                       tr("用你自己的 DNS 服务商凭据，记录与证书都不用你手动碰。",
                          "Using your own DNS provider credential — no manual records or certificates."))
                bullet("globe", tr("公网可达", "Reachable from outside"),
                       tr("有公网地址时直连；没有时走 Cloudflare 中继。",
                          "Direct when this machine has a public address, via a Cloudflare relay when it does not."))
            }

            kernelStatusCard
        }
    }

    private func bullet(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 内核状态。
    ///
    /// 放在第一页而不是等用户撞上"操作不可用"：后面三页全都要内核，
    /// 而他需要第一眼就知道前提成不成立。
    private var kernelStatusCard: some View {
        HStack(spacing: 8) {
            Circle().fill(model.phase == .running ? .green : .orange).frame(width: 7, height: 7)
            Text(kernelSummary).font(.caption)
            Spacer(minLength: 0)
            if let summary = model.ipStatus?.summary, summary != "—" {
                Text(summary).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }

    private var kernelSummary: String {
        switch model.phase {
        case .running: return tr("内核运行中", "Kernel running")
        case .starting: return tr("内核正在启动…", "Kernel starting…")
        case .stopping: return tr("内核正在停止…", "Kernel stopping…")
        case .failed: return model.errorMessage ?? tr("内核启动失败", "Kernel failed to start")
        case .stopped: return tr("内核未运行", "Kernel not running")
        }
    }

    // MARK: - 第二页

    @State private var providerName: String?
    @State private var label = ""
    @State private var values: [String: String] = [:]
    @State private var openedCredentialPages: Set<String> = []
    @State private var savingCredential = false
    @State private var credentialFailure: String?
    @State private var credentialSaved = false

    private var provider: Provider? { model.providers.first { $0.name == providerName } }

    private var providerPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading(tr("配置你的 DNS 服务商", "Connect your DNS provider"),
                    tr("解析域名、签发证书都要用它。凭据只存在这台机器上，加密保存。",
                       "Used for DNS records and certificate issuance. It stays on this machine, encrypted."))

            kernelNotice

            CredentialFieldsView(model: model,
                                 providerName: $providerName,
                                 label: $label,
                                 values: $values,
                                 openedCredentialPages: $openedCredentialPages)

            if let credentialFailure {
                Text(credentialFailure).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if credentialSaved {
                Label(tr("凭据已保存。", "Credential saved."), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
        }
    }

    // MARK: - 第三页

    /// 用户对"是不是需要中继的网络"的回答。
    ///
    /// 三态而不是布尔量：刚开始是"还没问"，而默认选中一个用户没确认过的
    /// 答案会让人以为那是探测出来的结论。
    @State private var needsRelay: Bool?
    @State private var relayPrefilled = false

    private var networkPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading(tr("这台机器能从公网直接访问吗？", "Can this machine be reached directly?"),
                    tr("校园网、公司网和多数家宽都在网关后面，外面连不进来。如果是这种情况，用 Cloudflare 中继。",
                       "Campus, corporate and most home networks sit behind a gateway that blocks incoming connections. If that is you, use the Cloudflare relay."))

            if let hint = relayHint {
                Label(hint, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("", selection: relayBinding) {
                Text(tr("需要中继", "I need the relay")).tag(true)
                Text(tr("能直接访问，不用中继", "Direct access works")).tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if needsRelay == true {
                Divider()
                TunnelControls(model: model, showsHeader: false)
            } else if needsRelay == false {
                Text(tr("那就不开中继：域名会直接指向这台机器的公网地址，由反向代理接住。前提是那个地址真的能从外面连上。",
                        "Then the relay stays off: domains point straight at this machine's public address and the reverse proxy answers. That requires the address to be genuinely reachable from outside."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            // 只在第一次进入时预选。用户改过之后回到这一页，不该被我们的
            // 猜测覆盖掉他的选择。
            guard !relayPrefilled else { return }
            relayPrefilled = true
            if let status = model.ipStatus {
                needsRelay = status.suggestsRelay
            }
        }
    }

    /// 自动判断的依据。说清楚它是**怎么推出来的**，用户才敢改。
    private var relayHint: String? {
        guard let status = model.ipStatus, let interfaces = status.interfaces, !interfaces.isEmpty else {
            return nil
        }
        if status.hasPublicAddress {
            return tr("检测到这台机器有公网 IPv6 地址，通常可以直连。",
                      "This machine has a public IPv6 address, so direct access usually works.")
        }
        let addresses = interfaces.flatMap { $0.ipv4 ?? [] }.joined(separator: "、")
        return tr("检测到这台机器的地址是 \(addresses.isEmpty ? "私有地址" : addresses)，没有公网 IPv6 —— 外面通常连不进来。",
                  "This machine's addresses are \(addresses.isEmpty ? "private" : addresses) with no public IPv6 — incoming connections are usually blocked.")
    }

    private var relayBinding: Binding<Bool> {
        Binding(get: { needsRelay ?? false }, set: { needsRelay = $0 })
    }

    // MARK: - 第四页

    @State private var sourcePath = ""
    @State private var inspection: SourceInspection?
    @State private var presetID = ""
    @State private var serviceName = ""
    @State private var domains = ""
    @State private var publishing = false
    @State private var publishFailure: String?

    private var firstServicePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading(tr("发布你的第一个服务", "Publish your first site"),
                    tr("给一个源码目录。Phecda 会识别技术栈、准备运行时并把它跑起来。这一步可以跳过。",
                       "Point at a source folder. Phecda detects the stack, prepares the runtime and runs it. You can skip this."))

            kernelNotice

            HStack(spacing: 10) {
                Button(tr("选择源码目录…", "Choose a folder…")) { chooseFolder() }
                    .buttonStyle(.glass)
                    .disabled(model.phase != .running || publishing)
                Text(sourcePath.isEmpty ? tr("尚未选择", "Nothing selected") : sourcePath)
                    .font(.caption).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(sourcePath.isEmpty ? .secondary : .primary)
            }

            if let inspection {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("识别结果", "Detected")).font(.callout.weight(.medium))
                    ForEach(inspection.evidence.prefix(5)) { item in
                        Text("· \(item.file) — \(item.signal)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let warnings = inspection.warnings, !warnings.isEmpty {
                        ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption2).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
            }

            if inspection != nil {
                VStack(alignment: .leading, spacing: 10) {
                    labeled(tr("名称", "Name")) {
                        TextField("my-site", text: $serviceName)
                            .textFieldStyle(.roundedBorder)
                    }
                    labeled(tr("域名（可留空）", "Domain (optional)")) {
                        TextField("www.example.com", text: $domains)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            if let publishFailure {
                Text(publishFailure).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - 底栏

    private var footer: some View {
        HStack(spacing: 10) {
            if page == .firstService {
                Button(tr("跳过", "Skip")) { finish(goToServices: false) }
                    .buttonStyle(.glass)
            }
            Spacer()
            if page != .welcome {
                Button(tr("上一步", "Back")) { back() }
                    .buttonStyle(.glass)
            }
            Button(nextTitle) { Task { await goNext() } }
                .buttonStyle(.glassProminent)
                .disabled(!canAdvance)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var nextTitle: String {
        switch page {
        case .welcome: return tr("开始设置", "Get started")
        case .provider: return tr("下一步", "Next")
        case .network: return tr("下一步", "Next")
        case .firstService: return tr("完成并发布", "Finish and publish")
        }
    }

    private var canAdvance: Bool {
        switch page {
        case .welcome: return true
        case .provider:
            // 已经存过就直接放行；否则要求填完整 —— 一个允许空着过去的
            // "必填步骤"会让用户以为后面某处还能补，而其实不能。
            return credentialSaved || (model.phase == .running
                && CredentialDraft.isValid(provider: provider, label: label, values: values))
        case .network: return needsRelay != nil
        case .firstService:
            if publishing { return false }
            // 没选目录时只能走"跳过" —— 按钮上写的是"完成并发布"，
            // 让它带着空目录点下去是一次必然失败的操作。
            return inspection != nil && !serviceName.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func back() {
        guard let previous = Page(rawValue: page.rawValue - 1) else { return }
        page = previous
    }

    private func goNext() async {
        switch page {
        case .welcome:
            page = .provider
        case .provider:
            if !credentialSaved {
                guard await saveCredential() else { return }
            }
            page = .network
        case .network:
            page = .firstService
        case .firstService:
            await publish()
        }
    }

    // MARK: - 动作

    private func saveCredential() async -> Bool {
        guard let provider else { return false }
        savingCredential = true
        credentialFailure = nil
        defer { savingCredential = false }
        do {
            _ = try await model.kernel.createCredential(
                CredentialDraft.input(provider: provider, label: label, values: values))
            credentialSaved = true
            await model.refreshAll()
            return true
        } catch {
            credentialFailure = error.localizedDescription
            return false
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = tr("选择", "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sourcePath = url.path
        Task { await inspect(url.path) }
    }

    private func inspect(_ path: String) async {
        publishFailure = nil
        do {
            let result = try await model.kernel.inspectSource(path: path)
            inspection = result
            presetID = result.recommendedPresetId
            if serviceName.isEmpty {
                serviceName = URL(fileURLWithPath: path).lastPathComponent
            }
        } catch {
            publishFailure = error.localizedDescription
        }
    }

    private func publish() async {
        guard !presetID.isEmpty else {
            publishFailure = tr("没有识别出可用的技术栈。", "No runnable stack was detected.")
            return
        }
        publishing = true
        publishFailure = nil
        defer { publishing = false }
        do {
            let list = domains
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            var input = AppCreateRequest(name: serviceName,
                                         presetId: presetID,
                                         sourcePath: sourcePath)
            input.domains = list.isEmpty ? nil : list
            _ = try await model.kernel.createApp(input)
            finish(goToServices: true)
        } catch {
            publishFailure = error.localizedDescription
        }
    }

    /// 结束引导。
    ///
    /// 落标记而不是只关掉界面：没有它，用户每次启动都会被再问一遍 ——
    /// 那是最容易被当成"这个应用有毛病"的一类打扰。
    private func finish(goToServices: Bool) {
        model.dismissOnboarding()
        if goToServices {
            model.section = .services
        } else if page == .firstService {
            model.section = AppSection.initial
        }
    }
}
