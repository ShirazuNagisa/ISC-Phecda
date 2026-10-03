import SwiftUI
import ISCCore

struct BusinessAddressSource {
    var enabled = false
    var method = "netInterface"
    var value = ""
    var domains = ""
    var selector = ""
    init(_ json: JSONValue = .null) {
        enabled = json["enable"].bool
        method = json["get_type"].string.isEmpty ? "netInterface" : json["get_type"].string
        value = json["value"].string
        domains = json["domains"].array.map(\.string).joined(separator: "\n")
        selector = json["selector"].string
    }
    var valid: Bool { !enabled || (!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !BusinessEditor.words(domains).isEmpty) }
    var json: JSONValue { .object(["enable": .bool(enabled), "get_type": .string(method), "value": .string(value), "domains": .array(BusinessEditor.words(domains).map(JSONValue.string)), "selector": .string(selector)]) }
}

struct BusinessSourceForm: View {
    let title: String
    let ipv6: Bool
    @Binding var source: BusinessAddressSource
    var body: some View {
        Section(title) {
            Toggle(tr("启用", "Enabled"), isOn: $source.enabled)
            if source.enabled {
                Picker(tr("地址来源", "Address Source"), selection: $source.method) {
                    Text(tr("网卡", "Network Interface")).tag("netInterface")
                    Text(tr("外部地址查询", "Address Lookup URL")).tag("url")
                    Text(tr("命令输出", "Command Output")).tag("cmd")
                }
                TextField(source.method == "netInterface" ? tr("网卡名称", "Interface Name") : source.method == "url" ? tr("查询 URL，可用逗号分隔", "Lookup URLs, separated by commas") : tr("命令", "Command"), text: $source.value)
                TextField(tr("域名，每行一个", "Domains, one per line"), text: $source.domains, axis: .vertical).lineLimit(3...6)
                if ipv6 { TextField(tr("地址选择器（可选）", "Address Selector (optional)"), text: $source.selector); Text(tr("留空选第一个；@2 选第二个；^240e:.* 按正则筛选。", "Leave blank for the first address; @2 selects the second; ^240e:.* filters by regular expression.")).font(.caption).foregroundStyle(.secondary) }
                if !source.valid { Text(tr("请填写来源和至少一个域名。", "Enter a source and at least one domain.")).foregroundStyle(.red) }
                if source.method == "cmd" { Text(tr("仅使用您信任的命令。保存后内核将按配置执行。", "Use a command you trust. The kernel executes it according to this configuration.")).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

struct BusinessHeaderField: Identifiable { var id = UUID(); var name = ""; var value = "" }

struct BusinessEditor: View {
    let model: AppModel
    let kind: BusinessKind
    let item: BusinessEditorItem
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var provider: String
    @State private var fields: [String: String]
    @State private var credential: String
    @State private var enabled: Bool
    @State private var ipv4: BusinessAddressSource
    @State private var ipv6: BusinessAddressSource
    @State private var ttl: String
    @State private var interface: String
    @State private var domains: String
    @State private var upstream: String
    @State private var tls: Bool
    @State private var channelKind: String
    @State private var url: String
    @State private var method: String
    @State private var template: String
    @State private var severity: String
    @State private var headers: [BusinessHeaderField]
    @State private var saving = false
    @State private var error: String?
    init(model: AppModel, kind: BusinessKind, item: BusinessEditorItem) {
        self.model = model; self.kind = kind; self.item = item
        let v = item.value
        _label = State(initialValue: v[kind == .notify ? "name" : "label"].string)
        _provider = State(initialValue: v["provider"].string)
        _fields = State(initialValue: v["fields"].object.mapValues(\.string))
        _credential = State(initialValue: v["credential_id"].string)
        _enabled = State(initialValue: v == .null ? true : v["enabled"].bool)
        _ipv4 = State(initialValue: BusinessAddressSource(v["ipv4"]))
        _ipv6 = State(initialValue: BusinessAddressSource(v["ipv6"]))
        _ttl = State(initialValue: v["ttl"].string)
        _interface = State(initialValue: v["http_interface"].string)
        _domains = State(initialValue: v["domains"].array.map(\.string).joined(separator: "\n"))
        _upstream = State(initialValue: v["upstream"].string)
        _tls = State(initialValue: v["tls"].bool)
        _channelKind = State(initialValue: v["kind"].string.isEmpty ? "webhook" : v["kind"].string)
        _url = State(initialValue: v["url"].string)
        _method = State(initialValue: v["method"].string.isEmpty ? "POST" : v["method"].string)
        _template = State(initialValue: v["body_template"].string)
        _severity = State(initialValue: v["min_severity"].string.isEmpty ? "info" : v["min_severity"].string)
        _headers = State(initialValue: v["headers"].object.sorted { $0.key < $1.key }.map { BusinessHeaderField(name: $0.key, value: $0.value.string) })
    }
    static func words(_ text: String) -> [String] { text.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    var providerValue: JSONValue { model.items("/v1/providers").first { $0["name"].string == provider } ?? .null }
    var credentials: [JSONValue] { model.items("/v1/credentials").filter { $0["capabilities"]["dynamic"].bool } }
    var valid: Bool {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch kind {
        case .credentials: return providerValue["capabilities"]["available"].bool && !provider.isEmpty && providerValue["credential_fields"].array.allSatisfy { !$0["required"].bool || !(fields[$0["key"].string] ?? "").isEmpty }
        case .ddns: return !credential.isEmpty && ipv4.valid && ipv6.valid && (ipv4.enabled || ipv6.enabled) && (ttl.isEmpty || (Int(ttl) ?? -1) >= 0)
        case .proxy: return !Self.words(domains).isEmpty && URL(string: upstream)?.host != nil && URL(string: upstream)?.port != nil && ["http", "https"].contains(URL(string: upstream)?.scheme ?? "")
        case .notify: return (channelKind == "log" || ["http", "https"].contains(URL(string: url)?.scheme ?? "")) && headers.allSatisfy { !$0.name.isEmpty } && Set(headers.map(\.name)).count == headers.count
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text((item.value == .null ? tr("添加", "Add") : tr("编辑", "Edit")) + " · " + kind.title).font(.title2.bold()); Spacer() }.padding(20)
            Form {
                Section(tr("基本信息", "Details")) {
                    TextField(tr("名称", "Name"), text: $label)
                    if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Text(tr("名称为必填项。", "A name is required.")).font(.caption).foregroundStyle(.red) }
                }
                switch kind {
                case .credentials: credentialForm
                case .ddns: ddnsForm
                case .proxy: proxyForm
                case .notify: notifyForm
                }
                if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
            }.formStyle(.grouped)
            HStack { Button(tr("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); if saving { ProgressView().controlSize(.small) }; Button(tr("保存", "Save")) { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!valid || saving || !model.running) }.padding(20)
        }.frame(width: 620, height: 680).interactiveDismissDisabled(saving)
        .onDisappear { fields = [:]; headers = []; template = ""; url = "" }
    }
    var credentialForm: some View {
        Section(tr("服务商凭据", "Provider Credentials")) {
            Picker(tr("服务商", "Provider"), selection: $provider) {
                Text(tr("请选择", "Select a provider")).tag("")
                ForEach(Array(model.items("/v1/providers").enumerated()), id: \.offset) { _, p in Text(p["display_name"].string).tag(p["name"].string) }
            }.disabled(item.value != .null).onChange(of: provider) { _, _ in if item.value == .null { fields = [:] } }
            if !provider.isEmpty && !providerValue["capabilities"]["available"].bool { Text(tr("此服务商尚未实现，无法保存新凭据。", "This provider is not available yet; new credentials cannot be saved.")).foregroundStyle(.orange) }
            ForEach(Array(providerValue["credential_fields"].array.enumerated()), id: \.offset) { _, field in
                let key = field["key"].string
                let binding = Binding(get: { fields[key] ?? "" }, set: { fields[key] = $0 })
                VStack(alignment: .leading, spacing: 4) {
                    if field["secret"].bool { SecureField(field["label"].string, text: binding, prompt: Text(field["placeholder"].string)) } else { TextField(field["label"].string, text: binding, prompt: Text(field["placeholder"].string)) }
                    if field["required"].bool && (fields[key] ?? "").isEmpty { Text(tr("必填", "Required")).font(.caption).foregroundStyle(.red) }
                    if !field["help"].string.isEmpty { Text(field["help"].string).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if item.value != .null { Text(tr("保留掩码值即可保留现有密钥。明文仅在本次表单中使用。", "Keep the masked value to preserve the existing secret. Plaintext is used only for this form.")).font(.caption).foregroundStyle(.secondary) }
        }
    }
    @ViewBuilder var ddnsForm: some View {
        Section(tr("运行设置", "Operation")) {
            Picker(tr("DNS 凭据", "DNS Credential"), selection: $credential) { Text(tr("请选择", "Select a credential")).tag(""); ForEach(Array(credentials.enumerated()), id: \.offset) { _, c in Text(c["label"].string).tag(c.id) } }
            if credential.isEmpty { Text(tr("请选择支持动态 DNS 的凭据。", "Choose a credential that supports dynamic DNS.")).foregroundStyle(.red) }
            Toggle(tr("启用任务", "Enable Task"), isOn: $enabled)
            TextField(tr("TTL 秒数（留空使用默认值）", "TTL seconds (blank for default)"), text: $ttl)
            TextField(tr("请求绑定网卡（可选）", "Request Interface (optional)"), text: $interface)
        }
        BusinessSourceForm(title: "IPv4", ipv6: false, source: $ipv4)
        BusinessSourceForm(title: "IPv6", ipv6: true, source: $ipv6)
        if !ipv4.enabled && !ipv6.enabled { Section { Text(tr("至少启用一种地址类型。", "Enable at least one address family.")).foregroundStyle(.red) } }
    }
    var proxyForm: some View {
        Section(tr("转发", "Forwarding")) {
            TextField(tr("域名，每行一个", "Domains, one per line"), text: $domains, axis: .vertical).lineLimit(3...6)
            TextField(tr("本机或内网上游 URL", "Local or private upstream URL"), text: $upstream, prompt: Text("http://127.0.0.1:8096"))
            if URL(string: upstream)?.port == nil { Text(tr("上游必须包含 http/https 协议、地址和端口。", "Include http/https, a local or private address, and an explicit port.")).font(.caption).foregroundStyle(.red) }
            Toggle(tr("使用 HTTPS", "Use HTTPS"), isOn: $tls)
            Text(tr("支持 *.example.com 的一级通配域名。保存将立即生效；其他规则会完整保留。", "Wildcard domains such as *.example.com match one subdomain level. Saving takes effect immediately and preserves other routes.")).font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder var notifyForm: some View {
        Section(tr("投递方式", "Delivery")) {
            Picker(tr("通道类型", "Channel Type"), selection: $channelKind) { Text(tr("Webhook", "Webhook")).tag("webhook"); Text(tr("日志", "Log")).tag("log") }
            Toggle(tr("启用", "Enabled"), isOn: $enabled)
            Picker(tr("最低级别", "Minimum Severity"), selection: $severity) { Text(tr("信息", "Information")).tag("info"); Text(tr("警告", "Warning")).tag("warning"); Text(tr("错误", "Error")).tag("error") }
            if channelKind == "webhook" {
                TextField(tr("目标 URL", "Destination URL"), text: $url)
                Picker(tr("请求方法", "Method"), selection: $method) { ForEach(["POST", "PUT", "PATCH", "GET"], id: \.self) { Text($0).tag($0) } }
                TextField(tr("消息模板（留空使用默认格式）", "Message Template (blank for default)"), text: $template, axis: .vertical).lineLimit(4...8).font(.system(.body, design: .monospaced))
                Text(tr("可用变量：", "Available variables: ") + "{{.Event}} {{.Title}} {{.Body}} {{.Severity}} {{.At}}").font(.caption).textSelection(.enabled)
            }
        }
        if channelKind == "webhook" {
            Section(tr("请求头", "Request Headers")) {
                ForEach($headers) { $header in HStack { TextField(tr("名称", "Name"), text: $header.name); TextField(tr("值", "Value"), text: $header.value); Button(role: .destructive) { headers.removeAll { $0.id == header.id } } label: { Image(systemName: "minus.circle") } } }
                Button(tr("添加请求头", "Add Header")) { headers.append(BusinessHeaderField()) }
                Text(tr("请求头会通过 API 原样返回，请勿填写明文密钥。", "Headers are returned by the API. Do not put plaintext secrets here.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    func payload() -> JSONValue {
        switch kind {
        case .credentials: return .object(["provider": .string(provider), "label": .string(label), "fields": .object(fields.mapValues(JSONValue.string))])
        case .ddns: return .object(["label": .string(label), "credential_id": .string(credential), "enabled": .bool(enabled), "ipv4": ipv4.json, "ipv6": ipv6.json, "ttl": .string(ttl), "http_interface": .string(interface)])
        case .proxy:
            var body = item.value.object
            body.merge(["id": .string(item.value == .null ? UUID().uuidString : item.value.id), "label": .string(label), "domains": .array(Self.words(domains).map(JSONValue.string)), "upstream": .string(upstream), "tls": .bool(tls)]) { _, new in new }
            return .object(body)
        case .notify:
            var body = item.value.object
            body.merge(["id": .string(item.value == .null ? UUID().uuidString : item.value.id), "name": .string(label), "kind": .string(channelKind), "enabled": .bool(enabled), "url": .string(url), "method": .string(method), "body_template": .string(template), "min_severity": .string(severity), "headers": .object(Dictionary(uniqueKeysWithValues: headers.map { ($0.name, JSONValue.string($0.value)) }))]) { _, new in new }
            return .object(body)
        }
    }
    func save() {
        guard valid && !saving else { return }; saving = true; error = nil
        let value = payload()
        model.execute {
            defer { saving = false }
            do {
                if kind.atomic {
                    let current = try await model.fetch(kind.path)
                    let id = item.value == .null ? value.id : item.value.id
                    let replacement = try CollectionEdit.replacing(id: id, with: value, baseline: item.baseline.items, current: current.items)
                    _ = try await model.request("PUT", kind.path, body: replacement)
                } else {
                    _ = try await model.request(item.value == .null ? "POST" : "PATCH", kind.path + (item.value == .null ? "" : "/" + KernelClient.pathComponent(item.value.id)), body: value)
                }
                _ = try await model.fetch(kind.path); dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
