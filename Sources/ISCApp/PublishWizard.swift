import SwiftUI
import ISCCore

struct PublishWizard: View {
    @Bindable var model: AppModel
    var onVerify: ((PublishedService) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var kind: ServiceKind = .dynamicDomain
    @State private var name = ""
    @State private var domain = ""
    @State private var upstream = "http://127.0.0.1:8080"
    @State private var credentialID = ""
    @State private var ipv4Enabled = true
    @State private var ipv6Enabled = true
    @State private var sourceType = "netInterface"
    @State private var sourceValue = ""
    @State private var acmeEmail = ""
    @State private var busy = false
    @State private var error: String?
    @State private var completed: [String] = []
    init(model: AppModel, onVerify: ((PublishedService) -> Void)? = nil, initialName: String = "", initialDomain: String = "", initialUpstream: String = "http://127.0.0.1:8080") {
        self.model = model
        self.onVerify = onVerify
        _name = State(initialValue: initialName)
        _domain = State(initialValue: initialDomain)
        _upstream = State(initialValue: initialUpstream)
    }
    private var credentials: [JSONValue] { model.items("/v1/credentials") }
    private var validBasics: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && domain.contains(".") && (kind == .dynamicDomain || upstream.contains(":")) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(tr("发布服务", "Publish service")).font(.title2.bold()); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless) }
            ProgressView(value: Double(step + 1), total: 5).tint(.blue)
            Text([tr("服务", "Service"), tr("域名与目标", "Domain & target"), tr("动态解析", "Dynamic DNS"), tr("HTTPS", "HTTPS"), tr("确认发布", "Review")][step]).font(.headline)
            Group { switch step { case 0: serviceStep; case 1: targetStep; case 2: ddnsStep; case 3: tlsStep; default: reviewStep } }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Button(tr("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); if step > 0 { Button(tr("上一步", "Back")) { withAnimation(.easeOut(duration: 0.15)) { step -= 1 } } }; if step < 4 { Button(tr("继续", "Continue")) { advance() }.buttonStyle(.glassProminent).disabled(step == 1 && !validBasics) } else { if busy { ProgressView().controlSize(.small) }; Button(tr("开始发布", "Publish")) { Task { await publish() } }.buttonStyle(.glassProminent).disabled(busy || !validBasics || credentialID.isEmpty) } }
        }.padding(28).frame(width: 620, height: 560).interactiveDismissDisabled(busy)
    }
    private var serviceStep: some View { VStack(alignment: .leading, spacing: 14) { Picker(tr("类型", "Type"), selection: $kind) { Text(tr("仅动态域名", "Dynamic domain")).tag(ServiceKind.dynamicDomain); Text(tr("HTTPS 转发", "HTTPS forwarding")).tag(ServiceKind.httpsForward) }.pickerStyle(.radioGroup); TextField(tr("服务名称", "Service name"), text: $name); Text(tr("普通用户可以先发布动态域名，之后再补充本地转发。", "Start with a dynamic domain, then add local forwarding later.")).foregroundStyle(.secondary) } }
    private var targetStep: some View { VStack(alignment: .leading, spacing: 14) { TextField(tr("域名，例如 home.example.com", "Domain, e.g. home.example.com"), text: $domain); if kind == .httpsForward { TextField(tr("本地目标，例如 http://127.0.0.1:8096", "Local target, e.g. http://127.0.0.1:8096"), text: $upstream); Text(tr("目标必须是本机或内网地址。", "The target must be local or on a private network.")).foregroundStyle(.secondary) } else { Text(tr("域名将由动态解析任务维护。", "The domain will be maintained by Dynamic DNS.")).foregroundStyle(.secondary) } } }
    private var ddnsStep: some View { VStack(alignment: .leading, spacing: 14) { Picker(tr("DNS 凭据", "DNS credential"), selection: $credentialID) { Text(tr("选择账户", "Choose account")).tag(""); ForEach(credentials, id: \.id) { Text($0["label"].string).tag($0.id) } }; Toggle(tr("更新 IPv4", "Update IPv4"), isOn: $ipv4Enabled); Toggle(tr("更新 IPv6", "Update IPv6"), isOn: $ipv6Enabled); Picker(tr("地址来源", "Address source"), selection: $sourceType) { Text(tr("网卡", "Network interface")).tag("netInterface"); Text("URL").tag("url"); Text(tr("命令", "Command")).tag("cmd") }; TextField(tr("来源值（网卡名、URL 或命令）", "Source value (interface, URL or command)"), text: $sourceValue); Text(tr("内核会过滤不可用于公网的地址。", "The kernel filters addresses unsuitable for public access.")).foregroundStyle(.secondary) } }
    private var tlsStep: some View { VStack(alignment: .leading, spacing: 14) { if kind == .httpsForward { TextField(tr("ACME 联系邮箱", "ACME contact email"), text: $acmeEmail); Text(tr("HTTPS 与代理端口是全局设置，发布前会显示影响范围。", "HTTPS and proxy port are global settings; the review shows their impact.")).foregroundStyle(.secondary) } else { ContentUnavailableView(tr("此服务不需要 HTTPS", "HTTPS is not needed for this service"), systemImage: "checkmark.shield") } } }
    private var reviewStep: some View { VStack(alignment: .leading, spacing: 12) { Label(name, systemImage: kind == .httpsForward ? "server.rack" : "globe").font(.headline); LabeledContent(tr("域名", "Domain"), value: domain); LabeledContent(tr("类型", "Type"), value: kind == .httpsForward ? tr("HTTPS 转发", "HTTPS forwarding") : tr("仅动态域名", "Dynamic domain")); if kind == .httpsForward { LabeledContent(tr("本地目标", "Local target"), value: upstream) }; Text(tr("已有无关配置会保留；发布阶段失败会保留已完成步骤。", "Unrelated configuration is retained; completed stages remain after a failure.")).foregroundStyle(.secondary); if !completed.isEmpty { Label(completed.joined(separator: ", "), systemImage: "checkmark.circle").foregroundStyle(.green) } } }
    private func advance() { if step == 2 && credentialID.isEmpty { error = tr("请选择 DNS 凭据。", "Choose a DNS credential."); return }; error = nil; if step < 4 { withAnimation(.easeOut(duration: 0.15)) { step += 1 } } }
    private func source(_ enabled: Bool) -> JSONValue { .object(["enable": .bool(enabled), "get_type": .string(sourceType), "value": .string(sourceValue), "domains": .array([.string(domain)]), "selector": .string("")]) }
    private func publish() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let body: JSONValue = .object(["credential_id": .string(credentialID), "label": .string(name), "enabled": .bool(true), "ipv4": source(ipv4Enabled), "ipv6": source(ipv6Enabled), "http_interface": .string("")])
            let task = try await model.request("POST", "/v1/ddns-tasks", body: body); completed.append(tr("动态解析", "Dynamic DNS"))
            var routeID: String?
            if kind == .httpsForward {
                let route: JSONValue = .object(["id": .string(UUID().uuidString), "label": .string(name), "domains": .array([.string(domain)]), "upstream": .string(upstream), "tls": .bool(true)])
                var routes = model.items("/v1/proxy/routes").filter { !$0["domains"].array.map(\.string).contains(domain) }; routes.append(route)
                let saved = try await model.request("PUT", "/v1/proxy/routes", body: .object(["items": .array(routes)])); routeID = saved.items.first(where: { $0["label"].string == name })?.id ?? route.id; completed.append(tr("代理规则", "Proxy route"))
            }
            let service = PublishedService(name: name, kind: kind, domains: [domain], ddnsID: task.id, routeID: routeID, order: model.services.count)
            model.addService(service); await model.refreshAll(); dismiss(); onVerify?(service)
        } catch let publishError { self.error = publishError.localizedDescription }
    }
}
