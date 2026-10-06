import SwiftUI
import ISCCore

/// DNS 分区：按"凭据 → 区域 → 解析条目"三层展开。
///
/// 解析条目必须挂在某个凭据的某个区域下，因此界面上先选这两样 ——
/// 一上来就要求用户输入"凭据 id"和"区域名"是不合理的，而这两样内核
/// 都能列出来。
struct DNSView: View {
    @Bindable var model: AppModel

    @State private var credentialID: String?
    @State private var zone: String?
    @State private var zones: [DNSZone] = []
    @State private var records: [DNSRecord] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var showingAdd = false
    @State private var editing: DNSRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            pickers
            Divider()
            content
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
                .disabled(zone == nil || credentialID == nil)
            }
        }
        .sheet(isPresented: $showingAdd) {
            if let credentialID, let zone {
                RecordFormView(zone: zoneLabel, existing: nil) { request in
                    _ = try await model.kernel.createRecord(credentialID: credentialID, zone: zone, request)
                    await loadRecords()
                }
            }
        }
        .sheet(item: $editing) { record in
            if let credentialID, let zone {
                RecordFormView(zone: zoneLabel, existing: record) { request in
                    _ = try await model.kernel.updateRecord(credentialID: credentialID, zone: zone,
                                                            recordID: record.id, request)
                    await loadRecords()
                }
            }
        }
        .task(id: model.credentials.count) { await bootstrap() }
    }

    /// 当前选中区域的名字；只用于显示。
    ///
    /// `zone` 存的是区域 ID（接口要的就是它），但界面上该给用户看名字。
    private var zoneLabel: String {
        guard let zone else { return "" }
        return zones.first { $0.id == zone }?.name ?? zone
    }

    private var pickers: some View {
        HStack(spacing: 14) {
            Picker(tr("凭据", "Credential"), selection: $credentialID) {
                Text(tr("请选择", "Select")).tag(String?.none)
                ForEach(model.credentials) { credential in
                    Text("\(credential.label) · \(credential.provider)").tag(String?.some(credential.id))
                }
            }
            .frame(maxWidth: 260)

            // 标签显示区域名（用户认的是名字），值用区域 ID ——
            // 契约里的路径参数是 zoneId，而 Cloudflare 这类服务商
            // 只认 ID，把名字当 ID 发过去会得到一条看不懂的上游 404。
            Picker(tr("区域", "Zone"), selection: $zone) {
                Text(tr("请选择", "Select")).tag(String?.none)
                ForEach(zones) { item in
                    Text(item.name).tag(String?.some(item.id))
                }
            }
            .frame(maxWidth: 240)
            .disabled(zones.isEmpty)

            if loading { ProgressView().controlSize(.small) }
            Spacer()
            Button {
                Task { await loadRecords() }
            } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(zone == nil)
        }
        .padding(16)
        .onChange(of: credentialID) { _, _ in Task { await loadZones() } }
        .onChange(of: zone) { _, _ in Task { await loadRecords() } }
    }

    @ViewBuilder private var content: some View {
        if model.credentials.isEmpty {
            EmptyHint(symbol: "key",
                      title: tr("还没有 DNS 凭据", "No DNS credential yet"),
                      message: tr("添加一个 DNS 服务商的凭据，才能管理解析与签发证书。",
                                  "Add a DNS provider credential to manage records and issue certificates."),
                      action: (tr("添加凭据", "Add a credential"), { model.requestedSheet = .credentials }))
        } else if let failure {
            EmptyHint(symbol: "exclamationmark.triangle",
                      title: tr("读取失败", "Could not load"),
                      message: failure,
                      action: (tr("重试", "Try again"), { Task { await loadZones() } }))
        } else if zone == nil {
            EmptyHint(symbol: "globe",
                      title: tr("选择一个区域", "Pick a zone"),
                      message: tr("先选凭据，再选要管理的域名区域。", "Choose a credential, then the zone to manage."))
        } else if records.isEmpty && !loading {
            EmptyHint(symbol: "tray",
                      title: tr("这个区域还没有解析条目", "No records in this zone"),
                      message: tr("点右上角添加一条。", "Use the button above to add one."),
                      action: (tr("添加解析", "Add record"), { showingAdd = true }))
        } else {
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
    }

    // MARK: 数据

    private func bootstrap() async {
        if credentialID == nil { credentialID = model.credentials.first?.id }
        await loadZones()
    }

    private func loadZones() async {
        guard let credentialID else { zones = []; zone = nil; return }
        loading = true
        failure = nil
        do {
            zones = try await model.kernel.zones(credentialID: credentialID)
            zone = zones.first?.id
        } catch {
            zones = []
            zone = nil
            failure = error.localizedDescription
        }
        loading = false
        await loadRecords()
    }

    private func loadRecords() async {
        guard let credentialID, let zone else { records = []; return }
        loading = true
        failure = nil
        do {
            records = try await model.kernel.records(credentialID: credentialID, zone: zone)
        } catch {
            records = []
            failure = error.localizedDescription
        }
        loading = false
    }

    private func delete(_ record: DNSRecord) async {
        guard let credentialID, let zone else { return }
        do {
            try await model.kernel.deleteRecord(credentialID: credentialID, zone: zone, recordID: record.id)
            await loadRecords()
        } catch {
            failure = error.localizedDescription
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
