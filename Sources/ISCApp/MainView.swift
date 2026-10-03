import SwiftUI
import AppKit
import ISCCore
import ServiceManagement

struct NavigationSection: Identifiable {
    let id: String
    let zh: String
    let en: String
    let symbol: String
    var title: String { tr(zh, en) }
    static let all: [Self] = [
        .init(id: "services", zh: "发布的服务", en: "Services", symbol: "server.rack"),
        .init(id: "credentials", zh: "DNS 凭据", en: "DNS Credentials", symbol: "key"),
        .init(id: "ddns", zh: "动态解析", en: "Dynamic DNS", symbol: "arrow.triangle.2.circlepath"),
        .init(id: "dns", zh: "DNS 记录", en: "DNS Records", symbol: "list.bullet.rectangle"),
        .init(id: "proxy", zh: "反向代理", en: "Reverse Proxy", symbol: "arrow.triangle.branch"),
        .init(id: "certs", zh: "证书", en: "Certificates", symbol: "lock.shield"),
        .init(id: "network", zh: "网络与验证", en: "Network & Verification", symbol: "network"),
        .init(id: "notify", zh: "通知", en: "Notifications", symbol: "bell"),
        .init(id: "tasks", zh: "任务中心", en: "Tasks", symbol: "checklist"),
        .init(id: "audit", zh: "审计日志", en: "Audit", symbol: "clock.arrow.circlepath"),
        .init(id: "changes", zh: "系统变更", en: "System Changes", symbol: "slider.horizontal.3"),
        .init(id: "config", zh: "配置迁移", en: "Configuration", symbol: "square.and.arrow.down"),
        .init(id: "settings", zh: "设置", en: "Settings", symbol: "gearshape")
    ]
}

struct MainView: View {
    @Bindable var model: AppModel
    let newWindow: () -> Void
    @State private var section: String? = "services"
    @State private var query = ""
    @State private var selectedID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(NavigationSection.all) { item in Label(item.title, systemImage: item.symbol).tag(item.id) }
            }.navigationSplitViewColumnWidth(min: 185, ideal: 215, max: 280)
            .safeAreaInset(edge: .bottom) {
                HStack { Circle().fill(model.running ? .green : .orange).frame(width: 7, height: 7); Text(model.running ? tr("内核运行中", "Kernel running") : tr("内核未运行", "Kernel stopped")).font(.caption); Spacer() }.padding()
            }
        } detail: {
            VStack(spacing: 0) {
                if let notice = model.notice {
                    HStack { Label(notice, systemImage: "checkmark.circle"); Spacer(); Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless) }.padding(12).font(.callout).background(.blue.opacity(0.07))
                }
                if !query.isEmpty { SearchResults(model: model, query: query, chooseSection: { section = $0; query = "" }, chooseService: { selectedID = $0; section = "services"; query = "" }) }
                else if section == "services" {
                    ServiceListView(model: model, selectedID: $selectedID)
                } else if section == "settings" { SettingsView(model: model) }
                else { BusinessView(model: model, section: section ?? "credentials") }
            }
            .navigationTitle(NavigationSection.all.first { $0.id == section }?.title ?? "ISC")
            .toolbar {
                ToolbarItem { Button { newWindow() } label: { Image(systemName: "macwindow.badge.plus") }.help(tr("新建管理窗口", "New management window")) }
                ToolbarItem { Button { Task { await model.refreshAll() } } label: { Image(systemName: "arrow.clockwise") }.disabled(!model.running) }
                ToolbarItem { Button { model.showWizard = true } label: { Label(tr("发布服务", "Publish service"), systemImage: "plus") }.disabled(!model.running) }
            }
            .searchable(text: $query, prompt: tr("搜索服务、域名、凭据或设置", "Search services, domains, credentials or settings"))
        }
        .sheet(isPresented: $model.showWizard) { PublishWizard(model: model) }
        .alert(tr("需要处理", "Needs attention"), isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button(tr("知道了", "OK")) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .onAppear { if let id = model.selectedServiceID { selectedID = id; model.selectedServiceID = nil } }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0), value: selectedID)
    }
}

