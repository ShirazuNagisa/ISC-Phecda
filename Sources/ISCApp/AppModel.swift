import Foundation
import Observation
import ISCCore
import UserNotifications

func tr(_ zh: String, _ en: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? zh : en
}

enum KernelPhase { case stopped, starting, running, stopping, failed }

@Observable final class AppModel {
    let kernel = KernelClient()
    var phase: KernelPhase = .stopped
    var services: [PublishedService] = []
    var datasets: [String: JSONValue] = [:]
    var events: [JSONValue] = []
    var errorMessage: String?
    var notice: String?
    var isBusy = false
    var activityCount = 0
    var selectedServiceID: UUID?
    var showWizard = false
    var notificationsEnabled = false
    private var eventTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var lastNotification: [String: Date] = [:]
    private var lifecycleGeneration = 0
    let dataDirectory: URL
    let archiveURL: URL
    static let listPaths = ["/v1/providers", "/v1/credentials", "/v1/ddns-tasks", "/v1/proxy/routes", "/v1/proxy/status", "/v1/certs", "/v1/ip/current", "/v1/jobs", "/v1/settings", "/v1/notify/channels", "/v1/notify/deliveries", "/v1/audit", "/v1/reach/providers", "/v1/changes", "/v1/changes/pending", "/v1/changes/interrupted", "/v1/verify/sessions"]

