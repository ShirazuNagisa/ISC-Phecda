import Foundation
import Observation
import ISCCore
import UserNotifications

enum KernelPhase: Equatable { case stopped, starting, running, stopping, failed }

/// 建议动作可以要求打开的界面。
///
/// 取值与内核的 `AdvisoryActionNavigation` 一一对应；对不上的取值会被忽略
/// （旧内核 + 新界面，或反过来），而不是崩掉。
enum RequestedSheet: String, Identifiable {
    case credentials, settings, ddns, jobs
    var id: String { rawValue }

}

/// 界面左侧的三个分区。
///
/// v0.3.0 在原来的三块之外加了「远程访问」：内核的远程面可以在这里
/// 开关、配对、看设备与审计、装 APNs 凭据。
///
/// v0.2.0 的界面只有这三块：首页（概览与建议）、服务（发布与查看）、
/// DNS（解析条目）。无关的东西不保留 —— 面向的是"只想一步到位"的用户，
/// 多出来的入口只会让他们不确定该点哪个。
enum AppSection: String, CaseIterable, Identifiable {
    /// 启动时选中的页面（默认首页）。
    static var initial: AppSection {
        guard let raw = ProcessInfo.processInfo.environment["ISC_PHECDA_SECTION"],
              let section = AppSection(rawValue: raw) else { return .home }
        return section
    }

    case home, services, dns, remote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: tr("首页", "Home")
        case .services: tr("服务", "Services")
        case .dns: tr("DNS", "DNS")
        case .remote: tr("Mizar 配置", "Mizar")
        }
    }

    var symbol: String {
        switch self {
        case .home: "gauge.with.dots.needle.50percent"
        case .services: "square.stack.3d.up"
        case .dns: "globe"
        // 手机与内核之间的那条链路 —— 用天线而不是手机图标：
        // 这一页讲的是"服务端对外开了一个口子"，不是"这里有一台手机"。
        case .remote: "antenna.radiowaves.left.and.right"
        }
    }
}

@Observable final class AppModel {
    let kernel = KernelClient()

    // MARK: 内核状态

    var phase: KernelPhase = .stopped
    var errorMessage: String?
    var notice: String?
    var isBusy = false
    /// 内核与界面接口版本不匹配时的说明。它必须**显眼**：不匹配时每一屏
    /// 都是空的，不说清楚的话用户只会以为应用坏了。
    var versionMismatch: String?

    // MARK: 数据

    var apps: [AppRecord] = []
    var presets: [PresetInfo] = []
    var runtimes: [RuntimeInfo] = []
    var metrics: MetricsSnapshot?

    /// 各域名的公网可达性，按域名索引。
    ///
    /// 内核每 5 分钟才查一轮，这里跟着指标的节奏取回来即可 —— 判空与
    /// 展示是界面的事，不必自己再定一个周期。
    var reachability: [String: ReachabilityItem] = [:]
    var advisories: [Advisory] = []
    var routes: [ProxyRoute] = []
    var certificates: [CertificateInfo] = []
    var ddnsTasks: [DdnsTaskInfo] = []
    var ipStatus: IPStatus?
    var credentials: [CredentialInfo] = []
    /// 服务商目录：字段定义与能力都由内核声明，界面据此生成表单。
    var providers: [ISCCore.Provider] = []
    var settings: KernelSettings?
    var jobs: [JobInfo] = []
    var events: [JSONValue] = []

    // MARK: DNS 页缓存

    /// DNS 页三层数据（服务商 → 域名 → 解析条目）的缓存，以及这一页的选中项。
    ///
    /// # 为什么放在模型里
    ///
    /// `RootView` 的 detail 是一个 switch：离开 DNS 页时那个视图会被整个丢掉，
    /// 它的 @State 跟着一起没。于是"每次切回来都重新问一遍内核"——用户看到的
    /// 就是点什么都要等。缓存在模型里，切回来时先用旧数据把界面填满，再在
    /// 后台悄悄刷新。
    ///
    /// 选中项（服务商、域名）同样放在这里：它决定缓存里的哪一份被显示，
    /// 也决定后台该刷新哪一份。
    var dnsCredentialID: String?
    var dnsZoneID: String?

