import Foundation

// 内核契约的 Swift 侧映射。
//
// 与 api/openapi.yaml 一一对应，字段名用 snake_case 转换（见 KernelClient 的
// 解码器配置）。这里只声明 GUI 真正用到的字段：契约里还有几十个字段是别的
// 界面用的，全量镜像只会让两边都要跟着改。
//
// 一条约定：**可选性照着契约里的 `required` 走**。契约说必填的用非可选，
// 这样漏字段会在解码时报错，而不是悄悄变成一个空字符串显示给用户。

// MARK: - 状态

public struct KernelMeta: Decodable, Sendable {
    public let version: String
    public let apiVersion: String
    public let commit: String?
    public let buildTime: String?
    public let os: String?
    public let arch: String?
    public let startedAt: Date?
}

public struct KernelHealth: Decodable, Sendable {
    public let status: String
}

// MARK: - 预设与识别

public struct PresetInfo: Decodable, Sendable, Identifiable {
    public let id: String
    public let version: String
    public let title: String
    /// 运行时类型；空串表示静态站点（由内核直接托管）。
    public let kind: String
    public let minVersion: String?
    public let defaultPort: Int
    public let dockerOnly: Bool?
    public let detectorFiles: [String]?
    public let detectorSuffixes: [String]?
    /// 补充说明，已由内核按请求语言本地化。
    public let note: String?

    /// 静态站点不需要任何外部运行时。
    public var isStatic: Bool { kind.isEmpty }
    public var needsDocker: Bool { kind == "docker" }
}

public struct PresetCatalog: Decodable, Sendable {
    public let items: [PresetInfo]
}

public struct SourceEvidence: Decodable, Sendable, Identifiable {
    public let file: String
    public let signal: String
    public let confidence: Double
    public var id: String { file + "|" + signal }
}

public struct SourceInspection: Decodable, Sendable {
    public let root: String
    public let evidence: [SourceEvidence]
    public let candidates: [PresetInfo]
    public let recommendedPresetId: String
    /// 内核给出的提醒，已本地化（例如"没认出已知技术栈"）。
    public let warnings: [String]?
}

// MARK: - 运行时

public struct RuntimeInfo: Decodable, Sendable, Identifiable {
    public let kind: String
    public let version: String
    /// `system`（本机已装）、`managed`（内核下载并校验过）或 `none`。
    public let source: String
    public let path: String?
    public let executable: String?
    public var id: String { kind }

    public var isSystem: Bool { source == "system" }
}

public struct RuntimeList: Decodable, Sendable {
    public let items: [RuntimeInfo]
}

// MARK: - 站点

public struct AppDomain: Decodable, Sendable, Identifiable {
    public let name: String
    /// 这些是**读的时候**从内核其余部分查出来的，不是站点自己的字段。
    public let routeReady: Bool?
    public let certExpiresAt: Date?
    public let certNeedsRenew: Bool?
    public let certStaging: Bool?
    public let certReason: String?
    public let certError: String?
    public var id: String { name }
}

public struct AppRecord: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let presetId: String
    public let kind: String
    public let sourcePath: String
    public let localPort: Int
    public let state: String
    public let health: String
    public let healthDetail: String?
    public let autoStart: Bool?
    public let maxRestarts: Int?
    public let restartCount: Int?
    public let lastError: String?
    public let domains: [AppDomain]?
    public let runtime: RuntimeInfo?
    public let createdAt: Date?
    public let updatedAt: Date?

    public var domainNames: [String] { (domains ?? []).map(\.name) }
    public var isBusy: Bool {
        ["provisioning", "installing", "building", "starting", "stopping"].contains(state)
    }
    public var isRunning: Bool { state == "running" }
    public var isStatic: Bool { kind.isEmpty }
}

public struct AppList: Decodable, Sendable {
    public let items: [AppRecord]
}

public struct AppLogs: Decodable, Sendable {
    public let lines: [String]
}

public struct JobAccepted: Decodable, Sendable {
    public let jobId: String
}

// MARK: - 指标

public struct HostMetrics: Decodable, Sendable {
    public let at: Date?
    public let cpuPercent: Double
    public let memoryUsedBytes: Int
    public let memoryTotalBytes: Int
    public let netRxBytesPerSec: Double
    public let netTxBytesPerSec: Double
    /// `unsupported` 表示此平台没有实现采样 —— 界面据此说"不支持"，
    /// 而不是把一堆零显示成"什么都没占用"。
    public let backend: String?

    public var isSupported: Bool { backend != "unsupported" }
    public var memoryFraction: Double {
        memoryTotalBytes > 0 ? Double(memoryUsedBytes) / Double(memoryTotalBytes) : 0
    }
}

