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
        case .remote: tr("远程访问", "Remote Access")
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

    // MARK: 远程访问

    var remoteStatus: RemoteStatus?
    var remoteDevices: [RemoteDevice] = []
    /// 进行中的配对会话。它有时效，因此单独轮询刷新倒计时。
    var pairingSession: RemotePairingSession?
    var remoteAudit: [AuditEntry] = []

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
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = support.appendingPathComponent("ISC Phecda", isDirectory: true)
        self.dataDirectory = dataDirectory ?? root.appendingPathComponent("Kernel", isDirectory: true)
        Self.migrateLegacyData(from: support.appendingPathComponent("ISC", isDirectory: true), to: root)
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
        guard !UserDefaults.standard.bool(forKey: Self.onboardingKey) else {
            showOnboarding = false
            return
        }
        showOnboarding = apps.isEmpty && credentials.isEmpty
    }

    /// 让首次引导重新出现。
    ///
    /// 存在的理由不只是"用户想再看一遍"：**没有它就没法重测这个界面**。
    /// 标记落在 UserDefaults 里，重测要先手动去删那个 key —— 而那一步
    /// 在真机上和在开发机上一样别扭。
    func restartOnboarding() {
        UserDefaults.standard.removeObject(forKey: Self.onboardingKey)
        showOnboarding = true
    }

    /// 用户关掉了首次引导：记住这件事。
    func dismissOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingKey)
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
