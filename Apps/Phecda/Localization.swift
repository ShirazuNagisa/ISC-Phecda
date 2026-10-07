import Foundation

/// 极简的双语取词。
///
/// 内核侧的文案由内核按请求语言本地化（它的消息目录是完整的）；界面自己的
/// 文案量很小，用这个函数就够了 —— 为几十条字符串引入一套本地化资源，
/// 换来的是一堆需要与代码同步维护的 .strings 文件。
/// 标 nonisolated：这个 target 默认把所有声明归到主 actor，而日志导出的
/// 错误文案与清单是在后台线程上拼出来的（见 LogExport）。取词只读
/// `Locale.preferredLanguages`，本来就没有任何需要隔离的状态。
nonisolated func tr(_ zh: String, _ en: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? zh : en
}

/// 内核请求使用的语言标签。
var kernelLanguage: String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-CN" : "en"
}

/// 数值格式化的一组小工具。
///
/// 整块标 nonisolated：它们都是纯函数（只做进制与单位换算，不碰任何共享
/// 状态），而主 actor 隔离会把这些格式化挡在后台线程之外 —— 日志导出在
/// 后台线程上拼文案，正好要用到 `formattedBytes`。
nonisolated extension Int {
    /// 把字节数写成人看的大小。
    ///
    /// 零要单独处理：`ByteCountFormatter` 对 0 返回的是 **"Zero KB"**，
    /// 而界面上写"共 Zero KB"既不像数字也不像人话。
    var formattedBytes: String {
        guard self != 0 else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .memory)
    }

    /// 把每秒字节数写成速率。
    var formattedRate: String {
        let value = Double(self)
        if value < 1024 { return String(format: "%.0f B/s", value) }
        if value < 1024 * 1024 { return String(format: "%.1f KB/s", value / 1024) }
        return String(format: "%.1f MB/s", value / 1024 / 1024)
    }
}

nonisolated extension Double {
    var formattedRate: String { Int(self).formattedRate }
    var formattedPercent: String { String(format: "%.0f%%", self) }
}

nonisolated extension Int64 {
    /// 把秒数写成人看 uptime。
    var formattedDuration: String {
        let seconds = Int(self)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
        return "\(seconds / 86400)d \((seconds % 86400) / 3600)h"
    }
}
