import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ISCCore

struct BusinessNetworkView: View {
    let model: AppModel
    @State private var provider = ""
    @State private var readiness: JSONValue?
    @State private var session: JSONValue?
    @State private var port = "0"
    @State private var error: String?
    var providers: [JSONValue] { model.items("/v1/reach/providers") }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("网络可达性", "Network Reachability")).font(.largeTitle.bold())
            HStack {
                Picker(tr("方式", "Method"), selection: $provider) {
                    Text(tr("选择方式", "Choose method")).tag("")
                    ForEach(providers, id: \.id) { p in Text(p["display_name"].string).tag(p["name"].string) }
                }
                Button(tr("探测", "Probe")) { probe() }.disabled(provider.isEmpty)
                Button(tr("开始外部验证", "Start external verification")) { startVerify() }.disabled(!model.running)
            }
            if let readiness {
                Text(readiness["summary"].string).font(.headline)
                ForEach(readiness["checks"].array, id: \.id) { check in
                    VStack(alignment: .leading) {
                        Label(check["name"].string, systemImage: "circle.fill")
                            .foregroundStyle(check["status"].string == "pass" ? .green : .orange)
                        Text(check["detail"].string)
                        Text(check["hint"].string).foregroundStyle(.secondary)
                    }
                }
                Button(tr("生成放行计划", "Plan port exposure")) { plan() }.buttonStyle(.borderedProminent)
            }
            if let session {
                VStack(alignment: .leading, spacing: 8) {
                    Text(session["message"].string).font(.headline)
                    Text(session["url"].string).textSelection(.enabled)
                    Button(tr("停止验证", "Stop verification"), role: .destructive) { stopVerify(session) }
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Spacer()
        }.padding(24).disabled(!model.running)
    }
    func probe() { model.execute { do { readiness = try await model.fetch("/v1/reach/providers/" + KernelClient.pathComponent(provider) + "/probe") } catch { self.error = error.localizedDescription } } }
    func plan() { model.execute { do { readiness = try await model.request("POST", "/v1/reach/providers/" + KernelClient.pathComponent(provider) + "/plan", body: .object(["port": .number(Double(Int(port) ?? 0)), "protocol": .string("tcp"), "label": .string("ISC Phecda")])) } catch { self.error = error.localizedDescription } } }
    func startVerify() { model.execute { do { session = try await model.request("POST", "/v1/verify/sessions", body: .object(["port": .number(Double(Int(port) ?? 0))])) } catch { self.error = error.localizedDescription } } }
    func stopVerify(_ value: JSONValue) { model.execute { _ = try? await model.request("DELETE", "/v1/verify/sessions/" + KernelClient.pathComponent(value.id)); session = nil } }
}

struct BusinessChangesView: View {
    let model: AppModel
    @State private var selected: JSONValue?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(tr("系统变更", "System changes")).font(.largeTitle.bold()); Spacer(); Button(tr("刷新", "Refresh")) { model.execute { _ = try await model.fetch("/v1/changes") } } }
            List(model.items("/v1/changes"), id: \.id) { value in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(value["title"].string).font(.headline); Spacer(); Text(value["status"].string) }
                    Text(value["risk"].string).foregroundStyle(.secondary)
                    if value["status"].string == "applied" { Button(tr("撤销", "Rollback"), role: .destructive) { selected = value } }
                }.padding(.vertical, 8)
            }
        }.padding(24).disabled(!model.running)
        .confirmationDialog(tr("撤销此变更？", "Rollback this change?"), isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            Button(tr("撤销", "Rollback"), role: .destructive) {
                if let value = selected { model.execute { _ = try await model.request("POST", "/v1/changes/" + KernelClient.pathComponent(value["plan_id"].string) + "/rollback"); _ = try await model.fetch("/v1/changes") } }
            }
        }
    }
}

struct BusinessConfigView: View {
    let model: AppModel
    @State private var text = ""
    @State private var preview: JSONValue?
    @State private var includeSecrets = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(tr("配置迁移", "Configuration migration")).font(.largeTitle.bold()); Spacer(); Toggle(tr("包含明文密钥", "Include plaintext secrets"), isOn: $includeSecrets) }
            Text(tr("导出默认不包含密钥。导入先预览，确认后才写入。", "Exports omit secrets by default. Imports are previewed before writing.")).foregroundStyle(.secondary)
            HStack { Button(tr("导出配置", "Export config")) { exportConfig() }; Button(tr("打开 YAML", "Open YAML")) { open() }; Button(tr("预览导入", "Preview import")) { previewImport() }.disabled(text.isEmpty) }
            TextEditor(text: $text).font(.system(.body, design: .monospaced))
            if let preview {
                Text(preview["dry_run"].bool ? tr("预览结果", "Preview") : tr("已应用", "Applied")).font(.headline)
                Text((try? preview.text(pretty: true)) ?? "").textSelection(.enabled)
                if preview["dry_run"].bool { Button(tr("确认导入", "Apply import")) { applyImport() }.buttonStyle(.borderedProminent) }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.padding(24).disabled(!model.running)
    }
    func exportConfig() { model.execute { do { let suffix = includeSecrets ? "?include_secrets=true" : ""; text = try (await model.request("GET", "/v1/config/export" + suffix)).string } catch { self.error = error.localizedDescription } } }
    func open() { let panel = NSOpenPanel(); panel.allowedContentTypes = [.yaml, .plainText]; if panel.runModal() == .OK, let url = panel.url { text = (try? String(contentsOf: url, encoding: .utf8)) ?? "" } }
    func previewImport() { model.execute { do { preview = try await model.requestRaw("POST", "/v1/config/import?dry_run=true", body: text) } catch { self.error = error.localizedDescription } } }
    func applyImport() { model.execute { do { preview = try await model.requestRaw("POST", "/v1/config/import?dry_run=false", body: text); await model.refreshAll() } catch { self.error = error.localizedDescription } } }
}
