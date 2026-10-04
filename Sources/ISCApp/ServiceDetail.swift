import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import ISCCore

struct ServiceDetail: View {
    @Bindable var model: AppModel
    let service: PublishedService
    @State private var showDelete = false
    @State private var showVerify = false
    @State private var showRename = false
    @State private var name = ""
    private var current: PublishedService { model.services.first { $0.id == service.id } ?? service }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(current.name).font(.title2.bold()).textSelection(.enabled)
                        Text(current.kind == .httpsForward ? tr("HTTPS 转发", "HTTPS forwarding") : tr("仅动态域名", "Dynamic domain")).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.toggleFavorite(current.id) } label: { Image(systemName: current.favorite ? "star.fill" : "star") }.help(tr("收藏", "Favorite")).buttonStyle(.borderless)
                    Menu {
                        Button(tr("重命名", "Rename")) { name = current.name; showRename = true }
                        Button(tr("删除服务…", "Delete service…"), role: .destructive) { showDelete = true }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.serviceAddress(current)).font(.headline.monospaced()).textSelection(.enabled)
                    HStack {
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.serviceAddress(current), forType: .string) } label: { Label(tr("复制", "Copy"), systemImage: "doc.on.doc") }.buttonStyle(.glass)
                        if current.kind == .httpsForward {
                            Button { if let url = URL(string: model.serviceAddress(current)) { NSWorkspace.shared.open(url) } } label: { Label(tr("打开", "Open"), systemImage: "arrow.up.right.square") }.buttonStyle(.glass)
                        }
                        Button { showVerify = true } label: { Label(tr("验证公网链路", "Verify public link"), systemImage: "qrcode") }.buttonStyle(.glassProminent).disabled(!model.running)
                    }
                }
                Divider()
                if let issue = model.serviceIssue(current) { Label(issue, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                VStack(alignment: .leading, spacing: 12) {
                    Text(tr("配置与状态", "Configuration & Status")).font(.headline)
                    if let task = model.ddns(for: current) {
                        LabeledContent(tr("动态解析", "Dynamic DNS"), value: task["label"].string)
                        LabeledContent(tr("最近执行", "Last run"), value: task["last_run_at"].string.isEmpty ? tr("尚未执行", "Never run") : task["last_run_at"].string)
                        LabeledContent(tr("执行结果", "Result"), value: task["last_message"].string)
                        Button(tr("立即更新解析", "Update DNS now")) { model.execute { _ = try await model.request("POST", "/v1/ddns-tasks/\(KernelClient.pathComponent(task.id))/run"); _ = try await model.fetch("/v1/ddns-tasks") } }.disabled(!model.running)
                    }
                    if let route = model.route(for: current) {
                        LabeledContent(tr("本地目标", "Local target"), value: route["upstream"].string)
                        LabeledContent(tr("反向代理", "Reverse proxy"), value: model.datasets["/v1/proxy/status"]?["running"].bool == true ? tr("运行中", "Running") : tr("未确认运行", "Not confirmed running"))
                        ForEach(model.items("/v1/certs").filter { certificate in certificate["domains"].array.map(\.string).contains(where: current.domains.contains) }, id: \.id) { certificate in
                            LabeledContent(tr("证书", "Certificate"), value: certificate["reason"].string.isEmpty ? certificate["name"].string : certificate["reason"].string)
                        }
                    }
                    Label(tr("配置成功不等于公网可达", "Configured does not mean publicly reachable"), systemImage: "info.circle").foregroundStyle(.secondary).font(.callout)
                    if let verifiedAt = current.verifiedAt {
                        Text(tr("临时端口链路验证：", "Temporary-port link verification: ") + verifiedAt.formatted()).font(.callout)
                        if current.verifiedFingerprint != model.fingerprint(for: current) { Label(tr("配置或地址已变化，需要重新验证", "Configuration or address changed. Verify again."), systemImage: "arrow.clockwise").foregroundStyle(.orange) }
                    } else { Text(tr("尚未验证公网链路", "Public link not yet verified")).foregroundStyle(.secondary) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text(tr("近期活动", "Recent activity")).font(.headline)
                    let relevant = model.events.filter { event in let payload = event["payload"]; return payload["id"].string == current.ddnsID || payload["task_id"].string == current.ddnsID || payload["route_id"].string == current.routeID }
                    if relevant.isEmpty { Text(tr("暂无相关事件", "No related events yet")).foregroundStyle(.secondary) }
                    ForEach(Array(relevant.suffix(15).reversed().enumerated()), id: \.offset) { _, event in
                        VStack(alignment: .leading) { Text(event["type"].string).font(.callout); Text(event["ts"].string).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }.padding(28).frame(maxWidth: 800, alignment: .leading)
        }
        .sheet(isPresented: $showDelete) { DeleteServiceSheet(model: model, service: current) }
        .sheet(isPresented: $showVerify) { ServiceVerification(model: model, serviceID: current.id) }
        .alert(tr("重命名服务", "Rename service"), isPresented: $showRename) {
            TextField(tr("名称", "Name"), text: $name)
            Button(tr("保存", "Save")) { if let index = model.services.firstIndex(where: { $0.id == current.id }), !name.trimmingCharacters(in: .whitespaces).isEmpty { model.services[index].name = name; model.serviceEdited() } }
            Button(tr("取消", "Cancel"), role: .cancel) {}
        }
    }
}

struct DeleteServiceSheet: View {
    @Bindable var model: AppModel
    let service: PublishedService
    @Environment(\.dismiss) private var dismiss
    @State private var removeDDNS = false
    @State private var removeRoute = false
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(tr("删除服务", "Delete service")).font(.title2.bold())
            Text(service.name).font(.headline)
            Text(tr("请选择删除范围。共享凭据和远端 DNS 记录将保留。", "Choose what to remove. Shared credentials and remote DNS records are retained."))
            if service.ddnsID != nil { Toggle(tr("移除关联的 DDNS 配置或域名", "Remove associated DDNS configuration or domains"), isOn: $removeDDNS) }
            if service.routeID != nil { Toggle(tr("移除关联的代理规则或域名", "Remove associated forwarding route or domains"), isOn: $removeRoute) }
            Text(tr("未选中时，仅删除界面中的服务组织信息，不停止内核配置。", "Unchecked items remain active; only the service organization is removed.")).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Button(tr("取消", "Cancel")) { dismiss() }.disabled(busy); Spacer(); if busy { ProgressView().controlSize(.small) }; Button(tr("确认删除", "Delete"), role: .destructive) { Task { await delete() } }.disabled(busy || ((!model.running) && (removeDDNS || removeRoute))) }
        }.padding(24).frame(width: 500)
    }
    func delete() async {
        busy = true; defer { busy = false }
        do {
            if removeRoute, let routeID = service.routeID {
                let baseline = model.items("/v1/proxy/routes")
                let fresh = try await model.fetch("/v1/proxy/routes").items
                guard baseline == fresh else { throw KernelError(code: "stale_edit", message: tr("代理配置已变化，请重试。", "Routes changed. Try again.")) }
                if let route = fresh.first(where: { $0.id == routeID }) {
                    let shared = model.services.contains { $0.id != service.id && $0.routeID == routeID }
                    let retained = route["domains"].array.filter { !service.domains.contains($0.string) }
                    if shared && retained.isEmpty { throw KernelError(code: "shared_route", message: tr("其他服务也使用此规则，请在代理页面调整。", "Another service uses this route. Edit it in Reverse Proxy.")) }
                    var replacement: JSONValue?
                    if !retained.isEmpty { var fields = route.object; fields["domains"] = .array(retained); replacement = .object(fields) }
                    let body = try CollectionEdit.replacing(id: routeID, with: replacement, baseline: fresh, current: fresh)
                    _ = try await model.request("PUT", "/v1/proxy/routes", body: body)
                    _ = try await model.fetch("/v1/proxy/routes")
                }
                removeRoute = false
            }
            if removeDDNS, let taskID = service.ddnsID {
                let task = try await model.fetch("/v1/ddns-tasks/\(KernelClient.pathComponent(taskID))")
                var fields = task.object
                for source in ["ipv4", "ipv6"] {
                    var value = task[source].object
                    let remaining = task[source]["domains"].array.filter { !service.domains.contains($0.string) }
                    value["domains"] = .array(remaining)
                    if remaining.isEmpty { value["enable"] = .bool(false) }
                    fields[source] = .object(value)
                }
                let hasDomains = !fields["ipv4"]!["domains"].array.isEmpty || !fields["ipv6"]!["domains"].array.isEmpty
                let shared = model.services.contains { $0.id != service.id && $0.ddnsID == taskID }
                if !hasDomains && shared { throw KernelError(code: "shared_task", message: tr("其他服务也使用此任务，请在动态解析页面调整。", "Another service uses this task. Edit it in Dynamic DNS.")) }
                if hasDomains { _ = try await model.request("PATCH", "/v1/ddns-tasks/\(KernelClient.pathComponent(taskID))", body: .object(fields)) }
                else { _ = try await model.request("DELETE", "/v1/ddns-tasks/\(KernelClient.pathComponent(taskID))") }
                removeDDNS = false
            }
            try await model.removePublishedService(service.id)
            await model.refreshAll(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct ServiceVerification: View {
    @Bindable var model: AppModel
    let serviceID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var session: JSONValue?
    @State private var target = ""
    @State private var port = "0"
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(tr("验证公网链路", "Verify the public link")).font(.title2.bold())
            Text(tr("关闭手机 Wi-Fi，使用移动网络扫描二维码或打开链接。此验证使用临时端口，只证明该端口的网络链路，不证明应用域名、代理或 HTTPS 全部可用。", "Turn off Wi-Fi on your phone and scan the code using mobile data. This uses a temporary port; it proves that port's network link, not the application domain, proxy or HTTPS."))
            if let session {
                if let image = qrImage(session["url"].string) { Image(nsImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 180, height: 180).frame(maxWidth: .infinity).accessibilityLabel(tr("验证链接二维码", "Verification URL QR code")) }
                Text(session["url"].string).font(.callout.monospaced()).textSelection(.enabled)
                Button(tr("复制链接", "Copy link")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session["url"].string, forType: .string) }
                Label(session["message"].string, systemImage: session["status"].string == "reachable" ? "checkmark.circle.fill" : "network").foregroundStyle(session["status"].string == "reachable" ? .green : .secondary)
                LabeledContent(tr("状态", "Status"), value: session["status"].string)
                LabeledContent(tr("有效期", "Expires"), value: session["expires_at"].string)
            } else {
                TextField(tr("目标公网 IP（留空自动检测 IPv6）", "Public IP (empty for automatic IPv6)"), text: $target)
                TextField(tr("临时验证端口（0 为随机端口）", "Temporary port (0 for automatic)"), text: $port)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button(tr("关闭", "Close")) { dismiss() }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if session == nil { Button(tr("开始验证", "Start verification")) { Task { await start() } }.buttonStyle(.glassProminent).disabled(busy || !model.running) }
                else { Button(tr("停止验证", "Stop verification")) { model.execute { if let session { _ = try await model.request("DELETE", "/v1/verify/sessions/\(KernelClient.pathComponent(session.id))") }; dismiss() } } }
            }
        }.padding(24).frame(width: 520)
        .task(id: session?.id) {
            guard let id = session?.id, !id.isEmpty else { return }
            while !Task.isCancelled, model.running {
                do {
                    let updated = try await model.fetch("/v1/verify/sessions/\(KernelClient.pathComponent(id))")
                    guard !Task.isCancelled else { return }
                    session = updated
                    if updated["status"].string == "reachable" {
                        if let index = model.services.firstIndex(where: { $0.id == serviceID }) { model.services[index].verifiedAt = Date(); model.services[index].verifiedFingerprint = model.fingerprint(for: model.services[index]); model.serviceEdited() }
                        return
                    }
                    if ["unreachable", "stopped"].contains(updated["status"].string) { return }
                    try await Task.sleep(for: .seconds(1))
                } catch { if !Task.isCancelled { self.error = error.localizedDescription }; return }
            }
        }
    }
    func start() async {
        guard let port = Int(port), (0...65535).contains(port) else { error = tr("端口必须在 0–65535 之间。", "Port must be between 0 and 65535."); return }
        busy = true; defer { busy = false }
        do { session = try await model.request("POST", "/v1/verify/sessions", body: .object(["port": .number(Double(port)), "target_ip": .string(target)])); error = nil }
        catch { self.error = error.localizedDescription }
    }
    func qrImage(_ text: String) -> NSImage? {
        guard !text.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