public struct AppMetrics: Decodable, Sendable, Identifiable {
    public let appId: String
    /// 为 0 表示该站点没有独立进程（静态站点由内核托管）。
    public let pid: Int
    public let cpuPercent: Double
    public let memoryBytes: Int
    public let uptimeSeconds: Int
    public var id: String { appId }
    public var hasOwnProcess: Bool { pid > 0 }
}

public struct MetricsSnapshot: Decodable, Sendable {
    public let host: HostMetrics
    public let apps: [AppMetrics]
    public let history: [HostMetrics]?
}

// MARK: - 建议

public struct AdvisoryAction: Decodable, Sendable {
    public let label: String
    public let method: String
    public let path: String
    public let body: JSONValue?
}

public struct Advisory: Decodable, Sendable, Identifiable {
    public let id: String
    /// `info` / `warning` / `blocking`。
    public let severity: String
    public let title: String
    public let detail: String?
    public let action: AdvisoryAction?

    public var isBlocking: Bool { severity == "blocking" }
}

public struct AdvisoryList: Decodable, Sendable {
    public let items: [Advisory]
}

// MARK: - DNS 与公网侧

public struct ProxyRoute: Codable, Sendable, Identifiable {
    public let id: String
    public let label: String?
    public let domains: [String]
    public let upstream: String
    public let tls: Bool
}

public struct ProxyRouteList: Decodable, Sendable {
    public let items: [ProxyRoute]
}

public struct ProxyStatus: Decodable, Sendable {
    public let running: Bool
    public let port: Int
    public let routes: Int
    public let error: String?
}

public struct CertificateInfo: Decodable, Sendable, Identifiable {
    public let name: String
    public let domains: [String]
    public let issuedAt: Date?
    public let expiresAt: Date?
    public let staging: Bool
    public let needsRenew: Bool
    public let reason: String?
    public let error: String?
    public var id: String { name }

    public var daysRemaining: Int? {
        guard let expiresAt else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day
    }
}

public struct CertificateList: Decodable, Sendable {
    public let items: [CertificateInfo]
}

public struct DdnsTaskInfo: Decodable, Sendable, Identifiable {
    public let id: String
    public let credentialId: String
    public let label: String
    public let enabled: Bool
    public let ipv4: String?
    public let ipv6: String?
    public let lastRunAt: Date?
    public let lastStatus: String?
    public let lastMessage: String?
    public let lastIpv4: String?
    public let lastIpv6: String?
}

public struct DdnsTaskList: Decodable, Sendable {
    public let items: [DdnsTaskInfo]
}

/// 本机当前的公网地址。
///
/// 首页要显示"域名现在解析到哪"，而那个答案的起点就是这里 ——
/// 解析正确与否，取决于 DNS 里的地址和这张网卡上的地址是否一致。
public struct IPStatus: Decodable, Sendable {
    public let primaryIpv4: String?
    public let primaryIpv6: String?
    public let primaryPrefix: String?

    public var summary: String {
        let values = [primaryIpv4, primaryIpv6].compactMap { $0 }.filter { !$0.isEmpty }
        return values.isEmpty ? "—" : values.joined(separator: " · ")
    }
}

/// 一个 DNS 解析条目。
public struct DNSRecord: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let type: String
    public let content: String
    public let ttl: Int?
    public let proxied: Bool?
    public let comment: String?
    public let priority: Int?
}

public struct DNSRecordList: Decodable, Sendable {
    public let items: [DNSRecord]
}

public struct DNSZone: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
}

public struct DNSZoneList: Decodable, Sendable {
    public let items: [DNSZone]
}

public struct CredentialInfo: Decodable, Sendable, Identifiable {
    public let id: String
    public let provider: String
    public let label: String
    public let lastVerifiedAt: Date?
    public let lastVerifyOk: Bool?
    public let lastVerifyError: String?
}

public struct CredentialList: Decodable, Sendable {
    public let items: [CredentialInfo]
    public let nextCursor: String?
}

public struct DNSProviderInfo: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public var identity: String { id }
}

// MARK: - 设置

public struct KernelSettings: Codable, Sendable {
    public var lang: String?
    public var logLevel: String?
    public var eventBufferSize: Int?
    public var notifyOnIPChange: Bool?
    public var proxyEnabled: Bool?
    public var proxyPort: Int?
    public var proxyTls: Bool?
    public var acmeEmail: String?
    public var acmeDirectory: String?
    public var acmeDnsCredentialId: String?

    public init() {}
}

public struct JobInfo: Decodable, Sendable, Identifiable {
    public let id: String
    public let kind: String
    public let status: String
    public let progress: Double?
    public let message: String?
    public let error: JSONValue?
    public let createdAt: Date?
    public let finishedAt: Date?

    public var isFinished: Bool { ["succeeded", "failed", "canceled"].contains(status) }
    public var failedMessage: String? {
        guard status == "failed" else { return nil }
        return error?["detail"].string ?? error?["message"].string ?? message
    }
}

public struct JobList: Decodable, Sendable {
    public let items: [JobInfo]
}
