import SwiftUI
import ISCCore

struct BusinessDNSView: View {
    let model: AppModel
    @State private var credential = ""
    @State private var zone = ""
    @State private var record: JSONValue?
    @State private var error: String?
    var creds: [JSONValue] { model.items("/v1/credentials").filter { $0["capabilities"]["zone_list"].bool } }
    var zones: [JSONValue] { model.datasets["/v1/dns-zones" + credential]?.items ?? [] }
    var records: [JSONValue] { model.datasets["/v1/dns-records" + credential + "/" + zone]?.items ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("DNS 区域与记录", "DNS Zones & Records")).font(.largeTitle.bold())
            HStack {
                Picker(tr("凭据", "Credential"), selection: $credential) { Text(tr("选择凭据", "Choose credential")).tag(""); ForEach(Array(creds.enumerated()), id: \.offset) { _, c in Text(c["label"].string).tag(c.id) } }.frame(width: 240)
                Button(tr("加载区域", "Load Zones")) { loadZones() }.disabled(credential.isEmpty)
                if !zone.isEmpty { Button(tr("刷新记录", "Refresh Records")) { loadRecords() } }
            }
            if let error { Text(error).foregroundStyle(.red) }
            List {
                Section(tr("区域", "Zones")) {
                    ForEach(Array(zones.enumerated()), id: \.offset) { _, item in Button { zone = item.id; loadRecords() } label: { Label(item["name"].string, systemImage: zone == item.id ? "checkmark.circle.fill" : "circle") } }
                }
                Section(tr("记录", "Records")) {
                    HStack { Spacer(); Button { record = .null } label: { Label(tr("新建记录", "New Record"), systemImage: "plus") }.disabled(zone.isEmpty) }
                    ForEach(Array(records.enumerated()), id: \.offset) { _, item in
                        HStack { VStack(alignment: .leading) { Text(item["name"].string).font(.headline); Text(item["type"].string + "  " + item["content"].string).foregroundStyle(.secondary); Text(tr("TTL", "TTL") + " " + String(Int(item["ttl"].number))).font(.caption) }; Spacer(); Button(tr("编辑", "Edit")) { record = item }; Button(role: .destructive) { delete(item) } label: { Image(systemName: "trash") } }
                    }
                }
            }
        }.padding(24).disabled(!model.running).sheet(item: Binding(get: { record.map { BusinessEditorItem(value: $0, baseline: .null) } }, set: { record = $0?.value })) { item in BusinessRecordEditor(model: model, credential: credential, zone: zone, item: item, onSaved: loadRecords) }
    }
    func loadZones() { model.execute { let path = "/v1/credentials/" + KernelClient.pathComponent(credential) + "/zones"; model.datasets["/v1/dns-zones" + credential] = try await model.fetch(path); zone = "" } }
    func loadRecords() { guard !credential.isEmpty, !zone.isEmpty else { return }; model.execute { let path = "/v1/credentials/" + KernelClient.pathComponent(credential) + "/zones/" + KernelClient.pathComponent(zone) + "/records"; model.datasets["/v1/dns-records" + credential + "/" + zone] = try await model.fetch(path) } }
    func delete(_ item: JSONValue) { model.execute { _ = try await model.request("DELETE", "/v1/credentials/" + KernelClient.pathComponent(credential) + "/zones/" + KernelClient.pathComponent(zone) + "/records/" + KernelClient.pathComponent(item.id)); loadRecords() } }
}

struct BusinessRecordEditor: View {
    let model: AppModel; let credential: String; let zone: String; let item: BusinessEditorItem; let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String; @State private var type: String; @State private var content: String; @State private var ttl: String; @State private var comment: String; @State private var proxied: Bool; @State private var priority: String; @State private var error: String?
    init(model: AppModel, credential: String, zone: String, item: BusinessEditorItem, onSaved: @escaping () -> Void) { self.model=model; self.credential=credential; self.zone=zone; self.item=item; self.onSaved=onSaved; let v=item.value; _name=State(initialValue:v["name"].string); _type=State(initialValue:v["type"].string.isEmpty ? "A" : v["type"].string); _content=State(initialValue:v["content"].string); _ttl=State(initialValue:String(Int(v["ttl"].number))); _comment=State(initialValue:v["comment"].string); _proxied=State(initialValue:v["proxied"].bool); _priority=State(initialValue:String(Int(v["priority"].number))) }
    var valid: Bool { !name.isEmpty && !type.isEmpty && !content.isEmpty && (Int(ttl) ?? 0) >= 0 }
    var body: some View { Form { TextField(tr("名称", "Name"), text:$name); Picker(tr("类型", "Type"), selection:$type) { ForEach(["A","AAAA","CNAME","MX","TXT","NS","SRV","CAA"], id:\.self) { Text($0).tag($0) } }; TextField(tr("内容", "Content"), text:$content, axis:.vertical); TextField(tr("TTL 秒数", "TTL seconds"), text:$ttl); TextField(tr("备注", "Comment"), text:$comment); Toggle(tr("代理", "Proxied"), isOn:$proxied); TextField(tr("优先级（MX/SRV）", "Priority (MX/SRV)"), text:$priority); if let error { Text(error).foregroundStyle(.red) }; HStack { Spacer(); Button(tr("取消", "Cancel")) { dismiss() }; Button(tr("保存", "Save")) { save() }.buttonStyle(.borderedProminent).disabled(!valid) } }.padding(20).frame(width:520,height:500) }
    func save() {
        let body: JSONValue = .object([
            "name": .string(name),
            "type": .string(type),
            "content": .string(content),
            "ttl": .number(Double(Int(ttl) ?? 0)),
            "proxied": .bool(proxied),
            "comment": .string(comment),
            "priority": .number(Double(Int(priority) ?? 0))
        ])
        let isNew = item.value == .null
        let recordID = item.value.id
        let base = "/v1/credentials/" + KernelClient.pathComponent(credential) + "/zones/" + KernelClient.pathComponent(zone) + "/records"
        let path = isNew ? base : base + "/" + KernelClient.pathComponent(recordID)
        let method = isNew ? "POST" : "PUT"
        model.execute {
            do {
                _ = try await model.request(method, path, body: body)
                onSaved()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
