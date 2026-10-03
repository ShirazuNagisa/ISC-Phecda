import SwiftUI
import ISCCore

struct BusinessView: View {
    let model: AppModel
    let section: String
    var body: some View {
        Group {
            switch section {
            case "credentials": BusinessCollectionView(model: model, kind: .credentials)
            case "ddns": BusinessCollectionView(model: model, kind: .ddns)
            case "dns": BusinessDNSView(model: model)
            case "proxy": BusinessCollectionView(model: model, kind: .proxy)
            case "notify": BusinessCollectionView(model: model, kind: .notify)
            case "network": BusinessNetworkView(model: model)
            case "changes": BusinessChangesView(model: model)
            case "config": BusinessConfigView(model: model)
            case "certs", "tasks", "audit": BusinessActivityView(model: model, section: section)
            default: ContentUnavailableView(tr("选择管理项目", "Choose a management section"), systemImage: "sidebar.left")
            }
        }.tint(.blue)
    }
}

enum BusinessKind: String, Identifiable {
    case credentials, ddns, proxy, notify
    var id: String { rawValue }
    var path: String { switch self { case .credentials: "/v1/credentials"; case .ddns: "/v1/ddns-tasks"; case .proxy: "/v1/proxy/routes"; case .notify: "/v1/notify/channels" } }
    var title: String { switch self { case .credentials: tr("DNS 凭据", "DNS Credentials"); case .ddns: tr("动态 DNS", "Dynamic DNS"); case .proxy: tr("转发规则", "Forwarding Routes"); case .notify: tr("通知通道", "Notification Channels") } }
    var atomic: Bool { self == .proxy || self == .notify }
}

struct BusinessEditorItem: Identifiable { let id = UUID(); let value: JSONValue; let baseline: JSONValue }

