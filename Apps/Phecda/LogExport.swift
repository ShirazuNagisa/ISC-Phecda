import Foundation

/// 把 Phecda 的全部日志集中打包成一个 zip。
///
/// # 为什么日志是"多处"的
///
/// 内核与界面在**同一个进程**里，但两者写日志的方式不同：
///
///   - 内核的结构化日志（`log/slog`）走 stderr，由 launchd 收进统一日志，
///     数据目录里没有对应的文件；它落盘的只有**站点进程的输出**，
///     在 `<数据目录>/logs/apps/<站点 ID>.log`（超过 4 MB 轮转成 `.log.1`）。
///   - 界面自己只在迁移数据目录失败时 `NSLog` 一句，同样没有日志文件。
///
/// 因此"导出日志"能拿到的就是文件形态的那几份。与其只导出一个目录、
/// 让用户以为拿到了全部，不如**如实报告**收集到哪些目录、跳过了哪些 ——
/// 这份清单会一起写进 zip，读日志的人（和用户自己）才知道缺了什么。
///
/// # 为什么用 `zip` 而不是 `ditto`
///
/// 两者都是系统自带、都能不经 shell 以 argv 逐项传参。选 `zip` 的理由：
///
///   - `zip` 的参数就是"要打包的路径 + 目标文件"，语义与这里要做的
///     "把这几棵目录树塞进一个 zip"完全一致；`ditto` 是目录**复制**工具，
///     zip 只是它的一个输出格式，为了去掉 macOS 的 `__MACOSX/` 元数据
///     还要额外关掉资源分叉、扩展属性、配额、ACL 四项。
///   - `zip -X` 一条就把那些元数据排除了，打出来的归档在任何平台上
///     解开都是一样的东西。
///   - 递归压缩是它的本职，日志（纯文本）的压缩比很好。
///
/// 调用方式上有一处细节：直接传绝对路径的话，`zip` 会把前导 `/` 去掉后
/// 整条路径当作条目名（`Users/xxx/Library/...`）—— 解开要先进五层无关
/// 目录。因此这里把**工作目录**设成临时搭出来的归档根，再用 argv 传相对
/// 路径，条目名就是 `logs/apps/xxx.log` 这样可读的样子。argv 逐项传递也
/// 意味着路径里的空格、`$`、引号都不需要转义，更不会被 shell 解释。
///
/// # 为什么先摆一层符号链接
///
/// 来源分散在不同的树里（数据目录、`~/Library/Logs`），想找一个公共父
/// 目录会一路退到 `/`，相对路径随之变成 `Users/...` 的长串。因此先在
/// 临时目录里按**来源名**摆一层符号链接，把 `zip` 的根钉在那里：
/// 条目名干净，而来源目录本身保持原样不动（zip 只读，不会写进去）。
///
/// 顺带一个好处：摆链接这一步把"某个来源在枚举之后、打包之前消失了"
/// 变成一件安全的事 —— 少一个条目，而不是整个打包失败。
///
/// # 为什么整块标 nonisolated
///
/// 这个 target 用 `-default-isolation=MainActor` 编译（见 pbxproj 的
/// OTHER_SWIFT_FLAGS），也就是**默认所有声明都归主 actor**。这里的每一件
/// 事 —— 枚举目录、统计字节、起 `zip` 子进程 —— 都是纯文件系统操作，
/// 放在主 actor 上会让界面在打包几百 MB 日志时卡住。显式标 nonisolated
/// 是把它们挪到后台线程的**前提**：`Task.detached` 里根本调不到
/// 主 actor 隔离的方法。
nonisolated enum LogExport {

    /// 一份日志来源：一个目录，或者一个单独的文件。
    struct Source: Sendable {
        /// 用户在界面上看到的名字，同时也是 zip 里的顶层条目名。
        let name: String
        let url: URL
        let isDirectory: Bool
    }

    /// 一次扫描的结果。
    ///
    /// `files` 在这里就展开成扁平数组：界面要显示"共几个文件、多大"，
    /// 打包时要判断"扫描之后这个文件还在不在"，两件事都需要逐项，
    /// 而不是只要一个总数。
    struct Report: Sendable {
        struct File: Sendable {
            let url: URL
            /// 相对归档根的条目名，例如 `logs/apps/xxx.log`。
            let entry: String
            let bytes: Int64
        }

        struct Totals: Sendable {
            var files = 0
            var bytes: Int64 = 0
            var directories = 0
        }

        /// 建了归档的目录（含文件，它们是目录的成员）。
        var directories: [Source] = []
        /// 单独收进来的文件（数据目录里的 `isc.yaml`）。
        var standaloneFiles: [Source] = []
        /// 实际收进归档的每个文件。
        var files: [File] = []
        /// 看了但跳过的位置，附一句原因。
        var skipped: [(path: String, reason: String)] = []
        var totals = Totals()

        /// 把这次导出的来龙去脉写成一份说明，塞进 zip 里。
        ///
        /// 它存在的理由是那些**没被收进来**的东西：内核的 slog 只写 stderr，
        /// 统一日志里有但数据目录里没有。只给一个装满站点日志的 zip，
        /// 读的人会以为"日志就这些"。
        var manifest: String {
            var lines: [String] = []
            lines.append("ISC Phecda 日志导出")
            lines.append("导出时间：\(ISO8601DateFormatter().string(from: Date()))")
            lines.append("")
            lines.append("已收集（\(totals.files) 个文件，\(totals.bytes) 字节）：")
            if directories.isEmpty && standaloneFiles.isEmpty {
                lines.append("  （无）")
            }
            for source in directories {
                lines.append("  [目录] \(source.name) → \(source.url.path)")
            }
            for source in standaloneFiles {
                lines.append("  [文件] \(source.name) → \(source.url.path)")
            }
            if !skipped.isEmpty {
                lines.append("")
                lines.append("已跳过：")
                for item in skipped {
                    lines.append("  \(item.path)（\(item.reason)）")
                }
            }
            lines.append("")
            lines.append("说明：")
            // 这一段是给"拿到 zip 却找不到想要的那条日志"的人看的。
            lines.append("  - 站点进程的输出在 logs/apps/ 下，按站点 ID 命名，超过 4 MB 轮转为 .log.1。")
            lines.append("  - 内核自身的结构化日志写入标准错误，由系统的统一日志收集，不在数据目录里。")
            lines.append("    需要时可在「终端」执行：log show --predicate 'process == \"ISC Phecda\"' --last 1h")
            return lines.joined(separator: "\n")
        }
    }

    /// 打包用的工具。系统自带，不引入任何依赖。
    private static let zipTool = "/usr/bin/zip"

    // MARK: 扫描

    /// 列出所有日志来源并统计大小。
    ///
    /// 整个扫描是同步的文件系统操作（日志可能有几十 MB），因此整体扔到
    /// 后台线程上 —— 在界面线程上枚举几万个文件会把窗口卡住，而这本来
    /// 就是用户点"导出"之后才会发生的事。
    static func prepare(dataDirectory: URL) async -> Report {
        await Task.detached(priority: .utility) { collect(dataDirectory: dataDirectory) }.value
    }

    /// 把已经扫描好的内容打成 zip 写到 `destination`。
    ///
    /// 重新扫一遍（而不是复用界面手里那份报告）：用户可能在按下按钮之前
    /// 让应用跑了一会儿，多出来的日志正好是最想看的那一段。
    ///
    /// 返回归档**实际写出来的大小**，而不是报告里那个"原始字节数"：
    /// 日志是纯文本，压缩后通常小一个数量级，用前者报数字是错的。
    static func export(to destination: URL, dataDirectory: URL) async throws -> (report: Report, archiveBytes: Int64) {
        try await Task.detached(priority: .utility) {
            try write(destination: destination, dataDirectory: dataDirectory)
        }.value
    }

    /// 给保存面板用的默认文件名，带日期，方便区分几次导出。
    static var suggestedFileName: String {
        let formatter = DateFormatter()
        // 固定 en_US_POSIX：文件名不该随系统语言变，否则同一台机器换语言后
        // 两次导出的名字格式对不上。
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        // 空格在这里是安全的：文件名以 argv 逐项传给 zip，不经过 shell。
        return "ISC Phecda logs \(formatter.string(from: Date())).zip"
    }

    // MARK: 收集范围

    /// 计算要收集哪些位置。
    ///
    /// 顺序即优先级。找不到的位置不是错误 —— 用户可能从没让内核跑起来，
    /// 数据目录里自然没有 logs/ —— 所以它们只是被跳过并记一笔。
    private static func sources(dataDirectory: URL) -> [Source] {
        var result: [Source] = [
            // 站点进程的输出，以及将来内核若改为落盘日志时最可能的位置。
            Source(name: "logs", url: dataDirectory.appending(path: "logs", directoryHint: .isDirectory),
                   isDirectory: true),
            // 内核的配置（隐私已由内核脱敏）。它解释"这台机器上内核是怎么配的"，
            // 缺了它很多日志没法读。数据目录里只有这一个文件值得带。
            Source(name: "isc.yaml", url: dataDirectory.appending(path: "isc.yaml", directoryHint: .notDirectory),
                   isDirectory: false),
        ]
        if let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            // 约定俗成的用户级日志位置。界面目前不往这里写，但把它列上：
            // 将来写了就会自动进归档，而现在它只是被跳过一次。
            result.append(Source(name: "app-logs", url: library.appending(path: "Logs/Phecda", directoryHint: .isDirectory),
                                 isDirectory: true))
        }
        // 刻意**不**去找 0.1.x 的旧数据目录（`Application Support/ISC`）：
        // 那是内核自己的安装，不属于这个应用（沙箱下这个路径还会落进容器，
        // 指向一个与真实安装无关的空目录）。把一个读不到的位置列进清单，
        // 只会让"收集到了什么"这件事变得不可信。
        return result
    }

    /// 逐项收集。同步实现，由 `prepare` / `export` 放到后台线程执行。
    private static func collect(dataDirectory: URL) -> Report {
        var report = Report()
        var usedEntries = Set<String>()

        for source in sources(dataDirectory: dataDirectory) {
            // `fileExists` 对悬空符号链接返回 false，正合此意。
            guard FileManager.default.fileExists(atPath: source.url.path) else {
                report.skipped.append((source.url.path, "不存在"))
                continue
            }
            // 来源名要唯一：它同时是 zip 的条目名，重名会让两棵树叠在一起。
            guard usedEntries.insert(source.name).inserted else {
                report.skipped.append((source.url.path, "与前一个来源重名"))
                continue
            }
            if source.isDirectory {
                collectDirectory(source, report: &report)
            } else {
                collectFile(source, report: &report)
            }
        }
        return report
    }

    private static func collectDirectory(_ source: Source, report: inout Report) {
        report.directories.append(source)
        report.totals.directories += 1
        for file in files(in: source.url) {
            // 条目名在这里才拼上来源名：`files` 只管相对自己的路径，
            // 来源名由这份清单决定，两件事不该混在一起算。
            report.files.append(Report.File(url: file.url, entry: source.name + "/" + file.entry, bytes: file.bytes))
            report.totals.files += 1
            report.totals.bytes += file.bytes
        }
    }

    private static func collectFile(_ source: Source, report: inout Report) {
        let size = (try? source.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        report.standaloneFiles.append(source)
        report.files.append(Report.File(url: source.url, entry: source.name, bytes: Int64(size)))
        report.totals.files += 1
        report.totals.bytes += Int64(size)
    }
    /// 递归列出一个目录下的所有普通文件，返回相对该目录的条目名。
    ///
    /// 两个开关都必要：跳过隐藏文件（`.DS_Store` 之类的噪音）、跳过包
    /// （日志目录里出现 `.app` 只会是意外）。**符号链接不在这里排除**
    /// （枚举器本来也不跟随），而是逐个用 `isSymbolicLink` 复查一遍 ——
    /// 否则一个指向上层的链接就能让枚举无限递归。
    private static func files(in root: URL) -> [(url: URL, entry: String, bytes: Int64)] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var result: [(url: URL, entry: String, bytes: Int64)] = []
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            // 目录不在这里产出；枚举器会自己走进去。
            //
            // 相对路径按**父目录前缀截断**算，两边都先 `resolvingSymlinksInPath`：
            // `/var`、`/tmp` 都是符号链接（指向 `/private/...`），而枚举器
            // 返回的是解析后的名字。不统一的话前缀对不上，条目名会退化成
            // 光秃秃的文件名 —— 看起来正常，但子目录 `apps/` 就这么没了。
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
            let rootPath = root.resolvingSymlinksInPath().path
            let suffix = parent.hasPrefix(rootPath) ? String(parent.dropFirst(rootPath.count)) : ""
            let relative = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let entry = relative.isEmpty ? url.lastPathComponent : relative + "/" + url.lastPathComponent
            result.append((url, entry, Int64(values.fileSize ?? 0)))
        }
        return result.sorted { $0.entry < $1.entry }
    }

    // MARK: 打包

    private static func write(destination: URL, dataDirectory: URL) throws -> (report: Report, archiveBytes: Int64) {
        let report = collect(dataDirectory: dataDirectory)
        guard !report.files.isEmpty else { throw LogExportError.noLogs }

        let fm = FileManager.default
        // 先写到临时目录再搬过去：保存面板给的位置可能在中途不可写（外置盘
        // 被拔、iCloud 目录还没物化），而半截 zip 比没有 zip 更难解释。
        let staging = fm.temporaryDirectory.appending(path: "phecda-log-export-\(UUID().uuidString)",
                                                      directoryHint: .isDirectory)
        let archive = staging.appending(path: "logs.zip", directoryHint: .notDirectory)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let roots = try stage(report: report, in: staging)
        guard !roots.isEmpty else { throw LogExportError.noLogs }

        // 没有 -y：符号链接本身不是要存的内容，zip 要顺着链接把**真实文件**
        // 读进来（它只读不写，来源目录不会被碰）。
        var arguments = ["-q", "-r", "-X", archive.path]
        arguments.append(contentsOf: roots)

        let outcome = run(zipTool, arguments, workingDirectory: staging)
        // zip 把"某个输入不存在"也报成失败（Nothing to do），而这里已经
        // 逐个检查过存在性，所以退出码非 0 就是真的没打成。
        guard outcome.status == 0 else {
            throw LogExportError.archiveFailed(detail: outcome.message)
        }
        guard fm.fileExists(atPath: archive.path),
              let size = try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            throw LogExportError.archiveFailed(detail: tr("打包程序没有产出文件。", "The archiver produced no file."))
        }

        do {
            try move(archive, to: destination)
        } catch {
            throw LogExportError.saveFailed(path: destination.path, detail: error.localizedDescription)
        }
        return (report, Int64(size))
    }

    /// 在临时目录里按来源名摆一层符号链接，返回传给 zip 的相对路径。
    ///
    /// 链接名用来源的**最后一段**：`app-logs`、`logs` 都是单段，摆出来就是
    /// `<staging>/logs → <数据目录>/logs`。名字与来源在清单里显示的一致，
    /// 解开归档看到什么，清单上就写着什么。
    private static func stage(report: Report, in staging: URL) throws -> [String] {
        let fm = FileManager.default
        var roots: [String] = []
        var used = Set<String>()
        for source in report.directories + report.standaloneFiles {
            // 重名理论上在 `collect` 里已经挡掉（来源名唯一），这里再挡一次：
            // 两个来源指向同一个链接名会让后一个**静默覆盖**前一个，
            // 而 zip 的结果会看起来完全正常。
            var name = source.url.lastPathComponent
            var suffix = 2
            while !used.insert(name).inserted {
                name = "\(source.url.lastPathComponent)-\(suffix)"
                suffix += 1
            }
            let link = staging.appending(path: name, directoryHint: source.isDirectory ? .isDirectory : .notDirectory)
            do {
                try fm.createSymbolicLink(at: link, withDestinationURL: source.url)
            } catch {
                // 来源在扫描之后消失了（日志被轮转、用户删了目录）：少一个
                // 条目即可，不必让整次导出失败。
                continue
            }
            roots.append(name)
        }
        let manifest = staging.appending(path: manifestName, directoryHint: .notDirectory)
        guard (try? report.manifest.write(to: manifest, atomically: true, encoding: .utf8)) != nil else {
            throw LogExportError.archiveFailed(detail: tr("无法写入导出说明。", "Could not write the export manifest."))
        }
        roots.append(manifestName)
        return roots
    }

    /// 清单固定用 ASCII 文件名：中文名在 Windows 上解开是乱码，
    /// 而这份文件的存在意义就是让**别人**能读懂这次导出。
    private static let manifestName = "README-export.txt"

    private static func move(_ archive: URL, to destination: URL) throws {
        let fm = FileManager.default
        // 保存面板问过"要替换吗"，但允许替换和真的覆盖是两件事：直接
        // `moveItem` 在目标已存在时会失败，用户明明点了替换却得到一个错误。
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: archive, to: destination)
    }

    // MARK: 运行外部工具

    /// 跑一个系统自带的可执行文件。
    ///
    /// **不经 shell**：参数以 argv 逐项传递，路径里的空格与特殊字符不需要
    /// 转义，也不会被当成命令解释。这与内核、以及应用里已有的几处调用
    /// （`NSTask` 风格的用法）是同一套约定。
    private static func run(_ executable: String, _ arguments: [String],
                            workingDirectory: URL? = nil) -> (status: Int32, message: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        let pipe = Pipe()
        // stdout 一并接过来：zip 正常情况下（-q）不说话，真说了就不该丢。
        process.standardError = pipe
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        // 先读完再等退出：管道写满时子进程会阻塞在写上，而我们在等它退出 ——
        // 顺序反了就是死锁。读到 EOF 本身就说明子进程已经关了管道。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, text)
    }
}

/// 导出失败的两种情形，分开是为了让文案能说清楚"哪一步"失败了。
nonisolated enum LogExportError: LocalizedError {
    case noLogs
    case archiveFailed(detail: String)
    case saveFailed(path: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .noLogs:
            return tr("没有找到任何日志文件。内核还没运行过、或者日志已经被清理了。",
                      "No log files were found. The kernel may never have run, or its logs were cleaned up.")
        case .archiveFailed(let detail):
            let base = tr("打包日志失败。", "Could not create the log archive.")
            return detail.isEmpty ? base : "\(base) \(detail)"
        case .saveFailed(let path, let detail):
            return tr("打包已完成，但写入 \(path) 失败：\(detail)",
                      "The archive was built, but writing \(path) failed: \(detail)")
        }
    }
}

extension Int64 {
    /// 把字节数写成人看的大小。
    ///
    /// `Localization.swift` 里已经有一份 `Int` 的版本，但文件大小天然是
    /// `Int64`（`fileSize` 就是），在这一侧再写一个比让每个调用点都做一次
    /// 可能失败的 `Int(...)` 转换要老实。
    nonisolated var formattedBytes: String { Int(self).formattedBytes }
}
