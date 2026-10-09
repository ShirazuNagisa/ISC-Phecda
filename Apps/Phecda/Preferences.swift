import AppKit
import Foundation

/// 应用自己的偏好。
///
/// # 为什么不放进内核设置
///
/// 内核管的是站点、DNS、证书这些**跨客户端**的事实：手机上的 Mizar 看到的
/// 必须是同一份。而"程序坞里要不要显示图标""首次引导关掉没有"只关乎本机
/// 这一个进程怎么呈现，别的客户端既看不到也不该看到。因此它们跟首次引导的
/// 标记一样存在 `UserDefaults` 里，而不是塞进 `KernelSettings`。
///
/// # 为什么要包一层
///
/// 一次性运行模式（`FreshRun`）要求"每次启动都像刚刚安装"，而 `UserDefaults`
/// 是落盘的 —— 那个模式下读写必须只落在内存里。把这个判断收在一处，调用点
/// 就不必各自记得它，也就不会有"某个新加的偏好悄悄漏进真实 plist"这种事。
enum Preferences {
    /// 一次性运行模式下的内存副本。只在 `FreshRun.isEnabled` 时被使用。
    private static var memory: [String: Bool] = [:]

    static func bool(_ key: String, default fallback: Bool = false) -> Bool {
        if FreshRun.isEnabled { return memory[key] ?? fallback }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func set(_ key: String, _ value: Bool) {
        if FreshRun.isEnabled {
            memory[key] = value
            return
        }
        UserDefaults.standard.set(value, forKey: key)
    }

    static func remove(_ key: String) {
        if FreshRun.isEnabled {
            memory[key] = nil
            return
        }
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// 「在程序坞里显示应用图标」这件事。
///
/// # 默认是显示
///
/// 应用在 `LSUIElement` 里不再是代理（agent）：启动之后它就是一个**普通
/// 应用** —— 程序坞里有图标，能进 Cmd-Tab，也有自己的菜单栏。菜单栏图标
/// 仍然照旧常驻：它是这个应用的常驻入口，与程序坞图标是两回事。
///
/// 不想在程序坞里看到它的人可以在这里关掉，而**关掉之后依然够得着**：
/// 菜单栏图标一直在，简略信息台里的「打开主窗口」与「退出」是完整的出口。
/// 这一条是这个开关能存在的前提 —— 一个把用户关在门外的开关不该有。
///
/// # 为什么可以随时切、不用重启
///
/// `NSApplication.setActivationPolicy` 就是"这个进程要不要出现在程序坞"
/// 那个开关本身。偏好只是它的持久化形态，改完立刻落到 `NSApp` 上。
enum DockIconPreference {
    /// `UserDefaults` 键。语义是**取反**的（`true` = 不显示）：
    /// 键名与界面上的开关一致，读代码时不用在脑子里做一次翻转。
    static let key = "ISC.Phecda.hideDockIcon"

    /// 用户是不是选择了不显示图标。
    static var isHidden: Bool { Preferences.bool(key) }

    /// 改这个偏好，并立刻落到当前进程上。
    static func setHidden(_ hidden: Bool) {
        Preferences.set(key, hidden)
        apply()
    }

    /// 把偏好变成实际的激活策略。
    ///
    /// `.regular`  = 普通应用：程序坞图标 + Cmd-Tab + 菜单栏。
    /// `.accessory` = 只有菜单栏图标的代理应用，程序坞里没有它。
    ///
    /// 启动时在 `applicationWillFinishLaunching` 里调用：那是系统第一次
    /// 绘制程序坞之前最近的一处可干预点。仍可能有极短的一帧图标闪过
    /// （`LSUIElement` 是**静态**的 Info.plist 键，进程起来之后才改得动），
    /// 但把选择放在这里，闪的那一下是"图标先出现再消失"，而不是"先空一块
    /// 再补上"—— 后者在默认状态下（显示图标）反而更常见。
    static func apply() {
        NSApplication.shared.setActivationPolicy(isHidden ? .accessory : .regular)
    }
}

/// 「最小化启动 Phecda」：启动时要不要把主界面推出来。
///
/// # 默认是**打开**主界面
///
/// 这个默认在 v0.4.4 翻过一次，理由值得写下来，免得下一个人又翻回去：
///
///   - 一个应用被双击之后什么都不发生，是最容易被当成"它坏了"的形态。
///     首次安装尤其如此 —— 用户装完，启动，看到菜单栏多了一个图标，
///     而首次引导向导（它在主窗口里）根本没露面。
///   - 内核在同一个进程里，但**界面开着不等于内核才在跑**：关掉窗口只是
///     关掉界面（`applicationShouldTerminateAfterLastWindowClosed` 是 false）。
///     所以"弹窗"并不会让站点受任何影响。
///   - 真正需要"开机即静默"的人（把它当常驻服务、由登录项拉起）会主动
///     打开这个开关 —— 那是他的场景，不该由所有人替他默认。
///
/// # 它只管**自动**弹窗
///
/// 点程序坞图标（或 Finder 里再次打开应用）永远会打开主界面，与这个开关
/// 无关：那一次点击就是用户明确要求看界面。开关只决定"启动之后要不要自己
/// 冒出来" —— 见 `AppDelegate.applicationShouldHandleReopen`。
enum LaunchPreference {
    /// `UserDefaults` 键。与界面上的开关同向（`true` = 最小化启动）。
    static let key = "ISC.Phecda.startMinimized"

    /// 启动时是不是只留菜单栏图标（不弹主窗口）。
    static var startMinimized: Bool { Preferences.bool(key) }

    static func setStartMinimized(_ minimized: Bool) {
        Preferences.set(key, minimized)
    }
}