    init(dataDirectory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.dataDirectory = dataDirectory ?? support.appendingPathComponent("ISC/Kernel", isDirectory: true)
        archiveURL = self.dataDirectory.deletingLastPathComponent().appendingPathComponent("services.json")
        do { services = try ServiceArchive.load(from: archiveURL).services }
        catch { errorMessage = error.localizedDescription }
    }
    var running: Bool { phase == .running }
    var orderedServices: [PublishedService] {
        services.sorted { a,b in a.favorite != b.favorite ? a.favorite : a.order < b.order }
    }
    func items(_ path: String) -> [JSONValue] { datasets[path]?.items ?? [] }
    func fetch(_ path: String) async throws -> JSONValue {
        let reply = try await kernel.call("GET", path)
        datasets[path] = reply.body
        return reply.body
    }
    @discardableResult func request(_ method: String, _ path: String, body: JSONValue? = nil) async throws -> JSONValue {
        activityCount += 1
        defer { activityCount -= 1 }
        let reply = try await kernel.call(method, path, body: body)
        if reply.status == 202 {
            notice = tr("任务已提交，可在任务中心查看进度。", "Task submitted. Track progress in Tasks.")
            _ = try? await fetch("/v1/jobs")
        }
        return reply.body
    }
    @discardableResult func requestRaw(_ method: String, _ path: String, body: String) async throws -> JSONValue {
        activityCount += 1
        defer { activityCount -= 1 }
        return try await kernel.callRaw(method, path, body: body).body
    }
    func execute(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await operation() }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func start() async {
        guard phase != .starting && phase != .stopping && !running else { return }
        phase = .starting; lifecycleGeneration += 1
        do {
            _ = try await kernel.start(dataDirectory: dataDirectory.path)
            phase = .running
            _ = try await request("PATCH", "/v1/settings", body: .object(["lang": .string(Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-CN" : "en")]))
            await refreshAll()
            beginEvents()
        } catch { phase = .failed; errorMessage = error.localizedDescription }
    }
    func stop() async throws {
        guard phase != .starting && phase != .stopping else { throw KernelError(code: "busy", message: tr("内核正在切换状态，请稍后重试。", "The kernel is changing state. Try again shortly.")) }
        phase = .stopping; lifecycleGeneration += 1
        eventTask?.cancel(); eventTask = nil
        refreshTask?.cancel(); refreshTask = nil
        do { _ = try await kernel.stop(); phase = .stopped; datasets = [:] }
        catch { phase = .failed; throw error }
    }
    func refreshAll() async {
        guard running else { return }
        let generation = lifecycleGeneration
        do { datasets["status"] = try await kernel.status() }
        catch { errorMessage = error.localizedDescription; return }
        for path in Self.listPaths {
            guard running && generation == lifecycleGeneration && !Task.isCancelled else { return }
            do { _ = try await fetch(path) }
            catch { datasets[path] = .object(["client_error": .string(error.localizedDescription)]) }
        }
    }
    private func beginEvents() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            var cursor: Int64 = 0
            while let self, self.running, !Task.isCancelled {
                do {
                    let envelope = try await self.kernel.events(since: cursor)
                    guard !Task.isCancelled, self.running else { return }
                    cursor = Int64(envelope["next"].number)
                    let incoming = envelope["events"].array
                    if !incoming.isEmpty { self.events.append(contentsOf: incoming); self.events = Array(self.events.suffix(200)) }
                    if envelope["gap"].bool || !incoming.isEmpty { self.scheduleRefresh() }
                    for event in incoming { await self.notifyIfNeeded(event) }
                } catch {
                    guard !Task.isCancelled else { return }
                    self.errorMessage = error.localizedDescription
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }
    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            await self.refreshAll()
            self.refreshTask = nil
        }
    }
    private func notifyIfNeeded(_ event: JSONValue) async {
        guard notificationsEnabled else { return }
        let payload = event["payload"]
        guard payload["level"].string == "error" || payload["status"].string == "failed" else { return }
        let key = event["type"].string + payload["id"].string
        guard lastNotification[key].map({ Date().timeIntervalSince($0) >= 300 }) ?? true else { return }
        lastNotification[key] = Date()
        let content = UNMutableNotificationContent(); content.title = "ISC"
        content.body = payload["message"].string.isEmpty ? tr("服务需要检查，请打开 ISC 查看详情。", "A service needs attention. Open ISC for details.") : payload["message"].string
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }
    func enableNotifications() async {
        do { notificationsEnabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) }
        catch { errorMessage = error.localizedDescription }
    }
    func saveServices() {
        do { try ServiceArchive(services: services).save(to: archiveURL) }
        catch { errorMessage = error.localizedDescription }
    }
    func addService(_ service: PublishedService) { services.append(service); saveServices() }
    func toggleFavorite(_ id: UUID) {
        guard let index = services.firstIndex(where: { $0.id == id }) else { return }
        services[index].favorite.toggle(); saveServices()
    }
    func removeServiceOrganization(_ id: UUID) { services.removeAll { $0.id == id }; saveServices() }
    func moveService(_ id: UUID, by offset: Int) {
        var list = orderedServices
        guard let old = list.firstIndex(where: { $0.id == id }) else { return }
        let new = max(0, min(list.count - 1, old + offset))
        list.swapAt(old, new)
        for index in list.indices { list[index].order = index }
        services = list; saveServices()
    }
    func ddns(for service: PublishedService) -> JSONValue? { items("/v1/ddns-tasks").first { $0.id == service.ddnsID } }
    func route(for service: PublishedService) -> JSONValue? { items("/v1/proxy/routes").first { $0.id == service.routeID } }
    func fingerprint(for service: PublishedService) -> String {
        [ddns(for: service)?["last_ipv4"].string ?? "", ddns(for: service)?["last_ipv6"].string ?? "", (try? route(for: service)?.text()) ?? ""].joined(separator: "|")
    }
    func serviceIssue(_ service: PublishedService) -> String? {
        if !running { return tr("内核未运行", "Kernel stopped") }
        if service.ddnsID != nil && ddns(for: service) == nil { return tr("动态解析配置缺失", "DDNS configuration missing") }
        if service.routeID != nil && route(for: service) == nil { return tr("转发规则缺失", "Forwarding route missing") }
        if ddns(for: service)?["last_status"].string == "failed" { return tr("动态解析失败", "DDNS failed") }
        return nil
    }
    func serviceAddress(_ service: PublishedService) -> String {
        let domain = service.domains.first ?? ""
        guard let route = route(for: service) else { return domain }
        let settings = datasets["/v1/settings"] ?? .null
        let tls = route["tls"].bool && settings["proxy_tls"].bool
        let port = Int(settings["proxy_port"].number)
        let suffix = port == 0 || port == (tls ? 443 : 80) ? "" : ":\(port)"
        return "\(tls ? "https" : "http")://\(domain)\(suffix)"
    }
}
