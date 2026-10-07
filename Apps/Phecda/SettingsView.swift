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
    /// 隧道。开关与状态分开存：开关是用户的意图，状态是内核实际做到哪一步，
    /// 两者常常不一致（点了开但缺 cloudflared），而那个差值正是要显示的东西。
    @State private var proxyPort = ""

    @State private var loaded = false
    @State private var busy = false
    @State private var failure: String?
    @State private var notice: String?

    /// 日志导出的状态。
    ///
    /// 放在这个视图里而不是 AppModel：导出是**一次性的界面动作**，
    /// 没有任何别的界面需要知道它，塞进全局模型只会多一个需要维护的状态。
    @State private var logReport: LogExport.Report?
    @State private var scanningLogs = false
    @State private var exportingLogs = false
    /// 导出成功/失败都写在这里 —— 这条路径上用户看不到别的反馈，
    /// 静默失败等于让他对着一个没出现的文件猜。
    @State private var exportMessage: (text: String, ok: Bool)?

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
                    tunnelSection
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

            labeled(tr("DNS 服务商", "DNS provider")) {
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
                 ? tr("内核会按域名找出它属于哪个服务商。只有当自动匹配挑错时才需要手动指定。",
                      "The kernel finds which zone the domain belongs to and which credential owns it. Pick one manually only if automatic matching gets it wrong.")
                 : tr("已手动指定：所有域名的 DNS-01 校验都会用这一个服务商。",
                      "Manually pinned: DNS-01 for every domain will use this one credential."))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if dnsCapableCredentials.isEmpty {
                Text(tr("还没有能新建记录的服务商（DNS-01 需要写一条 TXT）。先去 DNS 页添加一个，例如 Cloudflare。",
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

        }
    }

    /// Cloudflare 自动中继。
    ///
    /// 实现抽在 `TunnelControls` 里：首启向导的第三页要用**同一套**状态文案，
    /// 而那段"缺 cloudflared / 缺授权"的说明是很具体的知识，复制一份必然漂移。
    private var tunnelSection: some View { TunnelControls(model: model) }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(tr("日志", "Logging"),
                         tr("内核记录得越详细，出问题时越查得清。", "The more detail the kernel records, the more a problem can be traced."))

            // 这里原来是一个日志级别 Picker（错误/警告/信息/调试），默认「信息」。
            //
            // 去掉它有两个理由，都是"这个选择不该由用户来做"：日志是**出事之后**
            // 才去看的东西，而"要不要记调试信息"这个决定必须在出事**之前**下 ——
            // 用户按默认的「信息」跑上几周，等到站点起不来时才发现想看的那几行
            // 从来没被记下来，而这时已经补不回来了。另一个理由是日志全在本机、
            // 只写进应用自己的数据目录，详细模式的代价（磁盘与一点性能）远小于
            // 它换来的可诊断性。
            //
            // 因此界面不再提供这个选项，而是在**每次保存设置时**显式写回
            // `log_level = "debug"`（见 save()）；用户机器上残留的旧值
            // （例如之前选过「错误」）会在下一次保存时被改回来 —— 只是把
            // 控件藏起来、却让内核继续用旧值，是把问题变得更隐蔽而不是解决它。
            Text(tr("日志详细程度固定为「调试」，不再提供选项。日志只写在本机，出问题时才能查得到前因后果。",
                    "Log detail is always set to Debug and is no longer selectable. Logs stay on this Mac, so the whole story is there when something breaks."))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            row(title: tr("导出日志", "Export logs"),
                detail: tr("把所有日志打包成一个 zip，自己选保存位置。",
                           "Bundle every log into one zip at a location you choose.")) {
                if scanningLogs || exportingLogs { ProgressView().controlSize(.small) }
                Button(exportButtonTitle) { Task { await exportLogs() } }
                    .buttonStyle(.glass).controlSize(.small)
                    // **不**因为内核没运行就禁用：日志是磁盘上的文件，内核停着
                    // 照样读得到 —— 而"刚崩过、正想看日志"恰恰是内核没运行的时候。
                    .disabled(scanningLogs || exportingLogs)
            }
            // 打包前把总量摆出来。日志可以到几百 MB，让用户点完按钮才
            // 干等一分钟是不必要的 —— 他至少该知道自己按的是什么。
            if let report = logReport {
                Text(summary(of: report))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let exportMessage {
                message(exportMessage.text, tint: exportMessage.ok ? .green : .red)
            }

            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("引导", "Setup")).font(.callout)
                    Text(tr("重新走一遍首次安装的引导。", "Walk through the first-run setup again."))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button(tr("重新运行", "Run again")) {
                    model.restartOnboarding()
                    dismiss()
                }
                .buttonStyle(.glass).controlSize(.small)
            }
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

    /// 左文右按钮的一行。与 `labeled` 的区别是标签在上、说明在下 ——
    /// 说明比标签长得多的时候，把两者挤在一行会得到一堆折行的窄文字。
    private func row<Content: View>(title: String, detail: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            content()
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
        // 日志级别**不再读回**：界面上已经没有这个选项，读回来只是为了显示
        // 一个用户改不了的旧值。内核那边在下一次保存时会被写成 debug。
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
        // 固定最详细。写死在这里而不是"界面不显示、内核沿用旧值"：用户机器上
        // 可能存着旧版本选过的 error/warn，只藏控件的话那些机器会一直用最粗的
        // 日志级别，而界面上看不出任何区别。
        patch.logLevel = "debug"

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

    // MARK: 导出日志

    /// 按钮上的字数就是用户最先看到的信息量：还没统计时给动作，
    /// 统计完之后给"这份日志有多大"。
    private var exportButtonTitle: String {
        guard let report = logReport else { return tr("导出…", "Export…") }
        return tr("导出（\(report.totals.files) 个文件 · \(report.totals.bytes.formattedBytes)）",
                  "Export (\(report.totals.files) files · \(report.totals.bytes.formattedBytes))")
    }

    private func summary(of report: LogExport.Report) -> String {
        guard report.totals.files > 0 else {
            return tr("没有找到日志文件。内核还没运行过，或者日志已经被清理了。",
                      "No log files were found. The kernel may never have run, or its logs were cleaned up.")
        }
        // 逐个来源写清楚收集范围。只报一个总数的话，用户没法判断
        // "我要找的那份日志到底进没进去"。
        let names = (report.directories + report.standaloneFiles).map(\.name).joined(separator: "、")
        return tr("将收集 \(report.totals.files) 个文件（约 \(report.totals.bytes.formattedBytes)），来自：\(names)。",
                  "Will collect \(report.totals.files) files (~\(report.totals.bytes.formattedBytes)) from: \(names).")
    }

    /// 先统计、再让用户选位置、最后打包。
    ///
    /// 三步分开是有意的：统计结果要能显示出来（这是"可能很大"的唯一提示），
    /// 保存面板必须在统计**之后**出现（否则用户对着一个转圈的对话框等），
    /// 而打包是唯一耗时的一步，它的进行与结果都要有明确反馈。
    private func exportLogs() async {
        exportMessage = nil
        if logReport == nil {
            scanningLogs = true
            logReport = await LogExport.prepare(dataDirectory: model.dataDirectory)
            scanningLogs = false
            // 一份都没有时不再弹保存面板：让用户选完位置、按下保存、
            // 再被告知"没有日志"，是把坏消息放在最远的地方。
            guard logReport?.totals.files ?? 0 > 0 else {
                exportMessage = (tr("没有找到日志文件。内核还没运行过，或者日志已经被清理了。",
                                    "No log files were found. The kernel may never have run, or its logs were cleaned up."), false)
                return
            }
        }

        let panel = NSSavePanel()
        panel.title = tr("导出日志", "Export logs")
        panel.prompt = tr("导出", "Export")
        panel.nameFieldStringValue = LogExport.suggestedFileName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        exportingLogs = true
        do {
            // 重新扫一遍：统计之后应用可能又跑了一会儿，而新产生的日志
            // 往往正是用户想看的那一段。
            let result = try await LogExport.export(to: destination, dataDirectory: model.dataDirectory)
            logReport = result.report
            exportMessage = (tr("已导出 \(result.report.totals.files) 个日志文件（zip \(result.archiveBytes.formattedBytes)）到 \(destination.path)",
                                "Exported \(result.report.totals.files) log files (\(result.archiveBytes.formattedBytes) zip) to \(destination.path)"), true)
        } catch {
            exportMessage = (error.localizedDescription, false)
        }
        exportingLogs = false
    }
}