struct BusinessCollectionView: View {
    let model: AppModel
    let kind: BusinessKind
    @State private var editor: BusinessEditorItem?
    @State private var deleteItem: JSONValue?
    @State private var search = ""
    @State private var result: String?
    var rows: [JSONValue] { model.items(kind.path).filter { search.isEmpty || summary($0).localizedCaseInsensitiveContains(search) } }
    func summary(_ value: JSONValue) -> String { [value["label"].string, value["name"].string, value["provider"].string, value["upstream"].string, value["domains"].array.map(\.string).joined(separator: ", ")].joined(separator: " ") }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(kind.title).font(.largeTitle.bold()); Spacer()
                Button { refresh() } label: { Label(tr("刷新", "Refresh"), systemImage: "arrow.clockwise") }
                Button { open(nil) } label: { Label(tr("添加", "Add"), systemImage: "plus") }.buttonStyle(.borderedProminent)
            }
            if kind == .proxy {
                let status = model.datasets["/v1/proxy/status"] ?? .null
                Label(status["running"].bool ? tr("代理正在运行", "Proxy running") : tr("代理已停止", "Proxy stopped"), systemImage: status["running"].bool ? "checkmark.circle" : "pause.circle")
                if !status["error"].string.isEmpty { Text(status["error"].string).foregroundStyle(.red) }
            }
            if let result { Text(result).foregroundStyle(.secondary).textSelection(.enabled) }
            if let error = model.datasets[kind.path]?["client_error"].string, !error.isEmpty { Text(error).foregroundStyle(.red) }
            List {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: icon).foregroundStyle(.blue).frame(width: 24)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(displayName(row)).font(.headline)
                            Text(subtitle(row)).foregroundStyle(.secondary).textSelection(.enabled)
                            if kind == .ddns {
                                Text([row["last_ipv4"].string, row["last_ipv6"].string].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).textSelection(.enabled)
                                Text(row["last_message"].string).font(.caption).foregroundStyle(row["last_status"].string == "failed" ? .red : .secondary)
                            }
                        }
                        Spacer()
                        if kind == .credentials {
                            Button(tr("测试连接", "Test Connection")) { model.execute { let response = try await model.request("POST", itemPath(row) + "/verify"); result = response["message"].string; _ = try await model.fetch(kind.path) } }.disabled(!row["capabilities"]["verify"].bool)
                        }
                        if kind == .ddns { Button(tr("立即更新", "Update Now")) { model.execute { _ = try await model.request("POST", itemPath(row) + "/run"); _ = try await model.fetch(kind.path) } } }
                        Button(tr("编辑", "Edit")) { open(row) }
                        Button(role: .destructive) { deleteItem = row } label: { Image(systemName: "trash") }.help(tr("删除", "Delete"))
                    }.padding(.vertical, 8)
                }
                if rows.isEmpty { ContentUnavailableView(tr("暂无项目", "No items"), systemImage: icon, description: Text(tr("添加配置后会在这里显示。", "Add a configuration to see it here."))) }
            }.listStyle(.inset)
            if kind == .notify {
                HStack { Text(tr("最近投递", "Recent Deliveries")).font(.headline); Spacer(); Button(tr("发送测试通知", "Send Test Notification")) { model.execute { model.datasets["/v1/notify/deliveries"] = try await model.request("POST", "/v1/notify/test") } } }
                List(Array(model.items("/v1/notify/deliveries").enumerated()), id: \.offset) { _, item in
                    HStack { Image(systemName: item["ok"].bool ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(item["ok"].bool ? .green : .red); Text(item["channel"].string); Text(item["at"].string).foregroundStyle(.secondary); Text(item["error"].string).foregroundStyle(.red) }
                }.frame(minHeight: 100, maxHeight: 180)
            }
        }.padding(24).searchable(text: $search, prompt: tr("搜索", "Search")).disabled(!model.running)
        .sheet(item: $editor) { item in BusinessEditor(model: model, kind: kind, item: item) }
        .confirmationDialog(tr("删除此项目？", "Delete this item?"), isPresented: Binding(get: { deleteItem != nil }, set: { if !$0 { deleteItem = nil } }), titleVisibility: .visible) {
            Button(tr("删除", "Delete"), role: .destructive) {
                guard let row = deleteItem else { return }; deleteItem = nil
                model.execute {
                    if kind.atomic {
                        let baseline = model.datasets[kind.path] ?? .null
                        let current = try await model.fetch(kind.path)
                        let body = try CollectionEdit.replacing(id: row.id, with: nil, baseline: baseline.items, current: current.items)
                        _ = try await model.request("PUT", kind.path, body: body)
                    } else { _ = try await model.request("DELETE", itemPath(row)) }
                    _ = try await model.fetch(kind.path)
                }
            }
        } message: { Text(kind == .credentials ? tr("正在使用的凭据无法删除。", "Credentials in use cannot be deleted.") : tr("此配置将被移除。", "This configuration will be removed.")) }
    }
    var icon: String { switch kind { case .credentials: "key"; case .ddns: "arrow.triangle.2.circlepath"; case .proxy: "arrow.triangle.branch"; case .notify: "bell" } }
    func displayName(_ row: JSONValue) -> String { let name = row[kind == .notify ? "name" : "label"].string; return name.isEmpty ? row.id : name }
    func subtitle(_ row: JSONValue) -> String {
        switch kind {
        case .credentials: row["provider"].string + (row["capabilities"]["available"].bool ? "" : " · " + tr("尚未实现", "Not available"))
        case .ddns: [row["ipv4"]["domains"].array, row["ipv6"]["domains"].array].flatMap { $0 }.map(\.string).joined(separator: ", ")
        case .proxy: row["domains"].array.map(\.string).joined(separator: ", ") + " → " + row["upstream"].string
        case .notify: row["kind"].string + " · " + row["url"].string
        }
    }
    func itemPath(_ row: JSONValue) -> String { kind.path + "/" + KernelClient.pathComponent(row.id) }
    func refresh() { model.execute { _ = try await model.fetch(kind.path) } }
    func open(_ row: JSONValue?) {
        model.execute {
            let baseline = try await model.fetch(kind.path)
            let latest = row.flatMap { original in baseline.items.first { $0.id == original.id } }
            if row != nil && latest == nil { throw KernelError(code: "not_found", message: tr("项目已被删除。", "This item was deleted.")) }
            editor = BusinessEditorItem(value: latest ?? .null, baseline: baseline)
        }
    }
}

