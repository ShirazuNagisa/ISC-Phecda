import SwiftUI
import AppKit
import ISCCore

@main struct ISCPhecdaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

/// 应用是"菜单栏常驻 + 一个管理窗口"。
///
/// 不用 WindowGroup：那样关掉窗口就等于退出，而内嵌内核应该继续跑着 ——
/// 用户的站点还在上面。窗口由 AppKit 持有，关闭它只是关掉界面。
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem?
    private var windows: [NSWindow] = []
    private var mayTerminate = false
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.menuBarImage()
        item.button?.target = self
        item.button?.action = #selector(openWindow)
        item.button?.toolTip = "ISC Phecda"
        statusItem = item
        Task { await model.start() }
        DispatchQueue.main.async { [weak self] in self?.openWindow() }
    }

    /// 菜单栏图标。
    ///
    /// # 三点必须做对，否则它在菜单栏里会「消失」
    ///
    /// 1. **`isTemplate = true`** —— 系统据此按菜单栏的明暗把图形渲染成
    ///    黑或白。原图是白色的，不设这一项的话在浅色菜单栏上就是**看不见**。
    ///    资源目录里 `template-rendering-intent` 已经声明过一次，这里再设
    ///    一次是因为从 `Assets.car` 取出来的 `NSImage` 不保证带上那个属性。
    /// 2. **尺寸固定 18pt** —— 菜单栏图标的标准高度；原图是 1772px 的方图，
    ///    不设尺寸会撑满整个菜单栏。
    /// 3. **取不到时回落到系统符号** —— 资源没编进包时宁可显示一个通用的
    ///    网络图标，也不要让菜单栏上出现一个空白区域（那样用户连点都点不到）。
    static func menuBarImage() -> NSImage {
        let fallback = NSImage(systemSymbolName: "network", accessibilityDescription: "ISC Phecda")
        guard let image = NSImage(named: "MenuBarIcon") else { return fallback ?? NSImage() }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    @objc func openWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "ISC Phecda"
        window.minSize = NSSize(width: 900, height: 580)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RootView(model: model))
        window.center()
        window.makeKeyAndOrderFront(nil)
        windows.removeAll { !$0.isVisible }
        windows.append(window)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 退出前把内核停干净。
    ///
    /// 直接退会让内核来不及停掉用户站点所依赖的反向代理与证书续期循环 ——
    /// 而"关掉界面"和"关掉服务"是两件不同的事，这里只做前者。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if mayTerminate { return .terminateNow }
        guard !quitting else { return .terminateLater }
        quitting = true
        Task {
            while model.phase == .starting || model.phase == .stopping {
                try? await Task.sleep(for: .milliseconds(100))
            }
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