    /// 按服务商 id 缓存域名列表。
    var dnsZones: [String: [DNSZone]] = [:]

    /// 按「服务商 id + 域名 id」缓存解析条目。
    ///
    /// 键里带服务商：域名 id 由服务商给出（Cloudflare 是它的 zone id），
    /// 两个服务商下同名域名的 id 并不保证不同。
    var dnsRecords: [String: [DNSRecord]] = [:]

    /// 最近一次读取失败的原因。
    ///
    /// 它**不**清空任何缓存：有旧数据时界面照旧显示旧数据，只在旁边提一句 ——
    /// 一次网络抖动不该让屏幕上的清单凭空消失。
    var dnsFailure: String?

    /// 是否有一次"界面在等结果"的读取在跑（首次进页、换服务商/域名）。
    ///
    /// 后台的定期刷新**不**置它：否则那个小转圈每 5 分钟闪一次，而屏幕上
    /// 的数据其实一直是有的。
    var dnsLoading = false

    /// 后台刷新周期（秒）。
    ///
    /// 5 分钟是一个权衡：解析条目变得不快（改一条也就改一条），而每轮要打
    /// 三个请求 —— 更勤没有意义；再慢则用户改完回来看见的还是旧的。固定值
    /// 还让"这些数据有多旧"变得可预期。
    private static let dnsRefreshInterval: TimeInterval = 300

    /// 最近一次**完整成功**的读取时间；失败不更新它，这样下一次进页面会
    /// 立刻再试一次，而不是干等一个周期。
    private var dnsLastRefresh: Date?

    /// 正在跑的那一轮读取。它的存在让重复调用不会叠加成多轮请求。
    private var dnsRefreshTask: Task<Void, Never>?

    /// 定期刷新的循环。由 DNS 页起步（见 `beginDNSPolling`），内核停止时结束。
    private var dnsPollTask: Task<Void, Never>?

    // MARK: 远程访问

    var remoteStatus: RemoteStatus?
    var remoteDevices: [RemoteDevice] = []
    /// 进行中的配对会话。它有时效，因此单独轮询刷新倒计时。
    var pairingSession: RemotePairingSession?

    // MARK: 界面状态

    /// 当前选中的页面。
    ///
    /// 初始值可以由 `ISC_PHECDA_SECTION` 指定 —— 那是一个**只为验证**存在的
    /// 入口：本机没有辅助功能权限，脚本点不动侧栏，而"某个页面到底渲染成
    /// 什么样"没有别的办法自动看一眼。环境变量只能在进程启动时由启动方
    /// 设置，因此它不是一个可被外部利用的入口。
    var section: AppSection = AppSection.initial
    var selectedAppID: String?
    var showingNewService = false
    /// 首次引导只在**第一次**出现。
    ///
    /// 用户点过"稍后再说"之后不该每次启动都被再问一遍 —— 那是最容易被
    /// 当成"这个应用有毛病"的一类打扰。
    ///
    /// 存在 `Preferences`（而不是直接 `UserDefaults`）里：一次性运行模式
    /// 要求这个标记**不落盘**，否则"每次都是全新安装"就少了最该复验的
    /// 那一步（第一页引导）。见 `FreshRun`。
    private static let onboardingKey = "ISC.Phecda.onboardingDismissed"
    /// 建议动作要求界面跳到某处时记在这里，由 RootView 负责呈现。
    ///
    /// 用"请求"而不是直接打开：模型不该持有视图，而视图也不该去猜
    /// 内核给的 navigation 字符串对应哪个界面。
    var requestedSheet: RequestedSheet?
    var showOnboarding = false
    var notificationsEnabled = false

    let dataDirectory: URL
    private var eventTask: Task<Void, Never>?
    private var metricsTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var lifecycleGeneration = 0
    private var lastNotification: [String: Date] = [:]