struct BusinessActivityView: View {
    let model: AppModel
    let section: String
    @State private var search = ""
    @State private var filter = ""
    @State private var cancel: JSONValue?
    @State private var page: JSONValue?
    var path: String { section == "certs" ? "/v1/certs" : section == "tasks" ? "/v1/jobs" : "/v1/audit" }
    var title: String { section == "certs" ? tr("TLS 证书", "TLS Certificates") : section == "tasks" ? tr("任务中心", "Tasks") : tr("审计日志", "Audit Log") }
    var rows: [JSONValue] { (page ?? model.datasets[path] ?? .null).items.filter { row in search.isEmpty || [row["name"].string, row["kind"].string, row["action"].string, row["target"].string].joined(separator: " ").localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(.largeTitle.bold()); Spacer()
                if section != "certs" {
                    Picker(tr("状态", "Status"), selection: $filter) {
                        Text(tr("全部", "All")).tag("")
                        ForEach(section == "tasks" ? ["pending", "running", "succeeded", "failed", "canceled"] : ["success", "failure", "denied"], id: \.self) { Text(BusinessStatus.title($0)).tag($0) }
                    }.frame(width: 180).onChange(of: filter) { _, _ in load() }
                }
                Button(tr("刷新", "Refresh")) { load() }
                if section == "certs" { Button(tr("检查并续期", "Check & Renew")) { model.execute { model.datasets[path] = try await model.request("POST", "/v1/certs/renew") } }.buttonStyle(.borderedProminent) }
            }
            if section == "certs" { Text(tr("HTTPS 转发规则决定要申请的证书。有效证书不会重复签发。", "HTTPS routes determine which certificates are issued. Valid certificates are not reissued.")).foregroundStyle(.secondary) }
            List {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(section == "certs" ? row["name"].string : section == "tasks" ? row["kind"].string : row["action"].string).font(.headline); Spacer()
                            if section == "tasks" { Text(BusinessStatus.title(row["status"].string)); if ["pending", "running"].contains(row["status"].string) { Button(tr("取消任务", "Cancel Task"), role: .destructive) { cancel = row } } }
                            if section == "audit" { Text(BusinessStatus.title(row["result"].string)) }
                            if section == "certs" { Text(row["needs_renew"].bool ? tr("需要续期", "Renewal needed") : tr("有效", "Valid")).foregroundStyle(row["needs_renew"].bool ? .orange : .green) }
                        }
                        if section == "tasks" {
                            ProgressView(value: row["progress"].number); Text(row["message"].string)
                            Text(row["error"]["detail"].string).foregroundStyle(.red)
                            Text(row["created_at"].string).font(.caption).foregroundStyle(.secondary)
                        } else if section == "certs" {
                            Text(row["domains"].array.map(\.string).joined(separator: ", ")).textSelection(.enabled)
                            LabeledContent(tr("到期时间", "Expires"), value: row["expires_at"].string)
                            if row["staging"].bool { Label(tr("测试证书，浏览器不信任", "Staging certificate — not trusted by browsers"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                            Text(row["reason"].string).foregroundStyle(.secondary); Text(row["error"].string).foregroundStyle(.red)
                        } else {
                            Text(row["target"].string).textSelection(.enabled); Text(row["detail"].string)
                            Text(row["ts"].string + " · " + row["remote"].string).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                }
                if rows.isEmpty { ContentUnavailableView(tr("暂无记录", "No records"), systemImage: section == "certs" ? "checkmark.shield" : "list.bullet.rectangle") }
            }
            if !(page ?? model.datasets[path] ?? .null)["next_cursor"].string.isEmpty { Button(tr("下一页", "Next Page")) { load(cursor: (page ?? model.datasets[path] ?? .null)["next_cursor"].string) } }
        }.padding(24).searchable(text: $search, prompt: tr("搜索", "Search")).disabled(!model.running)
        .confirmationDialog(tr("取消正在执行的任务？", "Cancel this task?"), isPresented: Binding(get: { cancel != nil }, set: { if !$0 { cancel = nil } }), titleVisibility: .visible) {
            Button(tr("取消任务", "Cancel Task"), role: .destructive) { guard let row = cancel else { return }; cancel = nil; model.execute { _ = try await model.request("POST", "/v1/jobs/" + KernelClient.pathComponent(row.id) + "/cancel"); _ = try await model.fetch(path); page = nil } }
        }
    }
    func load(cursor: String = "") { model.execute { var query = [String](); if !filter.isEmpty { query.append((section == "tasks" ? "status=" : "result=") + KernelClient.pathComponent(filter)) }; if !cursor.isEmpty { query.append("cursor=" + KernelClient.pathComponent(cursor)) }; page = try await model.fetch(path + (query.isEmpty ? "" : "?" + query.joined(separator: "&"))) } }
}

enum BusinessStatus {
    static func title(_ value: String) -> String {
        switch value {
        case "pending": tr("等待执行", "Pending")
        case "running", "applying": tr("执行中", "Running")
        case "succeeded", "success", "applied": tr("成功", "Succeeded")
        case "failed", "failure": tr("失败", "Failed")
        case "canceled": tr("已取消", "Canceled")
        case "denied": tr("已拒绝", "Denied")
        case "rolled_back": tr("已撤销", "Rolled back")
        case "rollback_failed": tr("撤销失败，需要检查系统", "Rollback failed — inspect the system")
        case "waiting": tr("等待外部访问", "Waiting for external access")
        case "reachable": tr("公网可达", "Reachable externally")
        case "hairpin_only": tr("仅局域网访问，尚未证明公网可达", "Local access only — external reachability unproven")
        case "unreachable": tr("未收到外部访问", "No external access received")
        case "stopped": tr("已停止", "Stopped")
        case "pass": tr("通过", "Passed")
        case "fail": tr("未通过", "Failed")
        case "warn": tr("有隐患", "Warning")
        case "unknown": tr("尚无法确认", "Unknown")
        case "blocked": tr("上游阻断", "Blocked upstream")
        case "low": tr("低风险", "Low risk")
        case "medium": tr("中等风险", "Medium risk")
        case "high": tr("高风险", "High risk")
        default: value
        }
    }
}