struct SearchResults: View {
    let model: AppModel
    let query: String
    let chooseSection: (String) -> Void
    let chooseService: (UUID) -> Void
    func matches(_ text: String) -> Bool { text.localizedStandardContains(query) }
    var body: some View {
        List {
            Section(tr("服务", "Services")) {
                ForEach(model.orderedServices.filter { matches($0.name + $0.domains.joined()) }) { service in
                    Button { chooseService(service.id) } label: { Label(service.name, systemImage: "server.rack") }
                }
            }
            Section(tr("配置", "Configuration")) {
                ForEach(["/v1/credentials", "/v1/ddns-tasks", "/v1/proxy/routes"], id: \.self) { path in
                    ForEach(model.items(path).filter { matches($0["label"].string + $0["domains"].array.map(\.string).joined() + $0["ipv4"]["domains"].array.map(\.string).joined() + $0["ipv6"]["domains"].array.map(\.string).joined()) }, id: \.id) { item in
                        Button(item["label"].string.isEmpty ? item.id : item["label"].string) { chooseSection(path.contains("credentials") ? "credentials" : path.contains("ddns") ? "ddns" : "proxy") }
                    }
                }
            }
            Section(tr("页面与设置", "Pages & Settings")) {
                ForEach(NavigationSection.all.filter { matches($0.title + $0.en + $0.zh) }) { item in Button { chooseSection(item.id) } label: { Label(item.title, systemImage: item.symbol) } }
            }
        }.overlay {
            if model.services.isEmpty && NavigationSection.all.allSatisfy({ !matches($0.title + $0.en + $0.zh) }) && ["/v1/credentials", "/v1/ddns-tasks", "/v1/proxy/routes"].allSatisfy({ model.items($0).isEmpty }) { ContentUnavailableView.search(text: query) }
        }
    }
}

