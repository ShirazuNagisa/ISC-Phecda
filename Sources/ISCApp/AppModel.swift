import Foundation
import Observation
import ISCCore
import UserNotifications

enum KernelPhase: Equatable { case stopped, starting, running, stopping, failed }

/// 界面左侧的三个分区。
///
/// v0.2.0 的界面只有这三块：首页（概览与建议）、服务（发布与查看）、
/// DNS（解析条目）。无关的东西不保留 —— 面向的是"只想一步到位"的用户，
/// 多出来的入口只会让他们不确定该点哪个。
enum AppSection: String, CaseIterable, Identifiable {
    case home, services, dns

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: tr("首页", "Home")
        case .services: tr("服务", "Services")
        case .dns: tr("DNS", "DNS")
        }
    }

    var symbol: String {
        switch self {
        case .home: "gauge.with.dots.needle.50percent"
        case .services: "square.stack.3d.up"
        case .dns: "globe"
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
    var advisories: [Advisory] = []
    var routes: [ProxyRoute] = []
    var certificates: [CertificateInfo] = []
    var ddnsTasks: [DdnsTaskInfo] = []
    var credentials: [CredentialInfo] = []
    var settings: KernelSettings?
    var jobs: [JobInfo] = []
    var events: [JSONValue] = []

    // MARK: 界面状态

    var section: AppSection = .home
    var selectedAppID: String?
    var showingNewService = false
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
            await loadPresets()
            await refreshAll()
            beginEvents()
            beginMetricsPolling()
            showOnboarding = apps.isEmpty && credentials.isEmpty
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
        apps = []; runtimes = []; metrics = nil; advisories = []
        routes = []; certificates = []; ddnsTasks = []; credentials = []
        jobs = []; events = []; settings = nil
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
        async let credentialsTask: [CredentialInfo]? = attempt { try await self.kernel.credentials() }
        async let settingsTask: KernelSettings? = attempt { try await self.kernel.settings() }
        async let advisoriesTask: [Advisory]? = attempt { try await self.kernel.advisories() }
        async let jobsTask: [JobInfo]? = attempt { try await self.kernel.jobs() }

        let results = await (appsTask, runtimesTask, routesTask, certsTask, ddnsTask, credentialsTask, settingsTask, advisoriesTask, jobsTask)

        guard running, generation == lifecycleGeneration else { return }
        if let value = results.0 { apps = value }
        if let value = results.1 { runtimes = value }
        if let value = results.2 { routes = value }
        if let value = results.3 { certificates = value }
        if let value = results.4 { ddnsTasks = value }
        if let value = results.5 { credentials = value }
        if let value = results.6 {
            settings = value
            showOnboarding = apps.isEmpty && credentials.isEmpty
        }
        if let value = results.7 { advisories = value }
        if let value = results.8 { jobs = value }
    }

    /// 预设目录不常变，但与内核语言绑定，因此每次启动后取一次即可。
    func loadPresets() async {
        guard running else { return }
        if let loaded: [PresetInfo] = await attempt({ try await self.kernel.presets() }) {
            presets = loaded
        }
    }

    /// 指标是高频数据，单独一条循环。
    func refreshMetrics() async {
        guard running else { return }
        if let snapshot: MetricsSnapshot = await attempt({ try await self.kernel.metrics() }) {
            metrics = snapshot
        }
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
