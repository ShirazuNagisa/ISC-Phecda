import Foundation
import Observation
import ISCCore
import ISCSupervisor
import UserNotifications

func tr(_ zh: String, _ en: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? zh : en
}

enum KernelPhase { case stopped, starting, running, stopping, failed }

@Observable final class AppModel {
    let kernel = KernelClient()
    let supervisor = DeploymentCoordinator()
    let dockerSupervisor = DockerSupervisor()
    var supervisorClient: SupervisorServiceClient?
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
    /// A `services.json` written by a build that predates kernel-owned records. It is read
    /// once, imported, and thereafter only ever renamed — never written again.
    private var legacyServices: [PublishedService] = []
    /// Counts collection writes in flight, so a refresh triggered mid-write cannot mirror a
    /// stale collection back over the change the user just made.
    private var serviceWritesInFlight = 0
    let dataDirectory: URL
    let legacyArchiveURL: URL
    static let listPaths = ["/v1/providers", "/v1/credentials", "/v1/ddns-tasks", "/v1/proxy/routes", "/v1/proxy/status", "/v1/certs", "/v1/ip/current", "/v1/jobs", "/v1/settings", "/v1/notify/channels", "/v1/notify/deliveries", "/v1/audit", "/v1/reach/providers", "/v1/changes", "/v1/changes/pending", "/v1/changes/interrupted", "/v1/verify/sessions", "/v1/phecda/presets", "/v1/phecda/projects", "/v1/phecda/deployments", "/v1/public-services"]

