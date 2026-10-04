import SwiftUI
import ISCCore

/// 动态解析任务的管理。
///
/// 这是家宽场景的核心：地址会变，而 DNS 里的记录不会自己跟着变。
struct DDNSTaskListView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var editing: DdnsTaskInfo?
    @State private var showingAdd = false
    @State private var running: String?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("动态解析", "Dynamic DNS")).font(.headline)
                    Text(tr("地址变了就自动更新 DNS 记录。", "Updates DNS records when your address changes."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(tr("添加", "Add")) { showingAdd = true }
                    .buttonStyle(.glassProminent)
                    .disabled(dynamicCredentials.isEmpty)
            }
            .padding(20)
            Divider()

            if model.credentials.isEmpty {
                EmptyHint(symbol: "key",
                          title: tr("先添加一个 DNS 凭据", "Add a DNS credential first"),
                          message: tr("动态解析要用凭据去改你的 DNS 记录。",
                                      "Dynamic DNS needs a credential to change your records."))
            } else if dynamicCredentials.isEmpty {
                EmptyHint(symbol: "exclamationmark.triangle",
                          title: tr("没有可用于动态解析的凭据", "No credential can do dynamic DNS"),
                          message: tr("当前凭据的服务商不支持修改记录。", "Your providers do not support changing records."))
            } else if model.ddnsTasks.isEmpty {
                EmptyHint(symbol: "arrow.triangle.2.circlepath",
                          title: tr("还没有动态解析任务", "No dynamic-DNS task yet"),
                          message: tr("如果这台机器的公网地址会变，就建一个。",
                                      "Create one if this machine's public address changes."),
                          action: (tr("添加任务", "Add a task"), { showingAdd = true }))
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.ddnsTasks) { task in
                            row(task)
                        }
                    }
                    .padding(16)
                }
            }

            if let failure {
                Divider()
                Text(failure).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).padding(16)
            }

            Divider()
            HStack {
                Spacer()
                Button(tr("完成", "Done")) { dismiss() }
            }
            .padding(16)
        }
        .frame(width: 620, height: 520)
        .sheet(isPresented: $showingAdd) {
            DDNSTaskFormView(model: model, existing: nil) { await model.refreshAll() }
        }
        .sheet(item: $editing) { task in
            DDNSTaskFormView(model: model, existing: task) { await model.refreshAll() }
        }
    }

    private func row(_ task: DdnsTaskInfo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol(task)).foregroundStyle(tint(task))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.label).font(.callout.weight(.medium))
                    if task.updatesIPv4 { badge("IPv4") }
                    if task.updatesIPv6 { badge("IPv6") }
                    if !task.enabled { badge(tr("已停用", "disabled")) }
                }
                Text(task.domains.isEmpty ? tr("未指定域名", "No domain set") : task.domains.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(caption(task)).font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if running == task.id {
                ProgressView().controlSize(.small)
            } else {
                Button(tr("立即更新", "Run now")) { Task { await run(task) } }
                    .buttonStyle(.glass).controlSize(.small)
                    .disabled(!task.enabled)
                Button { editing = task } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                Button(role: .destructive) {
                    Task { await remove(task) }
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.2), in: .rect(cornerRadius: 10))
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary, in: .capsule)
    }

    private func symbol(_ task: DdnsTaskInfo) -> String {
        guard task.enabled else { return "pause.circle" }
        switch task.lastStatus {
        case "success": return "checkmark.circle.fill"
        case "failed": return "exclamationmark.triangle.fill"
        default: return "clock"
        }
    }

    private func tint(_ task: DdnsTaskInfo) -> Color {
        guard task.enabled else { return .secondary }
        switch task.lastStatus {
        case "success": return .green
        case "failed": return .orange
        default: return .secondary
        }
    }

    private func caption(_ task: DdnsTaskInfo) -> String {
        if let message = task.lastMessage, !message.isEmpty { return message }
        let address = [task.lastIpv4, task.lastIpv6].compactMap { $0 }.filter { !$0.isEmpty }
        guard let last = task.lastRunAt else { return tr("尚未执行", "Never run") }
        let stamp = last.formatted(date: .abbreviated, time: .shortened)
        return address.isEmpty ? stamp : "\(address.joined(separator: " · ")) · \(stamp)"
    }

    private var dynamicCredentials: [CredentialInfo] {
        model.credentials.filter { $0.capabilities?.dynamic == true }
    }

    private func run(_ task: DdnsTaskInfo) async {
        running = task.id
        failure = nil
        do {
            try await model.kernel.runDdnsTask(task.id)
            await model.refreshAll()
        } catch {
            failure = error.localizedDescription
        }
        running = nil
    }

    private func remove(_ task: DdnsTaskInfo) async {
        failure = nil
        do {
            try await model.kernel.deleteDdnsTask(id: task.id)
            await model.refreshAll()
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// 新建/编辑一个动态解析任务。
struct DDNSTaskFormView: View {
    @Bindable var model: AppModel
    /// 为空表示新建。
    let existing: DdnsTaskInfo?
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var credentialID: String?
    @State private var domains = ""

    @State private var ipv4Enabled = true
    @State private var ipv4Type = "netInterface"
    @State private var ipv4Value = ""

    @State private var ipv6Enabled = false
    @State private var ipv6Type = "netInterface"
    @State private var ipv6Value = ""

    @State private var ttl = ""
    @State private var httpInterface = ""

    @State private var busy = false
    @State private var failure: String?
    @State private var loaded = false

    private let getTypes = ["netInterface", "url", "cmd"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(existing == nil ? tr("添加动态解析任务", "Add a dynamic-DNS task")
                                 : tr("编辑动态解析任务", "Edit the dynamic-DNS task"))
                .font(.headline).padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    labeled(tr("名称", "Label")) {
                        TextField(tr("例如：家里的 IPv6", "e.g. Home IPv6"), text: $label)
                            .textFieldStyle(.roundedBorder)
                    }
                    labeled(tr("凭据", "Credential")) {
                        Picker("", selection: $credentialID) {
                            Text(tr("请选择", "Select")).tag(String?.none)
                            ForEach(dynamicCredentials) { credential in
                                Text("\(credential.label) · \(credential.provider)")
                                    .tag(String?.some(credential.id))
                            }
                        }
                        .labelsHidden()
                    }
                    labeled(tr("域名", "Domains")) {
                        TextField(tr("www.example.com, home.example.com", "www.example.com, home.example.com"),
                                  text: $domains)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text(tr("多个用逗号分隔。支持 `www:example.com` 这种显式写根域名的形式，用于自动识别不准的域名。",
                            "Comma separated. `www:example.com` pins the root domain for cases auto-detection gets wrong."))
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    sourceSection(title: tr("IPv4", "IPv4"), enabled: $ipv4Enabled,
                                  getType: $ipv4Type, value: $ipv4Value, selector: nil)
                    sourceSection(title: tr("IPv6", "IPv6"), enabled: $ipv6Enabled,
                                  getType: $ipv6Type, value: $ipv6Value, selector: nil)

                    DisclosureGroup(tr("高级", "Advanced")) {
                        VStack(alignment: .leading, spacing: 10) {
                            labeled(tr("TTL", "TTL")) {
                                TextField(tr("留空用服务商默认值", "Empty for provider default"), text: $ttl)
                                    .textFieldStyle(.roundedBorder)
                            }
                            labeled(tr("请求网卡", "Request interface")) {
                                TextField(tr("留空用默认网卡", "Empty for the default"), text: $httpInterface)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                        .padding(.top, 8)
                    }

                    if let failure {
                        Text(failure).font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(tr("取消", "Cancel")) { dismiss() }
                Button(existing == nil ? tr("添加", "Add") : tr("保存", "Save")) { Task { await save() } }
                    .buttonStyle(.glassProminent)
                    .disabled(!canSave || busy)
            }
            .padding(16)
        }
        .frame(width: 560, height: 620)
        .task { load() }
    }

    @ViewBuilder private func sourceSection(title: String, enabled: Binding<Bool>,
                                            getType: Binding<String>, value: Binding<String>,
                                            selector: Binding<String>?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(title, isOn: enabled).toggleStyle(.switch)
            if enabled.wrappedValue {
                HStack(spacing: 10) {
                    Picker("", selection: getType) {
                        Text(tr("自动（从网卡读取）", "Automatic (from the interface)")).tag("netInterface")
                        Text(tr("外部接口查询", "External lookup")).tag("url")
                        Text(tr("执行命令", "Run a command")).tag("cmd")
                    }
                    .labelsHidden()
                    if getType.wrappedValue != "netInterface" {
                        TextField(getType.wrappedValue == "url" ? "https://api.ipify.org" : "/path/to/script",
                                  text: value)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                if getType.wrappedValue == "netInterface" {
                    Text(tr("由内核从网卡快照里挑选可用于公网的地址。",
                            "The kernel picks a publicly usable address from its interface snapshot."))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.2), in: .rect(cornerRadius: 10))
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.callout).frame(width: 76, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private var dynamicCredentials: [CredentialInfo] {
        model.credentials.filter { $0.capabilities?.dynamic == true }
    }

    private var domainList: [String] {
        domains.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    private var canSave: Bool {
        guard !label.trimmingCharacters(in: .whitespaces).isEmpty,
              credentialID != nil, !domainList.isEmpty else { return false }
        // 至少要更新一种记录类型，否则这个任务什么也不做。
        return ipv4Enabled || ipv6Enabled
    }

    private func load() {
        guard !loaded, let existing else { loaded = true; return }
        label = existing.label
        credentialID = existing.credentialId
        domains = existing.domains.joined(separator: ", ")
        if let source = existing.ipv4 {
            ipv4Enabled = source.enable
            ipv4Type = source.getType
            ipv4Value = source.value
        } else {
            ipv4Enabled = false
        }
        if let source = existing.ipv6 {
            ipv6Enabled = source.enable
            ipv6Type = source.getType
            ipv6Value = source.value
        }
        ttl = existing.ttl ?? ""
        httpInterface = existing.httpInterface ?? ""
        loaded = true
    }

    private func save() async {
        guard let credentialID else { return }
        busy = true
        failure = nil

        var input = DdnsTaskInput(credentialId: credentialID, label: label)
        input.enabled = true
        input.ipv4 = DdnsSource(enable: ipv4Enabled, getType: ipv4Type,
                                value: ipv4Type == "netInterface" ? "" : ipv4Value,
                                domains: domainList)
        input.ipv6 = DdnsSource(enable: ipv6Enabled, getType: ipv6Type,
                                value: ipv6Type == "netInterface" ? "" : ipv6Value,
                                domains: domainList)
        if !ttl.trimmingCharacters(in: .whitespaces).isEmpty { input.ttl = ttl }
        if !httpInterface.trimmingCharacters(in: .whitespaces).isEmpty { input.httpInterface = httpInterface }

        do {
            if let existing {
                _ = try await model.kernel.updateDdnsTask(id: existing.id, input)
            } else {
                _ = try await model.kernel.createDdnsTask(input)
            }
            await onSaved()
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
        busy = false
    }
}
