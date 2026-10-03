import SwiftUI
import AppKit
import ISCCore

struct PhecdaProjectView: View {
    let model: AppModel
    let createImmediately: Bool
    @State private var showCreate = false
    @State private var selected: JSONValue?
    @State private var error: String?
    init(model: AppModel, createImmediately: Bool = false) { self.model = model; self.createImmediately = createImmediately; _showCreate = State(initialValue: createImmediately) }
    var projects: [JSONValue] { model.items("/v1/phecda/projects") }
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text(tr("我的服务器", "My servers")).font(.largeTitle.bold()); Spacer(); Button { showCreate = true } label: { Label(tr("创建服务器", "Create server"), systemImage: "plus") }.buttonStyle(.borderedProminent) }
                Text(tr("项目与公网服务分开管理。Docker 使用独立创建流程，不会默认要求源码目录。", "Projects and public services are separate. Docker has its own creation flow and does not require a source directory by default.")).foregroundStyle(.secondary)
                List(projects, id: \.id, selection: Binding(get: { selected?.id }, set: { id in selected = projects.first { $0.id == id } })) { project in
                    VStack(alignment: .leading, spacing: 5) { Text(project["name"].string).font(.headline); Text(project["purpose"].string).font(.caption).foregroundStyle(.secondary); Text(project["source"]["mode"].string).font(.caption2).foregroundStyle(.tertiary) }.tag(project.id)
                }
            }.padding(22).frame(minWidth: 300, idealWidth: 360)
            if let selected { PhecdaProjectDetail(model: model, project: selected) } else { ContentUnavailableView(tr("选择一个项目", "Select a project"), systemImage: "server.rack", description: Text(tr("或者创建一个新的服务器项目。", "Or create a new server project."))).frame(maxWidth: .infinity) }
        }
        .sheet(isPresented: $showCreate) { PhecdaCreateProjectSheet(model: model) }
        .alert(tr("无法处理项目", "Project error"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
}

struct PhecdaCreateProjectSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var purpose = "website"
    @State private var docker = false
    @State private var mode = "directory"
    @State private var value = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("创建服务器项目", "Create server project")).font(.title2.bold())
            Picker(tr("服务用途", "Purpose"), selection: $purpose) { Text(tr("网站", "Website")).tag("website"); Text("API").tag("api"); Text(tr("游戏服务器", "Game server")).tag("gameServer"); Text(tr("文件服务", "File service")).tag("fileService"); Text(tr("自定义", "Custom")).tag("custom") }.pickerStyle(.segmented)
            TextField(tr("项目名称", "Project name"), text: $name)
            Toggle(tr("这是 Docker 服务", "This is a Docker service"), isOn: $docker)
            if docker {
                Picker(tr("Docker 来源", "Docker source"), selection: $mode) { Text("Compose").tag("composeFile"); Text("Dockerfile").tag("dockerfileDirectory"); Text(tr("已有镜像", "Image")).tag("image"); Text(tr("简易命令", "Quick command")).tag("command") }
                TextField(mode == "image" ? tr("镜像名称", "Image reference") : mode == "command" ? tr("Docker 命令（执行前会预览）", "Docker command (previewed before execution)") : tr("文件或目录路径", "File or directory path"), text: $value)
                Text(tr("Docker 建站不会自动安装 Docker Desktop，也不会默认执行特权或宿主目录挂载。", "Docker setup does not install Docker Desktop or enable privileged host access by default.")).font(.caption).foregroundStyle(.secondary)
            } else {
                HStack { TextField(tr("源码目录或压缩包路径", "Source directory or archive path"), text: $value); Button(tr("选择…", "Choose…")) { choosePath() } }
                Text(tr("创建时只登记来源；扫描不会执行源码命令。", "Creation only registers the source; scanning never executes source commands.")).font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Button(tr("取消", "Cancel")) { dismiss() }; Spacer(); if busy { ProgressView().controlSize(.small) }; Button(tr("登记项目", "Register project")) { create() }.buttonStyle(.borderedProminent).disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 580)
    }
    func choosePath() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false; if panel.runModal() == .OK { value = panel.url?.path ?? "" } }
    func create() { busy = true; let source: JSONValue = .object(["mode": .string(mode), "value": .string(value)]); model.execute { do { _ = try await model.request("POST", "/v1/phecda/projects", body: .object(["name": .string(name), "purpose": .string(purpose), "source": source])); _ = try await model.fetch("/v1/phecda/projects"); dismiss() } catch { self.error = error.localizedDescription; busy = false } } }
}

struct PhecdaProjectDetail: View {
    let model: AppModel
    let project: JSONValue
    @State private var scan: JSONValue?
    @State private var busy = false
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            Text(project["name"].string).font(.title.bold())
            LabeledContent(tr("用途", "Purpose"), value: project["purpose"].string)
            LabeledContent(tr("来源模式", "Source mode"), value: project["source"]["mode"].string)
            Text(project["source"]["value"].string).font(.caption.monospaced()).textSelection(.enabled)
            HStack { Button(tr("只读扫描", "Read-only scan")) { scanProject() }.buttonStyle(.borderedProminent).disabled(busy || !model.running); if busy { ProgressView().controlSize(.small) } }
            if let scan { Text(tr("扫描证据", "Scan evidence")).font(.headline); ForEach(scan["evidence"].array, id: \.id) { evidence in Label(evidence["file"].string + " · " + evidence["signal"].string, systemImage: "doc.text.magnifyingglass") }; Text(tr("候选预设", "Candidate presets")).font(.headline); ForEach(scan["candidates"].array, id: \.id) { preset in Text(preset["title"].string + " · " + preset["runtime"].string) }; if !scan["warning"].string.isEmpty { Text(scan["warning"].string).foregroundStyle(.orange) } }
            Text(tr("扫描阶段不会安装运行时、执行依赖命令、启动容器或修改 DNS。", "Scanning does not install runtimes, run dependency commands, start containers, or change DNS.")).foregroundStyle(.secondary)
        }.padding(28).frame(maxWidth: 760, alignment: .leading) }
    }
    func scanProject() { busy = true; model.execute { defer { busy = false }; scan = try? await model.request("POST", "/v1/phecda/projects/\(KernelClient.pathComponent(project.id))/scan") } }
}
