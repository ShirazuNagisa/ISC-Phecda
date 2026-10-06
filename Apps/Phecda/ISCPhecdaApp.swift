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
///
/// # 菜单栏点击弹面板，不是开窗口
///
/// 早先图标绑的是 `openWindow`，于是**点一次开一个**，窗口越堆越多。
/// 现在点图标弹一个 transient 面板（简略信息台），主窗口只能从面板里
/// 打开，且全局只有一个实例 —— 重复打开是把它前置，不是再开一个。
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    /// 主窗口。单例：重复打开只前置，不新建。
    private var mainWindow: NSWindow?

    /// 上一次面板因"点到外面"而关闭的时刻。
    ///
    /// # 为什么需要它
    ///
    /// `.transient` 面板在点击状态栏图标时会先被系统判为"点到了外部"而
    /// 关闭，紧接着按钮的 action 又把它打开 —— 表现是图标**点不灭**：
    /// 刚关掉又弹出来。记下关闭时刻，让紧随其后的那次点击只当"关闭"。
    private var popoverClosedAt: Date?

    private var mayTerminate = false
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.menuBarImage()
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.toolTip = "ISC Phecda"
        statusItem = item
        Task { await model.start() }
        // 刻意**不**在这里开主窗口：菜单栏常驻应用一启动就弹窗是很打扰的，
        // 而且内核在后台跑着并不需要用户看着。用户点图标就能看到状态。
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
        // 资源目录是**应用 target** 的资源，编译进主 bundle 的 Assets.car。
        //
        // 早先它挂在 SwiftPM 的 ISCApp target 上，那时要写 Bundle.module；
        // 改成工程产出应用之后那个访问器不存在了，而症状是编译期直接报
        // "type 'Bundle' has no member 'module'" —— 这一条属于会自己暴露的，
        // 比"图标静默变通用"那类好得多。
        let image = NSImage(named: "MenuBarIcon")
        guard let image else { return fallback ?? NSImage() }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    /// 点击菜单栏图标：开或关那个简略信息台。
    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        // 刚刚才因为"点到外面"关掉的那一次点击，只当作关闭 ——
        // 否则面板会关掉又立刻弹回来，看起来像点不灭。
        if let closedAt = popoverClosedAt, Date().timeIntervalSince(closedAt) < 0.2 {
            popoverClosedAt = nil
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPanelView(
                model: model,
                openMainWindow: { [weak self] in
                    self?.popover?.performClose(nil)
                    self?.openMainWindow()
                },
                quit: { NSApp.terminate(nil) }
            )
        )
        popover.delegate = self
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 记下关闭时刻，供 togglePopover 识别"这一下点击只是关掉面板"。
    func popoverDidClose(_ notification: Notification) {
        popoverClosedAt = Date()
        popover = nil
    }

    /// 打开主窗口。已经有一个就把它前置，**不新建**。
    ///
    /// 这一条就是"不许多开窗口"的全部实现：窗口由自己持有，而不是每次
    /// 点击都造一个新的。早先每次 new 一个 NSWindow，用户点几次就有几个。
    @objc func openMainWindow() {
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "ISC Phecda"
        window.minSize = NSSize(width: 900, height: 580)
        window.titlebarAppearsTransparent = true
        // 关掉窗口不等于销毁它：内核还在跑，用户再打开时应当看到同一个
        // 界面（连同滚动位置与选中项），而不是一个刚初始化的新窗口。
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RootView(model: model))
        window.center()
        window.makeKeyAndOrderFront(nil)
        mainWindow = window
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