    init(dataDirectory: URL? = nil) {
        // 一次性运行模式要先摆好环境（临时数据目录、文件密钥后端），
        // 因为下面这一段就是要读数据目录的地方。幂等。
        FreshRun.prepareIfNeeded()

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

        // # 目录名短是**功能要求**，不是审美
        //
        // 内核的 Unix 域套接字放在 `<数据目录>/run/isc.sock`，而 macOS 的
        // `sun_path` 只有 104 字节。沙箱把数据目录推进容器之后，前缀
        // `~/Library/Containers/app.isc.phecda/Data/Library/Application Support/`
        // 一个人就占掉 80 字节 —— 原来的 `ISC Phecda/Kernel` 再加 17 字节，
        // 整个路径到 112，超限，内核只能降级成纯回环 TCP。
        //
        // 超限时内核会如实报警并降级（不是静默失败），但"能用"和"该这样"
        // 是两回事：一个只剩回环的管理通道比 Unix 域套接字少一层 ACL 防护。
        //
        // 注意这仍然是**余量有限**的修法：现在 99 字节，用户名再长十几位
        // 照样会超。真正稳的做法是让内核不依赖绝对路径长度（改动更大，
        // 见 Documentation/APPSTORE.md 阶段 2）。
        let root = support.appendingPathComponent("Phecda", isDirectory: true)

        // 数据目录的优先级：调用方显式指定 → 环境变量 → 默认位置。
        //
        // 环境变量这一条与**内核自己的约定同名同义**（ISC-Core 的
        // `paths.EnvDataDir`，`isc --data-dir` 也是设它）。界面是把数据目录
        // 显式传给内核的，所以内核那一侧读不到环境变量 —— 得由界面来认它。
        // 两边不一致的话，"换个目录跑一次"就会变成界面写进 A、内核读的是 B
        // 那种最难查的局面。
        let override = ProcessInfo.processInfo.environment[FreshRun.dataDirectoryKey]
        let usesDefaultRoot = dataDirectory == nil && (override ?? "").isEmpty
        if let dataDirectory {
            self.dataDirectory = dataDirectory
        } else if let override, !override.isEmpty {
            self.dataDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            self.dataDirectory = root
        }

        // 迁移只在**用默认位置**时做。
        //
        // 这条判断不是洁癖：一次性运行模式给的是一个空目录，而在那儿搬一次
        // 旧数据，等于"全新安装"里凭空多出上一次安装的凭据与站点 ——
        // 恰恰是这个模式要避免的事。指定了别的目录时同理（那多半是测试）。
        guard usesDefaultRoot else { return }
        Self.migrateLegacyData(
            from: support.appendingPathComponent("ISC Phecda/Kernel", isDirectory: true), to: root)
        Self.migrateLegacyData(
            from: support.appendingPathComponent("ISC", isDirectory: true), to: root)
    }

