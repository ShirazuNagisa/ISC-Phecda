import SwiftUI
import ISCCore

/// 设置。
///
/// 刻意**不做成第四个侧栏项**：侧栏只有首页/服务/DNS 三块是产品决定，
/// 而设置是偶尔用一次的东西。它从侧栏底部的齿轮、以及建议里的"去设置"
/// 进入。
///
/// 保存时**整份提交**当前表单：这个界面上看到什么，保存下去就是什么。
/// 只提交"改动过的字段"看起来更精细，但会让"我把邮箱清空了"这种意图
/// 变得不可表达（分不清"没改"和"改成空"）。
struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var acmeEmail = ""
    @State private var useStaging = false
    @State private var acmeCredentialID: String?
    @State private var proxyEnabled = false
    @State private var proxyPort = ""
    @State private var proxyTLS = true
    @State private var logLevel = "info"

    @State private var loaded = false
    @State private var busy = false
    @State private var failure: String?
    @State private var notice: String?

    /// 测试环境的目录地址。生产环境用空串表示。
    private let stagingDirectory = "https://acme-staging-v02.api.letsencrypt.org/directory"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "gearshape").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("设置", "Settings")).font(.headline)
                    Text(tr("证书、反向代理与日志。", "Certificates, reverse proxy and logging."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    certificateSection
                    proxySection
                    advancedSection
                    if let failure {
                        message(failure, tint: .red)
                    }
                    if let notice {
                        message(notice, tint: .green)
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(tr("取消", "Cancel")) { dismiss() }
                Button(tr("保存", "Save")) { Task { await save() } }
                    .buttonStyle(.glassProminent)
                    .disabled(busy)
            }
            .padding(16)
        }
        .frame(width: 560, height: 620)
        .task {
            // 设置还没拉到时先拉一次。否则表单显示的是默认值，而"保存"
            // 会把那些默认值当成用户的意图写回内核 —— 一次静默的覆盖。
            if model.settings == nil { await model.refreshAll() }
            load()
        }
    }

    // MARK: 分区

    private var certificateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(tr("证书", "Certificates"),
                         tr("签发给你的域名，用来自动开启 HTTPS。", "Issued for your domains to enable HTTPS automatically."))

            labeled(tr("联系邮箱", "Contact email")) {
                TextField("you@example.com", text: $acmeEmail)
                    .textFieldStyle(.roundedBorder)
            }
            Text(tr("证书颁发机构需要它才能签发证书。", "The certificate authority requires it before issuing."))
                .font(.caption2).foregroundStyle(.secondary)

            labeled(tr("DNS 凭据", "DNS credential")) {
                Picker("", selection: $acmeCredentialID) {
                    // 默认就是**自动**。
                    //
                    // 这个问题的答案完全由数据决定（域名在哪个区域、
                    // 那个区域在哪把凭据下），让用户在一列"标签 · 服务商"
                    // 里挑一个，是在要求他心算一件内核明明知道的事 ——
                    // 而他没有任何办法验证自己挑对了。挑错的症状还离得
                    // 很远：这里一切正常，几天后证书续期时才失败。
                    Text(tr("自动（按域名匹配）", "Automatic (match by domain)")).tag(String?.none)
                    ForEach(dnsCapableCredentials) { credential in
                        Text("\(credential.label) · \(credential.provider)")
                            .tag(String?.some(credential.id))
                    }
                }
                .labelsHidden()
            }
            Text(acmeCredentialID == nil
                 ? tr("内核会按域名找出它属于哪个区域、那把凭据在哪。只有当自动匹配挑错时才需要手动指定。",
                      "The kernel finds which zone the domain belongs to and which credential owns it. Pick one manually only if automatic matching gets it wrong.")
                 : tr("已手动指定：所有域名的 DNS-01 校验都会用这一把凭据。",
                      "Manually pinned: DNS-01 for every domain will use this one credential."))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if dnsCapableCredentials.isEmpty {
                Text(tr("还没有能新建记录的凭据（DNS-01 需要写一条 TXT）。先去 DNS 页添加一个，例如 Cloudflare。",
                        "No credential can create records yet (DNS-01 writes a TXT record). Add one in the DNS section, e.g. Cloudflare."))
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(tr("使用测试环境（签发的证书不被浏览器信任）",
                      "Use staging (issued certificates are not trusted by browsers)"),
                   isOn: $useStaging)
                .toggleStyle(.switch)
            Text(tr("首次配置时建议先用测试环境试一遍：生产环境的失败配额是每小时 5 次。",
                    "Try staging first: production allows only 5 failures per hour."))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var proxySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(tr("反向代理", "Reverse proxy"),
                         tr("把公网请求转发到本机的站点。", "Forwards public requests to your sites."))

            Toggle(tr("启用", "Enabled"), isOn: $proxyEnabled).toggleStyle(.switch)

            labeled(tr("端口", "Port")) {
                TextField("443", text: $proxyPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }
            Text(tr("留空表示使用默认值（HTTPS 443 / HTTP 80）。",
                    "Leave empty for the default (443 for HTTPS, 80 for HTTP)."))
                .font(.caption2).foregroundStyle(.secondary)

            Toggle(tr("为绑定的域名自动申请证书", "Request certificates for bound domains"), isOn: $proxyTLS)
                .toggleStyle(.switch)
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(tr("日志", "Logging"), tr("内核写日志的详细程度。", "How much the kernel logs."))
            Picker("", selection: $logLevel) {
                Text(tr("错误", "Error")).tag("error")
                Text(tr("警告", "Warning")).tag("warn")
                Text(tr("信息", "Info")).tag("info")
                Text(tr("调试", "Debug")).tag("debug")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: 组件

    private func sectionTitle(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.callout).frame(width: 90, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func message(_ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: tint == .red ? "xmark.octagon.fill" : "checkmark.circle.fill")
                .foregroundStyle(tint)
            Text(text).font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: 10))
    }

    // MARK: 数据

    private var dnsCapableCredentials: [CredentialInfo] {
        model.credentials.filter { $0.capabilities?.dns01 == true }
    }

    private func load() {
        guard !loaded, let settings = model.settings else { return }
        acmeEmail = settings.acmeEmail ?? ""
        useStaging = (settings.acmeDirectory ?? "").contains("staging")
        // **空串要当成 nil。**
        //
        // 内核返回的是 `""`（Go 那边的字段是 `string`，不是 `*string`），
        // 而 Swift 把它解成 `Optional("")` —— 与 `nil` 是两回事。
        // picker 里"自动"那一项的 tag 是 `String?.none`，于是两者对不上：
        // 界面显示**空白**，看起来像"还没选"，而实际上它已经是自动了。
        acmeCredentialID = (settings.acmeDnsCredentialId ?? "").isEmpty
            ? nil : settings.acmeDnsCredentialId
        proxyEnabled = settings.proxyEnabled ?? false
        proxyPort = (settings.proxyPort ?? 0) > 0 ? String(settings.proxyPort!) : ""
        proxyTLS = settings.proxyTls ?? true
        logLevel = settings.logLevel ?? "info"
        loaded = true
    }

    private func save() async {
        busy = true
        failure = nil
        notice = nil

        var patch = KernelSettings()
        patch.acmeEmail = acmeEmail.trimmingCharacters(in: .whitespaces)
        patch.acmeDirectory = useStaging ? stagingDirectory : ""
        patch.acmeDnsCredentialId = acmeCredentialID ?? ""
        patch.proxyEnabled = proxyEnabled
        // 端口留空就不提交：提交 0 会被内核当成非法值拒绝，
        // 而用户的意图是"用默认端口"。
        if let port = Int(proxyPort.trimmingCharacters(in: .whitespaces)) {
            patch.proxyPort = port
        }
        patch.proxyTls = proxyTLS
        patch.logLevel = logLevel

        do {
            let saved = try await model.kernel.updateSettings(patch)
            model.settings = saved
            notice = tr("已保存。", "Saved.")
            await model.refreshAll()
        } catch {
            failure = error.localizedDescription
        }
        busy = false
    }
}
