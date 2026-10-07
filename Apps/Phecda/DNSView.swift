import SwiftUI
import AppKit
import ISCCore

/// DNS 分区：按"服务商 → 域名 → 解析条目"三层展开。
///
/// 解析条目必须挂在某个服务商的某个域名下，因此界面上先选这两样 ——
/// 一上来就要求用户输入"服务商 id"和"域名"是不合理的，而这两样内核
/// 都能列出来。
///
/// # 数据为什么都在模型里
///
/// 这一页的三层数据（服务商、域名、解析条目）与选中项都缓存在 `AppModel`
/// 上，视图自己只留界面状态。切换分区会把这个视图整个丢掉，缓存放在 @State
/// 里就等于每次进来都重新问一遍内核 —— 用户看到的正是"点什么都要等"。
/// 现在切回来先用缓存立刻渲染，后台每 5 分钟刷一轮（`beginDNSPolling`）。
struct DNSView: View {
    @Bindable var model: AppModel

    @State private var showingAdd = false
    @State private var editing: DNSRecord?
    /// 最下面那条子域名展开条。默认收起；离开这一页时收起。
    @State private var showingSubdomain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            pickers
            Divider()
            content
            subdomainBar
        }
        .navigationTitle(AppSection.dns.title)
        .toolbar {
            ToolbarItem {
                Button {
                    model.requestedSheet = .ddns
                } label: {
                    Label(tr("动态解析", "Dynamic DNS"), systemImage: "arrow.triangle.2.circlepath")
                }
            }
            ToolbarItem {
                Button {
                    model.requestedSheet = .credentials
                } label: {
                    Label(tr("凭据", "Credentials"), systemImage: "key")
                }
            }
            ToolbarItem {
                Button {
                    showingAdd = true
                } label: {
                    Label(tr("添加解析", "Add record"), systemImage: "plus")
                }
                .disabled(model.dnsZoneID == nil || model.dnsCredentialID == nil)
            }
        }
        .sheet(isPresented: $showingAdd) {
            if let credentialID = model.dnsCredentialID, let zone = model.dnsZoneID {
                RecordFormView(zone: model.dnsZoneLabel, existing: nil) { request in
                    _ = try await model.kernel.createRecord(credentialID: credentialID, zone: zone, request)
                    // 写完立刻重读：缓存放着不管，列表就会与服务商那边不一致。
                    await model.refreshDNS(visible: true)
                }
            }
        }
        .sheet(item: $editing) { record in
            if let credentialID = model.dnsCredentialID, let zone = model.dnsZoneID {
                RecordFormView(zone: model.dnsZoneLabel, existing: record) { request in
                    _ = try await model.kernel.updateRecord(credentialID: credentialID, zone: zone,
                                                            recordID: record.id, request)
                    await model.refreshDNS(visible: true)
                }
            }
        }
        .task {
            // 定期刷新在这一页起步：没人打开过它时，每 5 分钟打三个请求没有意义。
            model.beginDNSPolling()
            await model.prepareDNS()
        }
        // 服务商列表变了（内核刚起来时它还是空的、或用户刚添加了一个）：
        // 补一次选择与数据。幂等 —— 有缓存时它什么都不做。
        .onChange(of: model.credentials.count) { _, _ in
            Task { await model.prepareDNS() }
        }
        // 离开 DNS 页时把展开条收起来，下次进来是干净的收起态。
        //
        // 盯的是 section 而不是用 onDisappear：这里要表达的正是"离开这个
        // 分区"，而 onDisappear 还会被窗口、弹窗这些与分区无关的事触发，
        // 语义比需要的宽。
        .onChange(of: model.section) { _, section in
            if section != .dns { showingSubdomain = false }
        }
    }

    // MARK: 顶部选择

    /// 当前服务商下的域名列表（缓存里的那一份）。
    private var zones: [DNSZone] { model.currentDNSZones ?? [] }

    /// 当前域名下的解析条目（缓存里的那一份）。
    private var records: [DNSRecord] { model.currentDNSRecords ?? [] }

    /// 缓存里有没有当前域名的解析条目。
    ///
    /// 「还没读到」与「读到了空列表」在界面上是两句不同的话，所以要分。
    private var recordsLoaded: Bool { model.currentDNSRecords != nil }

    private var pickers: some View {
        HStack(spacing: 14) {
            Picker(tr("服务商", "Provider"), selection: credentialSelection) {
                Text(tr("请选择", "Select")).tag(String?.none)
                ForEach(model.credentials) { credential in
                    Text("\(credential.label) · \(credential.provider)").tag(String?.some(credential.id))
                }
            }
            .frame(maxWidth: 260)

            // 标签显示域名（用户认的是名字），值用域名 ID ——
            // 契约里的路径参数是 zoneId，而 Cloudflare 这类服务商
            // 只认 ID，把名字当 ID 发过去会得到一条看不懂的上游 404。
            Picker(tr("域名", "Domain"), selection: zoneSelection) {
                Text(tr("请选择", "Select")).tag(String?.none)
                ForEach(zones) { item in
                    Text(item.name).tag(String?.some(item.id))
                }
            }
            .frame(maxWidth: 240)
            .disabled(zones.isEmpty)

            if model.dnsLoading { ProgressView().controlSize(.small) }
            Spacer()
            Button {
                Task { await model.refreshDNS(visible: true) }
            } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(model.dnsZoneID == nil)
        }
        .padding(16)
    }

    /// 服务商选择。
    ///
    /// 值先**同步**写回模型（Picker 的当前项要立刻对上，不能等异步方法跑
    /// 起来），再去补数据 —— 数据在缓存里时那一趟什么都不做，所以来回切
    /// 服务商是即时的。
    private var credentialSelection: Binding<String?> {
        Binding(get: { model.dnsCredentialID },
                set: { value in
                    model.dnsCredentialID = value
                    Task { await model.syncDNSCache() }
                })
    }

    /// 域名选择。同上。
    private var zoneSelection: Binding<String?> {
        Binding(get: { model.dnsZoneID },
                set: { value in
                    model.dnsZoneID = value
                    Task { await model.syncDNSCache() }
                })
    }

    // MARK: 内容

    @ViewBuilder private var content: some View {
        if model.credentials.isEmpty {
            EmptyHint(symbol: "key",
                      title: tr("还没有 DNS 服务商", "No DNS credential yet"),
                      message: tr("添加一个 DNS 服务商，才能管理解析与签发证书。",
                                  "Add a DNS provider credential to manage records and issue certificates."),
                      action: (tr("添加服务商", "Add a credential"), { model.requestedSheet = .credentials }))
        } else if model.dnsZoneID == nil {
            zonesHint
        } else if !recordsLoaded {
            loadHint
        } else if records.isEmpty {
            emptyListHint
        } else {
            VStack(spacing: 0) {
                // 刷新失败的提示挂在列表**上方**，而不是替换列表：旧数据还在，
                // 用户至少能继续看、继续操作。
                if let failure = model.dnsFailure { staleWarning(failure) }
                recordsList
            }
        }
    }

    /// 还没选到域名时的几种情况。
    ///
    /// 读不到、读到了空列表、还没读完，要分开说 —— 给用户一句"选择一个
    /// 域名"而其实是他没有任何域名可用，等于让他对着一个空选择器发呆。
    @ViewBuilder private var zonesHint: some View {
        if let failure = model.dnsFailure, model.currentDNSZones == nil {
            // 一点旧数据都没有（首次进来就读不到）：只能给出原因与重试。
            EmptyHint(symbol: "exclamationmark.triangle",
                      title: tr("读取失败", "Could not load"),
                      message: failure,
                      action: (tr("重试", "Try again"), { Task { await model.refreshDNS(visible: true) } }))
        } else if model.dnsLoading && model.currentDNSZones == nil {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.currentDNSZones?.isEmpty == true {
            EmptyHint(symbol: "globe",
                      title: tr("没有可管理的域名", "No domain to manage"),
                      message: tr("这个服务商名下没有域名。检查一下它的权限，或换一个服务商。",
                                  "This provider has no domain under it. Check its permissions, or pick another provider."),
                      action: (tr("重新读取", "Reload"), { Task { await model.refreshDNS(visible: true) } }))
        } else {
            EmptyHint(symbol: "globe",
                      title: tr("选择一个域名", "Pick a domain"),
                      message: tr("先选服务商，再选要管理的域名。", "Choose a credential, then the zone to manage."))
        }
    }

    /// 域名选好了但它的解析条目还没读到。
    @ViewBuilder private var loadHint: some View {
        if let failure = model.dnsFailure {
            EmptyHint(symbol: "exclamationmark.triangle",
                      title: tr("读取失败", "Could not load"),
                      message: failure,
                      action: (tr("重试", "Try again"), { Task { await model.refreshDNS(visible: true) } }))
        } else {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 读到了，但这个域名下确实一条都没有。
    @ViewBuilder private var emptyListHint: some View {
        if let failure = model.dnsFailure {
            // 上次读到空、这次又没读到：分不清"真的没有"还是"没读到"，
            // 那就说"没读到" —— 给出一个可能是错的结论比不说更糟。
            EmptyHint(symbol: "exclamationmark.triangle",
                      title: tr("读取失败", "Could not load"),
                      message: failure,
                      action: (tr("重试", "Try again"), { Task { await model.refreshDNS(visible: true) } }))
        } else {
            EmptyHint(symbol: "tray",
                      title: tr("这个域名还没有解析条目", "No records in this zone"),
                      message: tr("点右上角添加一条。", "Use the button above to add one."),
                      action: (tr("添加解析", "Add record"), { showingAdd = true }))
        }
    }

    /// 刷新失败时的提示。
    ///
    /// 它**不**替换列表：屏幕上已有的内容继续有效，用户能接着看、接着改。
    /// 把整页换成一句错误，等于让一次网络抖动抹掉已经读到的东西。
    private func staleWarning(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            // 宽度上限定在 EmptyHint 的那一套：内核回来的错误常常是一条没有
            // 空格可断的长串，由着它撑理想宽度会把左侧栏挤掉。
            Text(tr("这次没读到，下面是上次读到的内容：\(message)",
                    "Could not refresh — showing the last successful read: \(message)"))
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: EmptyHint.messageMaxWidth, alignment: .leading)
            Spacer(minLength: 8)
            Button(tr("重试", "Try again")) { Task { await model.refreshDNS(visible: true) } }
                .buttonStyle(.borderless).controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
    }

    private var recordsList: some View {
        List {
            ForEach(records) { record in
                HStack(spacing: 10) {
                    Text(record.type)
                        .font(.caption.weight(.semibold))
                        .frame(width: 52, alignment: .leading)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.name).font(.callout).lineLimit(1).truncationMode(.middle)
                        Text(record.content).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if let ttl = record.ttl {
                        Text("TTL \(ttl)").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Button { editing = record } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless)
                    Button(role: .destructive) {
                        Task { await delete(record) }
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.inset)
    }

    // MARK: 子域名展开条

    /// 列表最下方那条默认收起的展开条：Phecda 给 Mizar 用的用户子域名。
    ///
    /// 默认收起，因为只有配置手机端（ISC Mizar）时才用得上它，而那是偶尔
    /// 一次的事；但不能完全藏起来 —— 用户在 DNS 页排查"手机连不上"时要
    /// 核对的正是这个地址。
    private var subdomainBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showingSubdomain.toggle() }
                // 展开时才去要远程状态：这一条平时不必占一次请求。
                if showingSubdomain { Task { await model.loadRemoteStatusIfNeeded() } }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showingSubdomain ? 90 : 0))
                    Text(tr("Mizar 远程访问地址", "Mizar remote address")).font(.callout)
                    Spacer(minLength: 8)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if showingSubdomain { subdomainDetail }
        }
        .background(.bar)
    }

    /// 展开后的内容。拿不到数据时这里必须有一句明确的话，不能是空白。
    @ViewBuilder private var subdomainDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let host = model.remoteStatus?.public?.host, !host.isEmpty {
                HStack(spacing: 8) {
                    Text(host)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(host, forType: .string)
                    } label: {
                        Label(tr("复制", "Copy"), systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless).controlSize(.small)
                    .help(tr("复制地址", "Copy the address"))
                    Spacer(minLength: 0)
                }
                Text(tr("手机上配置 ISC Mizar 时填这个地址。它是内核为公网访问建的那条随机子域名，指向这台机器。",
                        "Enter this address when setting up ISC Mizar on your phone. It is the random subdomain the kernel created for public access, pointing at this machine."))
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let status = model.remoteStatus {
                // 内核答了，但里面没有子域名：这两种原因要分开说，
                // 否则用户不知道是该去开启，还是该等一等。
                Text(status.public?.enabled == true
                     ? tr("公网访问已经打开，但子域名还没建好。到「远程访问」页点一次「立即同步」；如果刚打开，稍等片刻再看。",
                          "Public access is on but the subdomain has not been created yet. Use “Sync now” on the Remote Access page — or wait a moment if you just enabled it.")
                     : tr("还没有子域名：公网访问没开启。到「远程访问」页打开它，Phecda 会在你自己的域名下建一条随机子域名给 Mizar 用。",
                          "No subdomain yet: public access is off. Turn it on in Remote Access and Phecda will create a random subdomain under your own domain for Mizar."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(tr("暂时读不到远程访问状态（内核没有返回）。这一条只影响这里显示什么，不影响 DNS 解析。",
                        "Cannot read the remote access status right now. This only affects what is shown here — DNS records are unaffected."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button {
                    Task { await model.refreshRemoteStatus() }
                } label: {
                    Label(tr("重新读取", "Reload"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless).controlSize(.small)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    // MARK: 动作

    private func delete(_ record: DNSRecord) async {
        guard let credentialID = model.dnsCredentialID, let zone = model.dnsZoneID else { return }
        do {
            try await model.kernel.deleteRecord(credentialID: credentialID, zone: zone, recordID: record.id)
            await model.refreshDNS()
        } catch {
            // 写失败走应用统一的提示条：它和"读不到"不是一回事，
            // 混进列表上方那条提示里会让人以为列表显示的是旧数据。
            model.errorMessage = error.localizedDescription
        }
    }
}

/// 新建或修改一条解析记录。
///
/// 修改走 PUT 而不是"删了再建"：后者在中间会有一段时间这个域名解析不到
/// 任何东西，对正在访问的用户就是一次中断。
struct RecordFormView: View {
    let zone: String
    /// 为空表示新建。
    let existing: DNSRecord?
    let submit: (DNSRecordRequest) async throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var type = "A"
    @State private var content = ""
    @State private var ttl = ""
    @State private var proxied = false
    @State private var comment = ""
    @State private var busy = false
    @State private var failure: String?
    @State private var loaded = false

    private let types = ["A", "AAAA", "CNAME", "TXT", "MX"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil
                 ? tr("在 \(zone) 添加解析", "Add a record in \(zone)")
                 : tr("修改 \(zone) 中的解析", "Edit the record in \(zone)"))
                .font(.headline)

            HStack(spacing: 10) {
                TextField(tr("名称（例如 www 或 @）", "Name (e.g. www or @)"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(existing != nil)
                Picker("", selection: $type) {
                    ForEach(types, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 100)
                .disabled(existing != nil)
            }
            if existing != nil {
                Text(tr("名称与类型不可修改；要换的话删掉重建。",
                        "The name and type cannot be changed; delete and recreate to change them."))
                    .font(.caption2).foregroundStyle(.secondary)
            }

            TextField(tr("内容（IP 或目标）", "Content (IP or target)"), text: $content)
                .textFieldStyle(.roundedBorder)
            TextField(tr("TTL（留空用服务商默认值）", "TTL (empty for the provider default)"), text: $ttl)
                .textFieldStyle(.roundedBorder)
            TextField(tr("备注（可选）", "Comment (optional)"), text: $comment)
                .textFieldStyle(.roundedBorder)
            Toggle(tr("经由服务商代理", "Proxied through the provider"), isOn: $proxied)
                .toggleStyle(.switch)

            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(tr("取消", "Cancel")) { dismiss() }
                Button(existing == nil ? tr("添加", "Add") : tr("保存", "Save")) { Task { await save() } }
                    .buttonStyle(.glassProminent)
                    .disabled(name.isEmpty || content.isEmpty || busy)
            }
        }
        .padding(22)
        .frame(width: 460)
        .task { load() }
    }

    private func load() {
        guard !loaded, let existing else { loaded = true; return }
        name = existing.name
        type = existing.type
        content = existing.content
        ttl = existing.ttl.map(String.init) ?? ""
        proxied = existing.proxied ?? false
        comment = existing.comment ?? ""
        loaded = true
    }

    private func save() async {
        busy = true
        failure = nil
        do {
            var request = DNSRecordRequest(name: name, type: type, content: content)
            if let value = Int(ttl.trimmingCharacters(in: .whitespaces)) { request.ttl = value }
            request.proxied = proxied
            if !comment.trimmingCharacters(in: .whitespaces).isEmpty { request.comment = comment }
            try await submit(request)
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
        busy = false
    }
}