    /// 把 0.1.x 的数据目录搬到新位置。
    ///
    /// 只搬一次（目标已存在就跳过）：重复搬运会覆盖用户在新版本里积累的数据。
    private static func migrateLegacyData(from oldRoot: URL, to newRoot: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: oldRoot.path), !fm.fileExists(atPath: newRoot.path) else { return }
        do { try fm.copyItem(at: oldRoot, to: newRoot) }
        catch { NSLog("ISC Phecda legacy migration failed: %@", error.localizedDescription) }
    }

    var running: Bool { phase == .running }

    var selectedApp: AppRecord? {
        guard let selectedAppID else { return nil }
        return apps.first { $0.id == selectedAppID }
    }

    func metrics(for appID: String) -> AppMetrics? {
        metrics?.apps.first { $0.appId == appID }
    }

    /// 还没结束的任务。首页据此显示"正在做什么"，而不是只转一个圈。
    var activeJobs: [JobInfo] {
        jobs.filter { !$0.isFinished }
    }

    // MARK: 内核生命周期

    func start() async {
        guard phase != .starting, phase != .stopping, !running else { return }
        phase = .starting
        lifecycleGeneration += 1
        versionMismatch = nil
        do {
            // 先看版本，再决定要不要启动。版本不匹配时启动内核没有意义
            // （每个请求都会 404），而用户需要知道的正是这一点。
            let bundled = try KernelClient.interfaceVersion()
            guard bundled == KernelClient.requiredAPIVersion else {
                versionMismatch = tr(
                    "界面需要 \(KernelClient.requiredAPIVersion) 版内核接口，但随包的内核是 \(bundled)。请把两者一起重新构建。",
                    "This app needs the \(KernelClient.requiredAPIVersion) kernel interface, but the bundled kernel is \(bundled). Rebuild both together.")
                phase = .failed
                return
            }
            // 把内置运行时的位置告诉内核。
            //
            // 内核以 libisc 的形式跑在**同一个进程**里，所以 setenv 对它可见 ——
            // 这也是唯一不用动 C ABI（D24）就能传配置的办法，与内核那边读
            // ISC_BUNDLED_RUNTIMES 是一对。
            //
            // 目录不存在时照样传：那表示这份构建没有内置运行时，内核会退回
            // 按需取回。反过来在这里判断存在与否，会把"打包时忘了放"变成
            // 一个静默的下载，而那正是 App Review 2.5.2 要挡的事。
            if let resources = Bundle.main.resourceURL {
                setenv("ISC_BUNDLED_RUNTIMES",
                       resources.appendingPathComponent("runtimes", isDirectory: true).path, 1)
            }
            _ = try await kernel.start(dataDirectory: dataDirectory.path)
            phase = .running
            var patch = KernelSettings()
            patch.lang = kernelLanguage
            _ = try? await kernel.updateSettings(patch)
            await loadCatalogs()
            await refreshAll()
            beginEvents()
            beginMetricsPolling()
            updateOnboarding()
        } catch {
            phase = .failed
            errorMessage = error.localizedDescription
        }
    }

    func stop() async throws {
        guard phase != .starting, phase != .stopping else {
            throw KernelError(code: "busy", message: tr("内核正在切换状态，请稍后重试。", "The kernel is changing state. Try again shortly."))
        }
        phase = .stopping
        lifecycleGeneration += 1
        eventTask?.cancel(); eventTask = nil
        metricsTask?.cancel(); metricsTask = nil
        refreshTask?.cancel(); refreshTask = nil
        dnsPollTask?.cancel(); dnsPollTask = nil
        do {
            _ = try await kernel.stop()
            phase = .stopped
            clearData()
        } catch {
            phase = .failed
            throw error
        }
    }

    private func clearData() {
        apps = []; runtimes = []; metrics = nil; advisories = []; reachability = [:]
        routes = []; certificates = []; ddnsTasks = []; credentials = []; ipStatus = nil
        jobs = []; events = []; settings = nil; providers = []
        // DNS 页的缓存跟着内核一起作废：内核重启后是另一个实例，旧的域名与
        // 解析条目不该继续装作有效。选中的服务商留着 —— 它只是一个 id，
        // 下一次读取时会重新校验，用户回来后还是原来那个。
        dnsZones = [:]; dnsRecords = [:]; dnsFailure = nil; dnsZoneID = nil
        dnsLastRefresh = nil
    }

    // MARK: 刷新

    /// 拉取全部数据。
    ///
    /// 每一项单独容错：某一项失败不该让其余部分也空掉 —— 用户看到的应该是
    /// "证书这块有问题"，而不是整个界面什么都没有。
    func refreshAll() async {
        guard running else { return }
        let generation = lifecycleGeneration

        async let appsTask: [AppRecord]? = attempt { try await self.kernel.apps() }
        async let runtimesTask: [RuntimeInfo]? = attempt { try await self.kernel.runtimes() }
        async let routesTask: [ProxyRoute]? = attempt { try await self.kernel.routes() }
        async let certsTask: [CertificateInfo]? = attempt { try await self.kernel.certificates() }
        async let ddnsTask: [DdnsTaskInfo]? = attempt { try await self.kernel.ddnsTasks() }
        async let ipTask: IPStatus? = attempt { try await self.kernel.currentIP() }
        async let credentialsTask: [CredentialInfo]? = attempt { try await self.kernel.credentials() }
        async let settingsTask: KernelSettings? = attempt { try await self.kernel.settings() }
        async let advisoriesTask: [Advisory]? = attempt { try await self.kernel.advisories() }
        async let jobsTask: [JobInfo]? = attempt { try await self.kernel.jobs() }
        async let remoteTask: RemoteStatus? = attempt { try await self.kernel.remoteStatus() }
        async let devicesTask: [RemoteDevice]? = attempt { try await self.kernel.remoteDevices() }

        let results = await (appsTask, runtimesTask, routesTask, certsTask, ddnsTask, credentialsTask, settingsTask, advisoriesTask, jobsTask, remoteTask)
        let currentIP = await ipTask
        let currentDevices = await devicesTask

        guard running, generation == lifecycleGeneration else { return }
        if let value = results.0 { apps = value }
        if let value = results.1 { runtimes = value }
        if let value = results.2 { routes = value }
        if let value = results.3 { certificates = value }
        if let value = results.4 { ddnsTasks = value }
        if let currentIP { ipStatus = currentIP }
        if let value = results.5 { credentials = value }
        if let value = results.6 {
            settings = value
            updateOnboarding()
        }
        if let value = results.7 { advisories = value }
        if let value = results.8 { jobs = value }
        if let value = results.9 { remoteStatus = value }
        if let currentDevices { remoteDevices = currentDevices }
    }

    /// 重新判断要不要显示首次引导。
    ///
    /// 三个条件缺一不可：还没有站点、还没有凭据、而且用户没关过它。
    /// 最后一条是补出来的：没有它，点过"稍后再说"的用户每次启动都会被
    /// 再问一遍 —— 那是最容易被当成"这个应用有毛病"的一类打扰。
    func updateOnboarding() {
        guard !Preferences.bool(Self.onboardingKey) else {
            showOnboarding = false
            return
        }
        showOnboarding = apps.isEmpty && credentials.isEmpty
    }

    /// 让首次引导重新出现。
    ///
    /// 存在的理由不只是"用户想再看一遍"：**没有它就没法重测这个界面**。
    /// 标记落在偏好里，重测要先手动去删那个 key —— 而那一步在真机上和在
    /// 开发机上一样别扭。（一次性运行模式里它本来就不落盘，见 `FreshRun`。）
    func restartOnboarding() {
        Preferences.remove(Self.onboardingKey)
        showOnboarding = true
    }

    /// 用户关掉了首次引导：记住这件事。
    func dismissOnboarding() {
        Preferences.set(Self.onboardingKey, true)
        showOnboarding = false
    }

    /// 目录类数据（预设、服务商）在内核运行期是固定的，取一次即可。
    ///
    /// 但界面可能在内核启动之前就打开（或者启动失败后重试），因此这个方法
    /// 要能被重复调用而不产生副作用。
    func loadCatalogs() async {
        guard running else { return }
        if let loaded: [PresetInfo] = await attempt({ try await self.kernel.presets() }) {
            presets = loaded
        }
        if let loaded: [ISCCore.Provider] = await attempt({ try await self.kernel.providers() }) {
            providers = loaded
        }
    }

    /// 指标是高频数据，单独一条循环。
    func refreshMetrics() async {
        guard running else { return }
        if let snapshot: MetricsSnapshot = await attempt({ try await self.kernel.metrics() }) {
            metrics = snapshot
        }
        // 可达性跟着一起取：它自身的节奏是分钟级，而这里只是把结果拿回来。
        // 失败不覆盖已有结果 —— 一次网络抖动不该让界面上的状态凭空消失。
        if let items: [ReachabilityItem] = await attempt({ try await self.kernel.reachability() }) {
            reachability = Dictionary(uniqueKeysWithValues: items.map { ($0.domain, $0) })
        }
    }

    /// 某个站点的公网可达性。
    ///
    /// 取该站点**第一个**绑定的域名：一个站点可以绑多个，而列表里只放
    /// 得下一个指示位。要看全部就去站点详情。
    func reachability(for app: AppRecord) -> ReachabilityItem? {
        for domain in app.domainNames {
            if let item = reachability[domain] { return item }
        }
        return nil
    }

    private func beginMetricsPolling() {
        metricsTask?.cancel()
        metricsTask = Task { [weak self] in
            while let self, self.running, !Task.isCancelled {
                await self.refreshMetrics()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: DNS 页：缓存

    /// 当前选中服务商下的域名缓存；nil 表示还没读到过。
    ///
    /// 「还没读到」和「读到了空列表」在界面上是两句不同的话，所以这里
    /// 用可选值而不是空数组把两者分开。
    var currentDNSZones: [DNSZone]? {
        guard let dnsCredentialID else { return nil }
        return dnsZones[dnsCredentialID]
    }

    /// 当前选中域名下的解析条目缓存；nil 表示还没读到过。
    var currentDNSRecords: [DNSRecord]? {
        guard let dnsCredentialID, let dnsZoneID else { return nil }
        return dnsRecords[Self.dnsCacheKey(credentialID: dnsCredentialID, zoneID: dnsZoneID)]
    }

    /// 当前选中域名的显示名。界面上给用户看名字，接口要的是 id。
    var dnsZoneLabel: String {
        guard let dnsZoneID else { return "" }
        return currentDNSZones?.first { $0.id == dnsZoneID }?.name ?? dnsZoneID
    }

    /// 缓存键。用 "/" 拼：服务商给的域名 id 是 UUID 或域名本身，不含它。
    private static func dnsCacheKey(credentialID: String, zoneID: String) -> String {
        "\(credentialID)/\(zoneID)"
    }

    /// 当前选择对应的数据在缓存里齐了没有。
    private var dnsCacheIsComplete: Bool {
        // 一个服务商都没有时"缺"的是用户还没添加，不是数据没读到 ——
        // 这种情况不该每次进页面都去问一遍内核。
        guard !credentials.isEmpty else { return true }
        guard let credentialID = dnsCredentialID, let zones = dnsZones[credentialID] else { return false }
        // 这个服务商名下确实一个域名都没有：没有解析条目可读，也算齐了。
        guard let zoneID = dnsZoneID, zones.contains(where: { $0.id == zoneID }) else { return true }
        return dnsRecords[Self.dnsCacheKey(credentialID: credentialID, zoneID: zoneID)] != nil
    }

    /// 缓存是否已经过了刷新周期。
    private var dnsCacheIsFresh: Bool {
        guard let dnsLastRefresh else { return false }
        return Date().timeIntervalSince(dnsLastRefresh) < Self.dnsRefreshInterval
    }

    /// 进入 DNS 页时调用：有缓存就用缓存，缺什么才去内核取什么。
    ///
    /// 这是"切页不重新拉取"的落点：5 分钟内来回切页面，这里一次请求都不发，
    /// 界面直接拿缓存渲染。
    ///
    /// 幂等：重复调用（视图重建、切页回来）不会多出请求，也不会覆盖用户
    /// 已经选好的服务商与域名。
    func prepareDNS() async {
        guard running else { return }
        normalizeDNSSelection()
        if !dnsCacheIsComplete {
            // 首次进页、或刚换过服务商：这一步要等，转圈是应该的。
            await refreshDNS(visible: true)
            return
        }
        guard !dnsCacheIsFresh else { return }
        // 缓存齐全但已经过期（离开很久、或上一次读失败过）：界面照旧立刻
        // 渲染缓存，这一轮在后台跑，不挡任何操作。
        await refreshDNS()
    }

    /// 用户换了服务商或域名之后调用：让缓存满足新的选择。
    ///
    /// 幂等：新的选择已经有缓存时它什么都不做 —— 这也是来回切服务商、
    /// 切域名时不重新拉取的原因。
    ///
    /// 它**不替用户挑服务商**：在服务商那一栏选"请选择"就是不选，页面会
    /// 说明该做什么；替用户挑回来只会让选择器自己弹回去。域名的默认选择
    /// 与内核那边一致（第一个），否则换个服务商就得多点一次。
    func syncDNSCache() async {
        guard running, let credentialID = dnsCredentialID else { return }
        guard let zones = dnsZones[credentialID] else {
            // 这个服务商的域名还没读过。域名选择属于上一个服务商，先清掉，
            // 读完由 performDNSLoad 选第一个。
            dnsZoneID = nil
            await refreshDNS(visible: true)
            return
        }
        // 选中的域名不在这个服务商名下（刚换服务商、或在服务商那边删掉了）
        // 时退回第一个，否则界面会指着一个取不到数据的域名。
        if let zoneID = dnsZoneID, !zones.contains(where: { $0.id == zoneID }) {
            dnsZoneID = nil
        }
        if dnsZoneID == nil { dnsZoneID = zones.first?.id }
        guard let zoneID = dnsZoneID else { return }
        guard dnsRecords[Self.dnsCacheKey(credentialID: credentialID, zoneID: zoneID)] == nil else { return }
        await refreshDNS(visible: true)
    }

    /// 读一遍当前选择对应的数据：服务商列表、域名列表、解析条目。
    ///
    /// 每一项各自容错并**保留旧值**：一次网络抖动不该让界面上的清单消失，
    /// 用户该看到的是一句"这次没读到"，而不是整页变空。
    ///
    /// 幂等：同一时刻只有一轮请求在跑。已经有一轮时先等它结束 —— 它刷的
    /// 可能是切换前的选择，所以等完还要按现在的选择再跑一轮。
    func refreshDNS(visible: Bool = false) async {
        guard running else { return }
        if visible { dnsLoading = true }
        defer { if visible { dnsLoading = false } }
        if let inflight = dnsRefreshTask { await inflight.value }
        guard running else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performDNSLoad()
        }
        dnsRefreshTask = task
        await task.value
        // 只在还是自己那一轮时清句柄：等待期间可能有另一轮已经接手。
        if dnsRefreshTask == task { dnsRefreshTask = nil }
    }

    /// 真正打内核的那一轮。所有写入缓存的地方都收在这里，界面只读缓存。
    private func performDNSLoad() async {
        let generation = lifecycleGeneration

        // 服务商列表跟着一起读：它是 DNS 页的第一层选择，在别处被删掉之后
        // 这一页必须能发现，否则会一直指着一个不存在的 id 反复报错。
        if let loaded: [CredentialInfo] = await attempt({ try await self.kernel.credentials() }) {
            credentials = loaded
        }
        normalizeDNSSelection()

        guard let credentialID = dnsCredentialID else {
            guard generation == lifecycleGeneration else { return }
            dnsFailure = nil
            dnsLastRefresh = Date()
            return
        }

        var failure: String?
        do {
            let loaded = try await kernel.zones(credentialID: credentialID)
            dnsZones[credentialID] = loaded
            if dnsZoneID == nil || !loaded.contains(where: { $0.id == dnsZoneID }) {
                dnsZoneID = loaded.first?.id
            }
        } catch {
            // 保留上一次读到的域名列表：它是用户继续操作的依据。
            failure = error.localizedDescription
        }

        if let zoneID = dnsZoneID {
            do {
                let loaded = try await kernel.records(credentialID: credentialID, zone: zoneID)
                dnsRecords[Self.dnsCacheKey(credentialID: credentialID, zoneID: zoneID)] = loaded
            } catch {
                // 域名列表的错误更靠上（用户得先把域名选对），优先显示它。
                if failure == nil { failure = error.localizedDescription }
            }
        }

        guard generation == lifecycleGeneration else { return }
        dnsFailure = failure
        if failure == nil { dnsLastRefresh = Date() }
    }

    /// 让选中的服务商与域名同凭据列表、缓存对齐。
    ///
    /// 只做**本地**判断，不发请求：选中项在别处被删掉时退回第一个，
    /// 而不是拿着一个不存在的 id 反复报错。
    private func normalizeDNSSelection() {
        // 凭据列表为空时不动选择：那表示还没读到，不是用户真的删光了。
        if !credentials.isEmpty,
           let current = dnsCredentialID, !credentials.contains(where: { $0.id == current }) {
            dnsCredentialID = credentials.first?.id
            dnsZoneID = nil
        }
        if dnsCredentialID == nil { dnsCredentialID = credentials.first?.id }
        guard let credentialID = dnsCredentialID, let zones = dnsZones[credentialID], !zones.isEmpty else { return }
        if dnsZoneID == nil || !zones.contains(where: { $0.id == dnsZoneID }) {
            dnsZoneID = zones.first?.id
        }
    }

    /// 开始定期刷新 DNS 缓存。
    ///
    /// 由 DNS 页在出现时起步，而不是内核一起来就跑：没人打开过这一页时，
    /// 每 5 分钟打三个请求没有意义。起来之后它一直跑到内核停止 —— 这样
    /// 用户离开再回来时，缓存里的东西正好是新的。
    ///
    /// 幂等：已经在跑、或内核没在跑，都不重开第二个循环。
    func beginDNSPolling() {
        guard running, dnsPollTask == nil else { return }
        dnsPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.dnsRefreshInterval))
                guard let self, !Task.isCancelled, self.running else { return }
                // 有人正在读时跳过这一轮：撞上去的代价是同一份数据请求两遍，
                // 而错过一轮的代价只是晚 5 分钟。
                if self.dnsRefreshTask == nil { await self.refreshDNS() }
            }
        }
    }

    // MARK: DNS 页：远程子域名

    /// DNS 页最下面那条展开条要显示的地址：Phecda 给 Mizar 用的用户子域名。
    ///
    /// 它住在远程状态里（`public.host`）。这里按需补一次读取，而不是复用
    /// `refreshAll()` —— 那个是十几个请求的全量刷新，而这一条只有用户展开
    /// 那条时才看得见。
    ///
    /// 幂等：已经拿到过状态就不重复读；展开条每点一次不会多打一个请求。
    func loadRemoteStatusIfNeeded() async {
        guard remoteStatus == nil else { return }
        await refreshRemoteStatus()
    }

    /// 重新读一次远程状态。给展开条上的"重新读取"用：用户刚在「远程访问」
    /// 页开过公网访问时，需要能立刻在这里看到子域名。
    func refreshRemoteStatus() async {
        guard running else { return }
        if let status: RemoteStatus = await attempt({ try await self.kernel.remoteStatus() }) {
            remoteStatus = status
        }
    }

    func beginEvents() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            var cursor: Int64 = 0
            while let self, self.running, !Task.isCancelled {
                do {
                    let envelope = try await self.kernel.events(since: cursor)
                    guard !Task.isCancelled, self.running else { return }
                    cursor = Int64(envelope["next"].number)
                    let incoming = envelope["events"].array
                    if !incoming.isEmpty {
                        self.events.append(contentsOf: incoming)
                        self.events = Array(self.events.suffix(200))
                    }
                    if envelope["gap"].bool || !incoming.isEmpty { self.scheduleRefresh() }
                    for event in incoming { await self.notifyIfNeeded(event) }
                } catch {
                    guard !Task.isCancelled else { return }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            // 合并短时间内的多个事件：一次部署会连续产生十几个事件，
            // 每个都全量刷新只会让界面抖。
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            await self.refreshAll()
            self.refreshTask = nil
        }
    }

    // MARK: 动作

    /// 执行一个会改动内核状态的操作，统一处理忙碌标志与错误。
    func execute(_ operation: @escaping () async throws -> Void) {
        Task {
            isBusy = true
            do { try await operation(); await refreshAll() }
            catch { errorMessage = error.localizedDescription }
            isBusy = false
        }
    }

    func createService(_ request: AppCreateRequest, deploy: Bool) async throws -> AppRecord {
        let created = try await kernel.createApp(request)
        if deploy { _ = try await kernel.deployApp(created.id) }
        await refreshAll()
        return created
    }

    func apply(_ advisory: Advisory) {
        guard let action = advisory.action else { return }
        if let navigation = action.navigation {
            requestedSheet = RequestedSheet(rawValue: navigation)
            return
        }
        execute { try await self.kernel.runAdvisoryAction(action) }
    }

    func enableNotifications() async {
        do { notificationsEnabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) }
        catch { errorMessage = error.localizedDescription }
    }

    private func notifyIfNeeded(_ event: JSONValue) async {
        guard notificationsEnabled else { return }
        let payload = event["payload"]
        guard payload["level"].string == "error" || payload["state"].string == "failed" else { return }
        let key = event["type"].string + payload["id"].string
        guard lastNotification[key].map({ Date().timeIntervalSince($0) >= 300 }) ?? true else { return }
        lastNotification[key] = Date()
        let content = UNMutableNotificationContent()
        content.title = "ISC Phecda"
        content.body = payload["message"].string.isEmpty
            ? tr("有站点需要检查，请打开 ISC Phecda 查看详情。", "A site needs attention. Open ISC Phecda for details.")
            : payload["message"].string
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }

    /// 把一次可能失败的数据拉取变成可选值。
    private func attempt<T>(_ work: () async throws -> T) async -> T? {
        do { return try await work() }
        catch { return nil }
    }
}
