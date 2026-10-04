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
                AddRecordView(zone: zone) { request in
                    _ = try await model.kernel.createRecord(credentialID: credentialID, zone: zone, request)
                    await loadRecords()
                }
            }
        }
        .task { await bootstrap() }
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

            Picker(tr("区域", "Zone"), selection: $zone) {
                Text(tr("请选择", "Select")).tag(String?.none)
                ForEach(zones) { item in
                    Text(item.name).tag(String?.some(item.name))
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
            zone = zones.first?.name
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

struct AddRecordView: View {
    let zone: String
    let submit: (DNSRecordRequest) async throws -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var type = "A"
    @State private var content = ""
    @State private var ttl = "600"
    @State private var busy = false
    @State private var failure: String?

    private let types = ["A", "AAAA", "CNAME", "TXT", "MX"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("在 \(zone) 添加解析", "Add a record in \(zone)")).font(.headline)

            TextField(tr("名称（例如 www 或 @）", "Name (e.g. www or @)"), text: $name)
                .textFieldStyle(.roundedBorder)
            Picker(tr("类型", "Type"), selection: $type) {
                ForEach(types, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField(tr("内容（IP 或目标）", "Content (IP or target)"), text: $content)
                .textFieldStyle(.roundedBorder)
            TextField(tr("TTL", "TTL"), text: $ttl)
                .textFieldStyle(.roundedBorder)

            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button(tr("取消", "Cancel")) { dismiss() }
                Button(tr("添加", "Add")) { Task { await add() } }
                    .buttonStyle(.glassProminent)
                    .disabled(name.isEmpty || content.isEmpty || busy)
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private func add() async {
        busy = true
        failure = nil
        do {
            let request = DNSRecordRequest(name: name, type: type, content: content, ttl: Int(ttl))
            try await submit(request)
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
        busy = false
    }
}
