import SwiftUI
import AppKit
import ISCCore

/// 发布新服务的向导。
///
/// 顺序刻意是"先选目录、再看识别结果"：用户不需要先知道自己的项目是什么
/// 技术栈 —— 那正是要 Phecda 来判断的事。识别结果会连同**依据**一起显示，
/// 这样用户能确认它没认错，也能在认错时自己改。
struct NewServiceView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var sourcePath: String = ""
    @State private var inspection: SourceInspection?
    @State private var presetID: String = ""
    @State private var name: String = ""
    @State private var domains: String = ""
    @State private var autoStart = true
    @State private var customExecutable = ""
    @State private var customArguments = ""
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    folderStep
                    if let inspection { resultStep(inspection) }
                    detailsStep
                    customStep
                    if let failure { errorBox(failure) }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 640)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("发布新服务", "Publish a site")).font(.headline)
                Text(tr("选一个源码目录，其余交给 Phecda。", "Pick a source folder and let Phecda handle the rest."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var folderStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("1. 源码目录", "1. Source folder")).font(.headline)
            HStack(spacing: 10) {
                Text(sourcePath.isEmpty ? tr("尚未选择", "Nothing selected") : sourcePath)
                    .font(.callout)
                    .foregroundStyle(sourcePath.isEmpty ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                Button(tr("选择…", "Choose…")) { chooseFolder() }.buttonStyle(.glass)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 10))
        }
    }

    @ViewBuilder private func resultStep(_ inspection: SourceInspection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("2. 识别结果", "2. Detection")).font(.headline)

            if !inspection.evidence.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("依据", "Evidence")).font(.caption).foregroundStyle(.secondary)
                    ForEach(inspection.evidence.prefix(6)) { item in
                        HStack(spacing: 6) {
                            Text(item.file).font(.system(.caption, design: .monospaced))
                            Text(item.signal).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.0f%%", item.confidence * 100))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 10))
            }

            ForEach(Array((inspection.warnings ?? []).enumerated()), id: \.offset) { _, warning in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                    Text(warning).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }

            Picker(tr("使用哪种方式部署", "How to deploy"), selection: $presetID) {
                ForEach(model.presets) { preset in
                    Text(presetLabel(preset)).tag(preset.id)
                }
            }
            .pickerStyle(.menu)

            if let selected = model.presets.first(where: { $0.id == presetID }) {
                if let note = selected.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if selected.needsDocker {
                    Text(tr("需要本机已安装 Docker Desktop。", "Requires Docker Desktop to be installed."))
                        .font(.caption).foregroundStyle(.orange)
                }
                // 跑不了时明说，并且**不让继续** —— 让用户填完再失败是最坏的时机。
                if !selected.isRunnable {
                    Label(selected.unavailableReason
                              ?? tr("这一版没有内置它需要的运行时，装了也跑不起来。",
                                    "This build does not include the runtime it needs, so it cannot run."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 选项文字。
    ///
    /// 跑不了的预设**照样列出来但标出来**，而不是藏起来：用户可能正是奔着
    /// 它来的（比如手里就是个 .NET 项目），藏起来他会以为这个产品不支持，
    /// 而真相是这一版没内置那个运行时 —— 那是两件完全不同的事。
    private func presetLabel(_ preset: PresetInfo) -> String {
        var parts = [preset.title]
        if !preset.isRunnable {
            parts.append(tr("这一版没有内置", "not included in this build"))
        } else if inspection?.recommendedPresetId == preset.id {
            parts.append(tr("推荐", "recommended"))
        }
        return parts.joined(separator: " · ")
    }

    private var detailsStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("3. 名称与域名", "3. Name and domain")).font(.headline)
            TextField(tr("名称", "Name"), text: $name).textFieldStyle(.roundedBorder)
            TextField(tr("域名（多个用逗号分隔，可留空）", "Domain (comma separated, optional)"), text: $domains)
                .textFieldStyle(.roundedBorder)
            Toggle(tr("内核启动时自动拉起", "Start automatically when the kernel starts"), isOn: $autoStart)
                .toggleStyle(.switch)
            Text(tr("留空域名就只在 127.0.0.1 上提供访问。", "Leave the domain empty to serve it on 127.0.0.1 only."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var customStep: some View {
        if presetID == "custom" {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("4. 自定义启动命令", "4. Custom start command")).font(.headline)
                TextField(tr("可执行文件", "Executable"), text: $customExecutable)
                    .textFieldStyle(.roundedBorder)
                TextField(tr("参数（空格分隔）", "Arguments (space separated)"), text: $customArguments)
                    .textFieldStyle(.roundedBorder)
                Text(tr("命令按参数逐项执行，不经 shell，因此管道、重定向与变量展开都不可用。端口用 {port} 表示。",
                        "The command runs directly, never through a shell, so pipes, redirection and variable expansion are unavailable. Use {port} for the port."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func errorBox(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            Text(text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.1), in: .rect(cornerRadius: 10))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if busy { ProgressView().controlSize(.small) }
            Spacer()
            Button(tr("取消", "Cancel")) { dismiss() }
            Button(tr("发布并部署", "Publish and deploy")) { Task { await publish() } }
                .buttonStyle(.glassProminent)
                .disabled(!canPublish || busy)
        }
        .padding(16)
    }

    private var canPublish: Bool {
        guard !sourcePath.isEmpty, !presetID.isEmpty, !name.isEmpty else { return false }
        // 跑不了的预设不让提交：让用户填完再失败是最坏的时机 —— 他会以为
        // 是自己哪里填错了，而真相是这一版没内置那个运行时。
        if let preset = model.presets.first(where: { $0.id == presetID }), !preset.isRunnable {
            return false
        }
        if presetID == "custom" { return !customExecutable.isEmpty }
        return true
    }

    // MARK: 动作

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = tr("选择", "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sourcePath = url.path
        if name.isEmpty { name = url.lastPathComponent }
        Task { await inspect(url.path) }
    }

    private func inspect(_ path: String) async {
        busy = true
        failure = nil
        do {
            if model.presets.isEmpty { await model.loadCatalogs() }
            let result = try await model.kernel.inspectSource(path: path)
            inspection = result
            presetID = result.recommendedPresetId
            if let preset = model.presets.first(where: { $0.id == result.recommendedPresetId }), !preset.isStatic {
                // 需要运行时的站点，名字建议保留目录名即可。
            }
        } catch {
            failure = error.localizedDescription
            inspection = nil
        }
        busy = false
    }

    private func publish() async {
        busy = true
        failure = nil
        do {
            let request = buildRequest()
            let created = try await model.createService(request, deploy: true)
            model.selectedAppID = created.id
            model.section = .services
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
        busy = false
    }

    private func buildRequest() -> AppCreateRequest {
        var request = AppCreateRequest(name: name, presetId: presetID, sourcePath: sourcePath)
        let parsed = domains
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        request.domains = parsed.isEmpty ? nil : parsed
        request.autoStart = autoStart
        if presetID == "custom" {
            request.customExecutable = customExecutable
            request.customArgs = customArguments
                .split(separator: " ").map(String.init).filter { !$0.isEmpty }
        }
        return request
    }
}
