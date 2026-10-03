import SwiftUI
import AppKit
import ServiceManagement
import ISCCore

@main struct ISCApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { Settings { SettingsView(model: delegate.model) } }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var windows: [NSWindow] = []
    private var pinned = false
    private var quitting = false
    private var mayTerminate = false
    private var monitor: Any?
    private var modelObservation: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "network", accessibilityDescription: "ISC")
        item.button?.target = self; item.button?.action = #selector(togglePopover)
        item.button?.toolTip = "ISC"
        statusItem = item
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 540)
        popover.contentViewController = NSHostingController(rootView: MenuPanel(model: model, openWindow: { [weak self] in self?.openWindow() }, togglePin: { [weak self] in self?.togglePin() }, isPinned: { [weak self] in self?.pinned ?? false }))
        modelObservation = Task {
            for await state in Observations({ (self.model.running, self.model.services.contains { self.model.serviceIssue($0) != nil }) }) {
                self.statusItem?.button?.image = NSImage(systemSymbolName: state.1 ? "network.badge.shield.half.filled" : "network", accessibilityDescription: "ISC")
                self.statusItem?.button?.toolTip = state.0 ? tr("ISC · 内核运行中", "ISC · Kernel running") : tr("ISC · 内核未运行", "ISC · Kernel stopped")
            }
        }
        Task { await model.start() }
        // Xcode 调试和首次启动都直接展示管理窗口；关闭窗口只回到菜单栏，不退出应用。
        openWindow()
    }
    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }
    private func togglePin() {
        pinned.toggle()
        popover.behavior = pinned ? .applicationDefined : .transient
        popover.contentViewController = NSHostingController(rootView: MenuPanel(model: model, openWindow: { [weak self] in self?.openWindow() }, togglePin: { [weak self] in self?.togglePin() }, isPinned: { [weak self] in self?.pinned ?? false }))
    }
    func openWindow() {
        popover.performClose(nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "ISC"
        window.minSize = NSSize(width: 860, height: 600)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: MainView(model: model, newWindow: { [weak self] in self?.openWindow() }))
        window.center(); window.makeKeyAndOrderFront(nil)
        windows.removeAll { !$0.isVisible }; windows.append(window)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if mayTerminate { return .terminateNow }
        guard !quitting else { return .terminateLater }
        quitting = true
        Task {
            while model.phase == .starting || model.phase == .stopping { try? await Task.sleep(for: .milliseconds(100)) }
            do {
                try await model.stop()
                mayTerminate = true
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                quitting = false
                sender.reply(toApplicationShouldTerminate: false)
                let alert = NSAlert()
                alert.messageText = tr("无法安全停止内核", "Could not stop the kernel safely")
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: tr("重试", "Retry"))
                alert.addButton(withTitle: tr("取消退出", "Cancel quit"))
                if alert.runModal() == .alertFirstButtonReturn { sender.terminate(nil) }
            }
        }
        return .terminateLater
    }
}

struct MenuPanel: View {
    @Bindable var model: AppModel
    let openWindow: () -> Void
    let togglePin: () -> Void
    let isPinned: () -> Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "network").font(.title2).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("ISC").font(.headline)
                    Text(model.running ? tr("内核运行中", "Kernel running") : tr("内核未运行", "Kernel stopped")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: togglePin) { Image(systemName: isPinned() ? "pin.fill" : "pin") }.help(tr("固定面板", "Pin panel"))
                Button { NSApp.keyWindow?.close() } label: { Image(systemName: "xmark") }.help(tr("关闭面板", "Close panel"))
            }.buttonStyle(.borderless).padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let message = model.errorMessage { Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                    if model.services.isEmpty {
                        ContentUnavailableView(tr("发布你的第一个服务", "Publish your first service"), systemImage: "network", description: Text(tr("让家中的应用拥有可访问的域名。", "Give your home application a reachable domain.")))
                        Button(tr("开始配置", "Get started")) { model.showWizard = true; openWindow() }.buttonStyle(.glassProminent)
                    } else {
                        Text(tr("发布的服务", "Published services")).font(.caption).foregroundStyle(.secondary)
                        ForEach(model.orderedServices, id: \.id) { service in
                            Button {
                                model.selectedServiceID = service.id; openWindow()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: service.kind == .httpsForward ? "server.rack" : "globe").foregroundStyle(.blue)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(service.name).font(.headline).lineLimit(1)
                                        Text(service.domains.first ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        Text(model.serviceIssue(service) ?? tr("尚未验证公网访问", "Public access not yet verified")).font(.caption2).foregroundStyle(model.serviceIssue(service) == nil ? Color.secondary : Color.orange)
                                    }
                                    Spacer()
                                    if service.favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).glassEffect(.regular, in: .rect(cornerRadius: 14))
                            }.buttonStyle(.plain)
                        }
                    }
                    Divider()
                    HStack {
                        Text(tr("动态解析", "Dynamic DNS")).font(.subheadline.bold())
                        Spacer()
                        if model.running { Button(tr("立即更新", "Update now")) { model.execute { for task in model.items("/v1/ddns-tasks") { _ = try await model.request("POST", "/v1/ddns-tasks/\(KernelClient.pathComponent(task.id))/run") } } }.buttonStyle(.borderless) }
                    }
                    let latest = model.items("/v1/ddns-tasks").compactMap { $0["last_run_at"].string.isEmpty ? nil : $0["last_run_at"].string }.sorted().last
                    Text(latest ?? tr("尚无执行记录", "No updates yet")).font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }
            Divider()
            HStack {
                Button(tr("管理…", "Manage…"), action: openWindow).buttonStyle(.glass)
                Spacer()
                if model.phase == .starting || model.phase == .stopping { ProgressView().controlSize(.small) }
                else { Button(model.running ? tr("停止内核", "Stop kernel") : tr("启动内核", "Start kernel")) { if model.running { model.execute { try await model.stop() } } else { Task { await model.start() } } }.buttonStyle(.borderless) }
                Menu { Button(tr("退出 ISC", "Quit ISC"), role: .destructive) { NSApp.terminate(nil) } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 20)
            }.padding(16)
        }.frame(width: 380, height: 540)
    }
}