struct ServiceListView: View {
    @Bindable var model: AppModel
    @Binding var selectedID: UUID?
    @State private var importCandidate: JSONValue?
    var body: some View {
        HSplitView {
            VStack {
                if model.services.isEmpty {
                    ContentUnavailableView(tr("准备发布第一个服务", "Ready for your first service"), systemImage: "server.rack", description: Text(tr("选择域名、连接本地应用，再验证公网访问。", "Choose a domain, connect a local app, then verify public access.")))
                    Button(tr("发布服务", "Publish service")) { model.showWizard = true }.buttonStyle(.glassProminent).disabled(!model.running)
                }
                List(selection: $selectedID) {
                    ForEach(model.orderedServices) { service in
                        HStack(spacing: 10) {
                            Image(systemName: service.kind == .httpsForward ? "server.rack" : "globe").foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(service.name).font(.headline)
                                Text(service.domains.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                if let issue = model.serviceIssue(service) { Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                            }
                            Spacer()
                            if service.favorite { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
                        }.padding(.vertical, 5).tag(service.id)
                        .contextMenu {
                            Button(tr("收藏 / 取消收藏", "Toggle favorite")) { model.toggleFavorite(service.id) }
                            Button(tr("上移", "Move up")) { model.moveService(service.id, by: -1) }
                            Button(tr("下移", "Move down")) { model.moveService(service.id, by: 1) }
                        }
                    }
                    let unlinked = model.items("/v1/ddns-tasks").filter { task in !model.services.contains { $0.ddnsID == task.id } }
                    if !unlinked.isEmpty {
                        Section(tr("未关联的动态解析", "Unlinked DDNS tasks")) {
                            ForEach(unlinked, id: \.id) { task in
                                Button { importCandidate = task } label: { Label(task["label"].string, systemImage: "square.and.arrow.down") }
                            }
                        }
                    }
                }
            }.frame(minWidth: 250, idealWidth: 310, maxWidth: 430)
            if let service = model.services.first(where: { $0.id == selectedID }) {
                ServiceDetail(model: model, service: service).id(service.id)
            } else { ContentUnavailableView(tr("选择一个服务", "Select a service"), systemImage: "network", description: Text(tr("查看地址、配置关系和近期活动。", "Inspect its address, configuration and recent activity."))).frame(maxWidth: .infinity) }
        }
        .confirmationDialog(tr("将已有任务加入服务列表？", "Add this existing task to Services?"), isPresented: Binding(get: { importCandidate != nil }, set: { if !$0 { importCandidate = nil } }), titleVisibility: .visible) {
            Button(tr("加入服务", "Add service")) {
                if let task = importCandidate {
                    let domains = Set((task["ipv4"]["domains"].array + task["ipv6"]["domains"].array).map(\.string)).sorted()
                    model.addService(PublishedService(name: task["label"].string, kind: .dynamicDomain, domains: domains, ddnsID: task.id, order: model.services.count))
                }
                importCandidate = nil
            }
        } message: { Text(tr("这里只创建界面关联，不修改现有内核配置。", "This creates an interface association without changing the existing kernel configuration.")) }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage("appearance") private var appearance = "system"
    @State private var loginStatus = SMAppService.mainApp.status
    var body: some View {
        Form {
            Section(tr("应用", "Application")) {
                Picker(tr("外观", "Appearance"), selection: $appearance) {
                    Text(tr("跟随系统", "System")).tag("system"); Text(tr("浅色", "Light")).tag("light"); Text(tr("深色", "Dark")).tag("dark")
                }
                LabeledContent(tr("语言", "Language"), value: tr("跟随系统（简体中文 / English）", "System (English / Simplified Chinese)"))
                Toggle(tr("登录时启动 ISC", "Open ISC at login"), isOn: Binding(get: { loginStatus == .enabled }, set: { enabled in
                    do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginStatus = SMAppService.mainApp.status }
                    catch { model.errorMessage = error.localizedDescription }
                }))
                if loginStatus == .requiresApproval { Button(tr("打开系统登录项设置", "Open Login Items settings")) { SMAppService.openSystemSettingsLoginItems() } }
                Toggle(tr("允许严重异常系统通知", "Allow system notifications for serious errors"), isOn: Binding(get: { model.notificationsEnabled }, set: { value in if value { Task { await model.enableNotifications() } } else { model.notificationsEnabled = false } }))
            }
            Section(tr("内核", "Kernel")) {
                LabeledContent(tr("运行状态", "Status"), value: model.running ? tr("运行中", "Running") : tr("已停止", "Stopped"))
                LabeledContent(tr("数据位置", "Data location")) { Text(model.dataDirectory.path).textSelection(.enabled).font(.caption) }
                Text(tr("关闭管理窗口后，菜单栏与内核继续运行。选择“退出 ISC”会先停止内核，然后退出应用。", "Closing a management window keeps the menu bar and kernel running. Quit ISC stops the kernel before exiting the app.")).foregroundStyle(.secondary)
                HStack {
                    Button(model.running ? tr("停止内核", "Stop kernel") : tr("启动内核", "Start kernel")) { if model.running { model.execute { try await model.stop() } } else { Task { await model.start() } } }.disabled(model.phase == .starting || model.phase == .stopping)
                    Button(tr("打开数据文件夹", "Show data folder")) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: model.dataDirectory.path) }
                }
                Text(tr("此版本使用用户级内核库。机器级服务安装和提权需要额外组件，当前不会自动执行。", "This version uses a user-level kernel library. Machine-wide installation and elevation require additional components and are not performed automatically.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(tr("关于 ISC", "About ISC")) {
                LabeledContent(tr("最低系统", "Minimum system"), value: "macOS 27 · Apple Silicon")
                LabeledContent(tr("许可证", "License"), value: "GPLv3")
                LabeledContent(tr("内核版本", "Kernel version"), value: model.datasets["status"]?["meta"]["version"].string ?? "—")
            }
        }.formStyle(.grouped).preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
    }
}
