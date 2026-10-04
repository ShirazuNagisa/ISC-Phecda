import Foundation
import CISC

// 内核 REST 契约的**类型化**入口。
//
// 没有类型化的话，每个界面都要自己去 JSONValue 里翻字段，于是"契约里这个
// 字段叫什么"这件事会在十几个地方各写一遍 —— 而字段改名时编译器一个错
// 都不会报。这里做一次映射，界面只面对 Swift 类型。

extension KernelClient {
    /// 当前内核接口版本。内核与界面**必须**配对：v1 的内核没有 /v1/apps，
    /// 而 v0.2.0 的界面每一屏都依赖它。
    public static let requiredAPIVersion = "v2"

    // MARK: - 编解码

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // 内核的时间戳是 RFC3339；带小数秒与不带都要能解。
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = formatter.date(from: text) ?? fallback.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unrecognised timestamp: \(text)"))
        }
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// 发一个请求并把响应体解码成 `T`。
    public func send<T: Decodable>(_ method: String, _ path: String, body: (some Encodable)? = Optional<Never>.none, as type: T.Type = T.self) async throws -> T {
        let reply = try await perform(method, path, body: body)
        guard let payload = try? reply.body.data() else {
            throw KernelError(code: "decode", status: reply.status, message: "The kernel returned an unreadable body.")
        }
        do {
            return try Self.makeDecoder().decode(T.self, from: payload)
        } catch {
            throw KernelError(code: "decode", status: reply.status,
                              message: "The kernel's reply did not match the expected shape for \(path): \(error)")
        }
    }

    /// 发一个请求，不关心响应体。
    @discardableResult
    public func sendIgnoringReply(_ method: String, _ path: String, body: (some Encodable)? = Optional<Never>.none) async throws -> Int {
        try await perform(method, path, body: body).status
    }

    private func perform(_ method: String, _ path: String, body: (some Encodable)?) async throws -> KernelReply {
        guard let body else { return try await call(method, path) }
        let encoder = Self.makeEncoder()
        let encoded = try encoder.encode(body)
        return try await callRaw(method, path, body: String(decoding: encoded, as: UTF8.self))
    }

    // MARK: - 生命周期

    /// 读取内核的接口版本。**不需要启动内核** —— 走的是 C ABI 的
    /// `isc_api_version()`，因此可以在链接之后、启动之前就判断配对。
    public static func interfaceVersion() throws -> String {
        try KernelClient.rawInterfaceVersion()
    }

    /// 内核元信息（版本、commit、平台能力）。
    public func meta() async throws -> KernelMeta {
        try await send("GET", "/v1/meta", body: Optional<Never>.none, as: KernelMeta.self)
    }

    // MARK: - 建站：预设、识别、运行时

    public func presets() async throws -> [PresetInfo] {
        try await send("GET", "/v1/presets", body: Optional<Never>.none, as: PresetCatalog.self).items
    }

    public func inspectSource(path: String) async throws -> SourceInspection {
        try await send("POST", "/v1/sources/inspect", body: ["path": path], as: SourceInspection.self)
    }

    public func runtimes() async throws -> [RuntimeInfo] {
        try await send("GET", "/v1/runtimes", body: Optional<Never>.none, as: RuntimeList.self).items
    }

    public func provisionRuntimes(kinds: [String], minVersions: [String: String] = [:]) async throws -> JobAccepted {
        struct Body: Encodable {
            let kinds: [String]
            let minVersions: [String: String]?
        }
        let body = Body(kinds: kinds, minVersions: minVersions.isEmpty ? nil : minVersions)
        return try await send("POST", "/v1/runtimes/provision", body: body, as: JobAccepted.self)
    }

    public func removeRuntime(kind: String) async throws {
        try await sendIgnoringReply("DELETE", "/v1/runtimes/\(Self.pathComponent(kind))")
    }

    // MARK: - 站点

    public func apps() async throws -> [AppRecord] {
        try await send("GET", "/v1/apps", body: Optional<Never>.none, as: AppList.self).items
    }

    public func app(_ id: String) async throws -> AppRecord {
        try await send("GET", "/v1/apps/\(Self.pathComponent(id))", body: Optional<Never>.none, as: AppRecord.self)
    }

    public func createApp(_ request: AppCreateRequest) async throws -> AppRecord {
        try await send("POST", "/v1/apps", body: request, as: AppRecord.self)
    }

    public func deployApp(_ id: String) async throws -> JobAccepted {
        try await send("POST", "/v1/apps/\(Self.pathComponent(id))/deploy", body: Optional<Never>.none, as: JobAccepted.self)
    }

    public func startApp(_ id: String) async throws -> JobAccepted {
        try await send("POST", "/v1/apps/\(Self.pathComponent(id))/start", body: Optional<Never>.none, as: JobAccepted.self)
    }

    public func stopApp(_ id: String) async throws {
        try await sendIgnoringReply("POST", "/v1/apps/\(Self.pathComponent(id))/stop")
    }

    public func restartApp(_ id: String) async throws -> JobAccepted {
        try await send("POST", "/v1/apps/\(Self.pathComponent(id))/restart", body: Optional<Never>.none, as: JobAccepted.self)
    }

    public func deleteApp(_ id: String) async throws {
        try await sendIgnoringReply("DELETE", "/v1/apps/\(Self.pathComponent(id))")
    }

    public func appLogs(_ id: String, tail: Int = 200) async throws -> [String] {
        try await send("GET", "/v1/apps/\(Self.pathComponent(id))/logs?tail=\(tail)", body: Optional<Never>.none, as: AppLogs.self).lines
    }

    // MARK: - 指标与建议

    public func metrics() async throws -> MetricsSnapshot {
        try await send("GET", "/v1/metrics", body: Optional<Never>.none, as: MetricsSnapshot.self)
    }

    public func advisories() async throws -> [Advisory] {
        try await send("GET", "/v1/advisories", body: Optional<Never>.none, as: AdvisoryList.self).items
    }

    /// 执行一条建议自带的一键修复动作。
    public func runAdvisoryAction(_ action: AdvisoryAction) async throws {
        let body = try action.body?.text()
        _ = try await callRaw(action.method, action.path, body: body)
    }

    // MARK: - DNS 与公网侧

    public func routes() async throws -> [ProxyRoute] {
        try await send("GET", "/v1/proxy/routes", body: Optional<Never>.none, as: ProxyRouteList.self).items
    }

    public func proxyStatus() async throws -> ProxyStatus {
        try await send("GET", "/v1/proxy/status", body: Optional<Never>.none, as: ProxyStatus.self)
    }

    public func certificates() async throws -> [CertificateInfo] {
        try await send("GET", "/v1/certs", body: Optional<Never>.none, as: CertificateList.self).items
    }

    public func ddnsTasks() async throws -> [DdnsTaskInfo] {
        try await send("GET", "/v1/ddns-tasks", body: Optional<Never>.none, as: DdnsTaskList.self).items
    }

    public func runDdnsTask(_ id: String) async throws {
        try await sendIgnoringReply("POST", "/v1/ddns-tasks/\(Self.pathComponent(id))/run")
    }

    public func credentials() async throws -> [CredentialInfo] {
        try await send("GET", "/v1/credentials", body: Optional<Never>.none, as: CredentialList.self).items
    }

    /// 列出某个凭据下的 DNS 区域。
    public func zones(credentialID: String) async throws -> [DNSZone] {
        try await send("GET", "/v1/credentials/\(Self.pathComponent(credentialID))/zones", body: Optional<Never>.none, as: DNSZoneList.self).items
    }

    /// 列出某个凭据下某个区域的解析条目。
    public func records(credentialID: String, zone: String) async throws -> [DNSRecord] {
        let path = "/v1/credentials/\(Self.pathComponent(credentialID))/zones/\(Self.pathComponent(zone))/records"
        return try await send("GET", path, body: Optional<Never>.none, as: DNSRecordList.self).items
    }

    public func createRecord(credentialID: String, zone: String, _ request: DNSRecordRequest) async throws -> DNSRecord {
        let path = "/v1/credentials/\(Self.pathComponent(credentialID))/zones/\(Self.pathComponent(zone))/records"
        return try await send("POST", path, body: request, as: DNSRecord.self)
    }

    public func deleteRecord(credentialID: String, zone: String, recordID: String) async throws {
        let path = "/v1/credentials/\(Self.pathComponent(credentialID))/zones/\(Self.pathComponent(zone))/records/\(Self.pathComponent(recordID))"
        try await sendIgnoringReply("DELETE", path)
    }

    // MARK: - 设置与任务

    public func settings() async throws -> KernelSettings {
        try await send("GET", "/v1/settings", body: Optional<Never>.none, as: KernelSettings.self)
    }

    public func updateSettings(_ patch: KernelSettings) async throws -> KernelSettings {
        try await send("PATCH", "/v1/settings", body: patch, as: KernelSettings.self)
    }

    public func jobs() async throws -> [JobInfo] {
        try await send("GET", "/v1/jobs", body: Optional<Never>.none, as: JobList.self).items
    }

    public func job(_ id: String) async throws -> JobInfo {
        try await send("GET", "/v1/jobs/\(Self.pathComponent(id))", body: Optional<Never>.none, as: JobInfo.self)
    }
}

/// 创建一个站点的请求体。
public struct AppCreateRequest: Encodable, Sendable {
    public var name: String
    public var presetId: String
    public var sourcePath: String
    public var port: Int?
    public var domains: [String]?
    public var autoStart: Bool?
    public var maxRestarts: Int?
    /// 仅自定义服务器使用；**不经 shell**，可执行文件与参数逐项传递。
    public var customExecutable: String?
    public var customArgs: [String]?

    public init(name: String, presetId: String, sourcePath: String) {
        self.name = name
        self.presetId = presetId
        self.sourcePath = sourcePath
    }
}

/// 新建一条 DNS 解析记录。
public struct DNSRecordRequest: Encodable, Sendable {
    public var name: String
    public var type: String
    public var content: String
    public var ttl: Int?
    public var proxied: Bool?
    public var comment: String?

    public init(name: String, type: String, content: String, ttl: Int? = nil, proxied: Bool? = nil, comment: String? = nil) {
        self.name = name
        self.type = type
        self.content = content
        self.ttl = ttl
        self.proxied = proxied
        self.comment = comment
    }
}