    init(dataDirectory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let phecdaRoot = support.appendingPathComponent("ISC Phecda", isDirectory: true)
        let oldRoot = support.appendingPathComponent("ISC", isDirectory: true)
        self.dataDirectory = dataDirectory ?? phecdaRoot.appendingPathComponent("Kernel", isDirectory: true)
        legacyArchiveURL = phecdaRoot.appendingPathComponent("services.json")
        let bundleHelper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/PhecdaSupervisor")
        let siblingHelper = URL(fileURLWithPath: CommandLine.arguments.first ?? "").deletingLastPathComponent().appendingPathComponent("PhecdaSupervisor")
        let helper = FileManager.default.isExecutableFile(atPath: bundleHelper.path) ? bundleHelper : siblingHelper
        supervisorClient = try? SupervisorServiceClient(executableURL: helper, stateDirectory: phecdaRoot.appendingPathComponent("Supervisor", isDirectory: true))
        Self.migrateLegacyData(from: oldRoot, to: phecdaRoot)
        // Only a read, and only to be imported once: the kernel owns published services now.
        do { legacyServices = try ServiceArchive.load(from: legacyArchiveURL).services }
        catch { errorMessage = error.localizedDescription }
    }
    private static func migrateLegacyData(from oldRoot: URL, to newRoot: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: oldRoot.path), !fm.fileExists(atPath: newRoot.path) else { return }
        do { try fm.copyItem(at: oldRoot, to: newRoot) }
        catch { NSLog("ISC Phecda legacy migration failed: %@", error.localizedDescription) }
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
    func submitDeployment(_ plan: DeploymentPlan) async throws -> UUID {
        if let supervisorClient { return try await supervisorClient.submit(plan) }
        return await supervisor.submit(plan)
    }
    func rollbackDeployment(_ id: UUID) async throws {
        if let supervisorClient { _ = try await supervisorClient.rollback(id) }
        else { _ = try await supervisor.rollback(id) }
    }
    func monitorDeployment(_ id: UUID, projectID: UUID, presetID: String, localPort: Int) {
        guard let client = supervisorClient else { return }
        Task { @MainActor in
            while !Task.isCancelled {
                do {
                    guard let state = try await client.list().jobs?.first(where: { $0.id == id }) else { break }
                    let mapped: String
                    switch state.phase { case .building: mapped = "building"; case .running, .completed: mapped = "running"; case .stopping, .cancelled: mapped = "stopped"; case .failed: mapped = "failed"; default: mapped = "preparing" }
                    var fields: [String: JSONValue] = ["id": .string(id.uuidString), "project_id": .string(projectID.uuidString), "preset_id": .string(presetID), "state": .string(mapped), "local_port": .number(Double(localPort))]
                    if let error = state.error { fields["last_error"] = .string(error) }
                    _ = try await request("POST", "/v1/phecda/deployments", body: .object(fields))
                    if [.completed, .failed, .cancelled].contains(state.phase) { break }
                } catch let caught {
                    let fields: [String: JSONValue] = ["id": .string(id.uuidString), "project_id": .string(projectID.uuidString), "preset_id": .string(presetID), "state": .string("failed"), "local_port": .number(Double(localPort)), "last_error": .string(caught.localizedDescription)]
                    _ = try? await request("POST", "/v1/phecda/deployments", body: .object(fields))
                    break
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
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
            await importLegacyServices()
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
        mirrorServicesFromKernel()
    }
    /// Mirrors the kernel's collection into the UI model.
    ///
    /// Skipped while a write is in flight, and skipped when the fetch failed: a collection
    /// that did not load must not read as "the user has no published services", which would
    /// blank the list and could be saved back over the real records.
    private func mirrorServicesFromKernel() {
        guard serviceWritesInFlight == 0, let collection = datasets["/v1/public-services"], collection["client_error"] == .null else { return }
        services = PublishedService.kernelCollection(from: collection)
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
        let content = UNMutableNotificationContent(); content.title = "ISC Phecda"
        content.body = payload["message"].string.isEmpty ? tr("服务需要检查，请打开 ISC Phecda 查看详情。", "A service needs attention. Open ISC Phecda for details.") : payload["message"].string
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }
    func enableNotifications() async {
        do { notificationsEnabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) }
        catch { errorMessage = error.localizedDescription }
    }
    // MARK: - Published services
    //
    // The records live in ISC-Core (`/v1/public-services`), which is the only writer. That is
    // what makes a deployment's `public_service_id` trustworthy: the kernel clears it in the
    // same transaction that drops a service, so this side has nothing to clean up and cannot
    // forget to. Materializing the binding still goes through the kernel's own DDNS,
    // reverse-proxy and certificate APIs.

    /// Writes the whole collection back to the kernel.
    ///
    /// Replacement rather than per-record edits, matching how the kernel stores it: the set is
    /// validated as a unit (duplicate ids, one domain claimed twice), and the reply is mirrored
    /// back so local state is exactly what the kernel holds rather than an optimistic guess.
    func saveServices() async throws {
        // The kernel is the store of record, so an edit with the kernel stopped cannot be
        // saved. Say so rather than dropping the user's action silently.
        guard running else {
            errorMessage = tr("内核未运行，改动未保存。", "The kernel is not running, so the change was not saved.")
            return
        }
        serviceWritesInFlight += 1
        defer { serviceWritesInFlight -= 1 }
        let saved = try await request("PUT", "/v1/public-services", body: PublishedService.kernelCollection(services))
        datasets["/v1/public-services"] = saved
        services = PublishedService.kernelCollection(from: saved)
    }

    /// Persists a local edit made by a control that cannot await. The UI already shows the
    /// change; a rejected write surfaces as an error and the next refresh restores the
    /// kernel's version.
    private func persistServices() {
        execute { try await self.saveServices() }
    }

    func addService(_ service: PublishedService) async throws {
        services.append(service)
        try await saveServices()
    }

    func toggleFavorite(_ id: UUID) {
        guard let index = services.firstIndex(where: { $0.id == id }) else { return }
        services[index].favorite.toggle(); persistServices()
    }

    /// Removes a published service. The kernel clears any deployment reference to it in the
    /// same transaction, so there is nothing to unbind here.
    func removePublishedService(_ id: UUID) async throws {
        services.removeAll { $0.id == id }
        try await saveServices()
    }

    func moveService(_ id: UUID, by offset: Int) {
        var list = orderedServices
        guard let old = list.firstIndex(where: { $0.id == id }) else { return }
        let new = max(0, min(list.count - 1, old + offset))
        list.swapAt(old, new)
        for index in list.indices { list[index].order = index }
        services = list; persistServices()
    }

    /// Persists an edited record (rename, verification stamp) made in place by a view.
    func serviceEdited() { persistServices() }

    /// Imports a pre-kernel `services.json` exactly once.
    ///
    /// Only into an empty collection: if the kernel already holds services, this build has
    /// either migrated already or the user created them since, and importing on top would
    /// duplicate records. The file is renamed rather than deleted, so nothing is destroyed if
    /// the import turns out to be wrong.
    func importLegacyServices() async {
        guard running, services.isEmpty, !legacyServices.isEmpty else { return }
        do {
            services = legacyServices
            try await saveServices()
            try? FileManager.default.moveItem(at: legacyArchiveURL, to: legacyArchiveURL.appendingPathExtension("migrated"))
            notice = tr("已将 \(legacyServices.count) 个已发布服务迁移到内核。", "Moved \(legacyServices.count) published service(s) into the kernel.")
        } catch {
            services = []
            errorMessage = error.localizedDescription
        }
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
