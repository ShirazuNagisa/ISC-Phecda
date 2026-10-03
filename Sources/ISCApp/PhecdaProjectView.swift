import SwiftUI
import AppKit
import ISCCore
import ISCSupervisor

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
    @State private var selectedPreset: JSONValue?
    @State private var deploying = false
    @State private var deploymentMessage: String?
    @State private var showDeployConfirmation = false
    @State private var showPublicBinding = false
    @State private var deploymentID: UUID?
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            Text(project["name"].string).font(.title.bold())
            LabeledContent(tr("用途", "Purpose"), value: project["purpose"].string)
            LabeledContent(tr("来源模式", "Source mode"), value: project["source"]["mode"].string)
            Text(project["source"]["value"].string).font(.caption.monospaced()).textSelection(.enabled)
            HStack { Button(tr("只读扫描", "Read-only scan")) { scanProject() }.buttonStyle(.borderedProminent).disabled(busy || !model.running); if busy { ProgressView().controlSize(.small) } }
            if let scan {
                Text(tr("扫描证据", "Scan evidence")).font(.headline)
                ForEach(scan["evidence"].array, id: \.id) { evidence in Label(evidence["file"].string + " · " + evidence["signal"].string, systemImage: "doc.text.magnifyingglass") }
                Text(tr("候选预设", "Candidate presets")).font(.headline)
                ForEach(scan["candidates"].array, id: \.id) { preset in
                    Button { selectedPreset = preset } label: { HStack { Image(systemName: selectedPreset?.id == preset.id ? "checkmark.circle.fill" : "circle"); Text(preset["title"].string); Spacer(); Text(preset["runtime"].string).foregroundStyle(.secondary) } }.buttonStyle(.plain)
                }
                if selectedPreset != nil {
                    Button(tr("预览并部署", "Preview and deploy")) { showDeployConfirmation = true }.buttonStyle(.borderedProminent).disabled(deploying)
                }
                if let deploymentMessage { Text(deploymentMessage).foregroundStyle(.secondary).textSelection(.enabled) }
                Button(tr("绑定公网服务", "Bind public service")) { showPublicBinding = true }.buttonStyle(.bordered).disabled(deploying)
                if !scan["warning"].string.isEmpty { Text(scan["warning"].string).foregroundStyle(.orange) }
            }
            Text(tr("扫描阶段不会安装运行时、执行依赖命令、启动容器或修改 DNS。", "Scanning does not install runtimes, run dependency commands, start containers, or change DNS.")).foregroundStyle(.secondary)
        }.padding(28).frame(maxWidth: 760, alignment: .leading) }
        .confirmationDialog(tr("确认部署？", "Confirm deployment?"), isPresented: $showDeployConfirmation) {
            Button(tr("执行预设部署", "Run preset deployment")) { if let selectedPreset { deploy(preset: selectedPreset) } }
            Button(tr("取消", "Cancel"), role: .cancel) { }
        } message: {
            Text(tr("Phecda 将按预设安装依赖、构建并启动本地服务。命令来自固定 allowlist，不执行 shell。", "Phecda will install dependencies, build, and start the local service using an allowlisted command plan without a shell."))
        }
        .sheet(isPresented: $showPublicBinding) {
            PublishWizard(model: model, onVerify: { service in bind(service) }, initialName: project["name"].string, initialUpstream: "http://127.0.0.1:8080")
        }
    }
    func scanProject() { busy = true; model.execute { defer { busy = false }; scan = try? await model.request("POST", "/v1/phecda/projects/\(KernelClient.pathComponent(project.id))/scan") } }
    func deploy(preset: JSONValue) {
        deploying = true
        let runtime = preset["runtime"].string
        let projectID = UUID(uuidString: project.id)
        model.execute {
            defer { deploying = false }
            guard let projectID else { deploymentMessage = tr("项目 ID 无效。", "The project ID is invalid."); return }
            do {
                let mode = project["source"]["mode"].string
                let value = project["source"]["value"].string
                let localPort = Int(preset["default_port"].number)
                if runtime == "docker" {
                    let source: DockerSourcePlan
                    switch mode {
                    case "composeFile": source = .compose(file: URL(fileURLWithPath: value))
                    case "dockerfileDirectory": source = .dockerfile(directory: URL(fileURLWithPath: value))
                    case "image": source = .image(reference: value)
                    default: throw DockerPlanError.invalidArgument
                    }
                    let plan = try await model.dockerSupervisor.plan(source: source, name: project["name"].string, ports: [localPort])
                    deploymentMessage = plan.display
                    _ = try await model.dockerSupervisor.start(source: source, name: project["name"].string, ports: [localPort])
                } else {
                    guard mode == "directory" else { throw DeploymentPlanError.invalidPlan }
                    let workspace = URL(fileURLWithPath: value, isDirectory: true)
                    let commands: (install: [PresetCommand], build: PresetCommand?, run: PresetCommand)
                    switch runtime {
                    case "staticFiles": commands = ([], nil, .serveStatic)
                    case "node": commands = ([.installNodeDependencies], .buildNode, .runNode)
                    case "python": commands = ([.installPythonDependencies], .buildPython, .runPython)
                    case "php": commands = ([.installPHPDependencies], .buildPHP, .runPHP)
                    case "go": commands = ([.installGoDependencies], .buildGo, .runGo)
                    case "java": commands = ([.installJavaDependencies], .buildJava, .runJava)
                    default: throw DeploymentPlanError.invalidPlan
                    }
                    let plan = try DeploymentPlan(workspace: workspace, installCommands: commands.install, buildCommand: commands.build, runCommand: commands.run, localPort: localPort)
                    let taskID = try await model.submitDeployment(plan)
                    deploymentMessage = tr("部署任务已提交：\(taskID.uuidString)", "Deployment submitted: \(taskID.uuidString)")
                }
                let state = runtime == "docker" ? "running" : "preparing"
                let deployment = try await model.request("POST", "/v1/phecda/deployments", body: .object(["project_id": .string(projectID.uuidString), "preset_id": .string(preset["id"].string), "state": .string(state), "local_port": .number(Double(localPort))]))
                deploymentID = UUID(uuidString: deployment["id"].string)
                _ = try await model.fetch("/v1/phecda/deployments")
            } catch { deploymentMessage = error.localizedDescription }
        }
    }
    func bind(_ service: PublishedService) {
        guard let deploymentID else { return }
        model.execute {
            let body: JSONValue = .object(["id": .string(deploymentID.uuidString), "project_id": .string(project.id), "preset_id": .string(selectedPreset?["id"].string ?? ""), "state": .string("running"), "public_service_id": .string(service.id.uuidString)])
            _ = try await model.request("POST", "/v1/phecda/deployments", body: body)
            _ = try await model.fetch("/v1/phecda/deployments")
            deploymentMessage = tr("公网服务已关联。", "Public service binding saved.")
        }
    }
}
