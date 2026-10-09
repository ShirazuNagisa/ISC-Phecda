import Foundation

/// 一次性运行模式：每次启动都像刚刚安装好的应用。
///
/// # 它解决什么
///
/// 产品里最难复验的，恰恰是那些**只在第一次**发生的事：首次引导弹不弹、
/// 一个服务商都没有时每一页长什么样、数据目录要不要迁移、日志目录还不存在
/// 时导出怎么报错。反复验证它们需要每次都从零开始，而手工去删数据目录与
/// 偏好既慢又危险 —— 那两处同时也是真实安装正在用的数据。
///
/// # 判断依据
///
/// 环境变量 `ISC_PHECDA_FRESH=1`。环境变量**只能**由启动方在进程启动时
/// 设置，与 `ISC_PHECDA_SECTION`（见 `AppModel.section`）是同一套口径：
/// 它不是一个可以被外部利用的入口。入口脚本见 `Scripts/fresh-run.sh`。
///
/// # 它让三件事不再落到真实安装上
///
///   1. **数据目录**换成 `$TMPDIR` 下的临时目录，本次运行独有，正常退出时
///      删掉。内核的数据库、站点日志、ACME 账户、远程面自签证书全都落在
///      那里面（见 ISC-Core 的 `internal/paths`）。
///   2. **密钥后端切成文件**（`ISC_SECRET_STORE=file`），临时数据目录各自一把
///      主密钥。不做这一步的话，临时数据目录会各自算出一个新的条目名，于是
///      每验证一次就往用户的登录钥匙串里多写一条 `isc-core` 记录 —— 而验证
///      本来只是一次性的。内核支持这个开关正是为了这种场合
///      （见 `platform.EnvSecretStore`）。**这一条由启动方设置**，理由见下。
///   3. **偏好只留在内存里**（见 `Preferences`）。首次引导"已关掉"的标记、
///      程序坞图标的选择都不落盘，下一次启动又是全新的一份。
///
/// 真实安装的 `~/Library/Application Support/Phecda`、偏好 plist、钥匙串条目
/// 一个都不会被读写 —— 这是它相对"先删掉再跑"的根本区别：验证不该拿真实
/// 数据当代价。
///
/// # 第 2 条为什么必须由**启动方**提供
///
/// 这里不能用 `setenv` 把它设上。内核是同一个进程里的 Go 运行时（libisc），
/// 而 Go 在库被装载时就把 `environ` 复制走了 —— 之后再 `setenv`，`os.Getenv`
/// 看不见（内核那边为此专门改成"自己推导内置运行时目录"，见 ISC-Core 的
/// `f1de9b5`）。实测：应用里 `setenv` 之后内核照样报
/// `已生成新的主密钥 backend=macos-keychain`。
///
/// 所以 `Scripts/fresh-run.sh` 把它**放进启动环境**（那才是 Go 看得见的位置），
/// 而这里只负责在拿不到时**说清楚**：见 `prepareIfNeeded` 里的那句告警。
/// 静默降级成"每次多一条钥匙串记录"是最糟的选项 —— 用户以为自己在做一次性
/// 验证，实际在往真实钥匙串里攒东西。
enum FreshRun {
    /// 打开这个模式的环境变量。
    static let environmentKey = "ISC_PHECDA_FRESH"

    /// 内核自己的数据目录环境变量（ISC-Core 的 `paths.EnvDataDir`）。
    ///
    /// 这一个 `setenv` 是**有效**的，因为读它的是界面自己（见 `AppModel.init`），
    /// 不是 Go 那一侧。内核拿到的数据目录是界面显式传进 `isc_start` 的。
    static let dataDirectoryKey = "ISC_DATA_DIR"

    /// 内核自己的密钥后端环境变量（ISC-Core 的 `platform.EnvSecretStore`）。
    /// 取值只有 `file` 一个。
    static let secretStoreKey = "ISC_SECRET_STORE"

    /// 这个模式开着没有。
    static var isEnabled: Bool { ProcessInfo.processInfo.environment[environmentKey] == "1" }

    /// 本次运行的数据目录；没有启用时是 nil。
    private(set) static var dataDirectory: URL?

    /// 建临时数据目录并把环境变量摆好。
    ///
    /// **必须在任何人读数据目录之前调用**，也就是 `AppModel.init` 的第一件事。
    /// 幂等：重复调用不会建出第二个目录。
    ///
    /// 名字刻意短：内核的本地管理通道是 `<数据目录>/run/isc.sock`，而
    /// `sun_path` 只有 104 字节。`/var/folders/…/T/isc-fresh-xxxxxxxx` 之后
    /// 仍然留有余量（见 AppModel.init 里关于目录名长度的那段）。
    static func prepareIfNeeded() {
        guard isEnabled, dataDirectory == nil else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("isc-fresh-\(UUID().uuidString.prefix(8).lowercased())",
                                    isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            // 建不出来就**不要**假装成功：继续按真实数据目录跑，会让用户
            // 以为自己在测全新安装，而实际上动的是他的真实数据。
            NSLog("ISC Phecda fresh run: 无法创建临时数据目录 %@：%@", directory.path,
                  error.localizedDescription)
            return
        }
        // 让界面自己看到数据目录（`AppModel.init` 读的就是这个名字）。
        setenv(dataDirectoryKey, directory.path, 1)
        dataDirectory = directory
        NSLog("ISC Phecda fresh run: 数据目录 %@（退出时删除）", directory.path)

        // 密钥后端这一条**不是**这里设的（设了也没用，见类型注释）。拿不到时
        // 如实说清楚代价，而不是让用户以为钥匙串没被动过。
        if ProcessInfo.processInfo.environment[secretStoreKey]?.lowercased() != "file" {
            NSLog("""
                ISC Phecda fresh run: 没有拿到 %@=file，这一次的主密钥会写进登录钥匙串（isc-core 下多一条 master@…），\
                临时数据目录删掉之后那条记录就没人用了。用 Scripts/fresh-run.sh 启动就不会这样。
                """, secretStoreKey)
        }
    }

    /// 内核停干净之后删掉这一次运行留下的东西。
    ///
    /// 删不掉的常见原因是此刻还有别的东西在读它（例如终端里正看着某份日志）。
    /// 那种情况下往日志里留一句就好 —— 为一次清理失败让退出流程报错，
    /// 是把代价放错了地方。
    static func cleanUp() {
        guard let directory = dataDirectory else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            NSLog("ISC Phecda fresh run: 临时数据目录没删掉 %@：%@", directory.path,
                  error.localizedDescription)
        }
        dataDirectory = nil
    }
}
