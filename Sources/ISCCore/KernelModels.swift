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

/// 一条建议可以做的事。
///
/// 两种形态：**跳转到界面某处**（`navigation`），或**发一次 API 调用**
/// （`method` + `path`）。前者用于"需要用户填点什么"的情况 —— 早先只有后者，
/// 于是"去添加凭据"只能伪装成一个不带请求体的 POST，点下去必然 400。
public struct AdvisoryAction: Decodable, Sendable {
    public let label: String
    public let navigation: String?
    public let method: String?
    public let path: String?
    public let body: JSONValue?

    public var isNavigation: Bool { navigation != nil }
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

/// 一种记录类型从哪里取地址。
///
/// `netInterface` 走内核自己的地址快照（已过滤掉不能用于公网的地址），
/// `url` / `cmd` 是用户自己指定的来源。
public struct DdnsSource: Codable, Sendable {
    public var enable: Bool
    /// `netInterface` / `url` / `cmd`。
    public var getType: String
    public var value: String
    public var domains: [String]
    /// 仅 IPv6 使用：地址选择器。
    public var selector: String?

    public init(enable: Bool, getType: String = "netInterface", value: String = "",
                domains: [String] = [], selector: String? = nil) {
        self.enable = enable
        self.getType = getType
        self.value = value
        self.domains = domains
        self.selector = selector
    }

    public var isAutomatic: Bool { getType == "netInterface" && value.isEmpty }
}

/// 一个动态解析任务。
///
/// ⚠️ `ipv4` / `ipv6` 是**对象**不是字符串。此前这里写成了 `String?`，于是
/// 解码必然抛错，而调用方用 `attempt` 把错误吞掉了 —— 结果就是首页的
/// "动态解析"永远显示"还没有任务"，即使内核里明明有。这类静默失败说明
/// "吞掉解码错误"这个便利是有代价的，因此补了解码测试。
public struct DdnsTaskInfo: Decodable, Sendable, Identifiable {
    public let id: String
    public let credentialId: String
    public let label: String
    public let enabled: Bool
    public let ipv4: DdnsSource?
    public let ipv6: DdnsSource?
    public let ttl: String?
    public let httpInterface: String?
    public let lastRunAt: Date?
    public let lastStatus: String?
    public let lastMessage: String?
    public let lastIpv4: String?
    public let lastIpv6: String?

    /// 这个任务在更新的域名。
    public var domains: [String] {
        let all = (ipv4?.domains ?? []) + (ipv6?.domains ?? [])
        var seen = Set<String>()
        return all.filter { seen.insert($0).inserted }
    }

    public var updatesIPv4: Bool { ipv4?.enable == true }
    public var updatesIPv6: Bool { ipv6?.enable == true }
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

/// 服务商声明的能力。
///
/// 界面据此决定**显示什么**，而不是靠服务商名字去猜：不能列区域的凭据
/// 不该出现"选择区域"这一步，不能签证书的不该被选进 ACME 配置里。
public struct ProviderCapabilities: Decodable, Sendable {
    public let available: Bool
    public let verify: Bool
    public let dynamic: Bool
    public let zoneList: Bool
    public let recordList: Bool
    public let recordCreate: Bool
    public let recordUpdate: Bool
    public let recordDelete: Bool
    public let allRecordTypes: Bool
    public let customTtl: Bool
    public let proxy: Bool
    /// 能否用于 DNS-01 校验（也就是能不能签证书）。
    public let dns01: Bool

    public var canManageRecords: Bool { zoneList && recordList }

    // 手写 init 会抑制合成的 CodingKeys，因此显式声明。
    // 名字用驼峰：解码器开的是 convertFromSnakeCase，它先把 JSON 的
    // zone_list 转成 zoneList，再来匹配这里的键。
    private enum CodingKeys: String, CodingKey {
        case available, verify, dynamic, zoneList, recordList
        case recordCreate, recordUpdate, recordDelete
        case allRecordTypes, customTtl, proxy, dns01
    }

    /// 缺字段一律按 `false` 处理。
    ///
    /// 契约里这些布尔量都是可选的，而合成的解码器会因为**其中一个**缺失
    /// 就让整份服务商目录解不出来 —— 一个界面根本不关心的小字段（比如
    /// `all_record_types`）能把"添加凭据"整页打空。这与 `DdnsTaskInfo`
    /// 那次是同一类错误：严格模型套在宽松契约上。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func flag(_ key: CodingKeys) -> Bool { (try? container.decodeIfPresent(Bool.self, forKey: key)) ?? false }
        available = flag(.available)
        verify = flag(.verify)
        dynamic = flag(.dynamic)
        zoneList = flag(.zoneList)
        recordList = flag(.recordList)
        recordCreate = flag(.recordCreate)
        recordUpdate = flag(.recordUpdate)
        recordDelete = flag(.recordDelete)
        allRecordTypes = flag(.allRecordTypes)
        customTtl = flag(.customTtl)
        proxy = flag(.proxy)
        dns01 = flag(.dns01)
    }
}

/// 凭据表单里的一个字段，由服务商声明。
///
/// 界面因此不需要为每家的 API Key / Secret / Token 写一套表单 ——
/// 加一个服务商不需要改 GUI。
public struct ProviderField: Decodable, Sendable, Identifiable {
    public let key: String
    public let label: String
    public let secret: Bool
    public let required: Bool
    public let placeholder: String?
    public let help: String?
    public let example: String?
    public var id: String { key }
}

public struct Provider: Decodable, Sendable, Identifiable {
    public let name: String
    public let displayName: String
    public let tier: Int?
    public let capabilities: ProviderCapabilities
    public let credentialFields: [ProviderField]
    /// 该服务商创建 API 凭据的控制台页面；内核没登记时为空。
    ///
    /// 可选而不是必填：契约里它不是 required，而且确实存在没有稳定
    /// 凭据页面的服务商。界面据此决定给不给"去配置"按钮 ——
    /// 不要为了让它非空而编一个地址出来。
    public let consoleUrl: String?
    public var id: String { name }

    /// 可直接用系统浏览器打开的凭据页面；没有或不是 https 时为 nil。
    ///
    /// 这里挡一道 https：这个值来自内核（也就是一份外部数据），
    /// 而它会被直接交给系统浏览器打开。http 的凭据页面本就不该存在，
    /// 真出现了也不该由我们替用户打开。
    public var credentialPageURL: URL? {
        guard let consoleUrl, let url = URL(string: consoleUrl),
              url.scheme?.lowercased() == "https", url.host() != nil
        else { return nil }
        return url
    }
}

public struct ProviderList: Decodable, Sendable {
    public let items: [Provider]
}

public struct CredentialVerifyResult: Decodable, Sendable {
    public let ok: Bool
    public let message: String
}

public struct CredentialInfo: Decodable, Sendable, Identifiable {
    public let id: String
    public let provider: String
    public let label: String
    public let capabilities: ProviderCapabilities?
    public let lastVerifiedAt: Date?
    public let lastVerifyOk: Bool?
    public let lastVerifyError: String?

    /// 校验状态的三种呈现：没校验过、通过、失败。
    public var verifyState: String {
        guard lastVerifiedAt != nil else { return "unverified" }
        return lastVerifyOk == true ? "ok" : "failed"
    }
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

/// 一条审计记录：内核做过什么。
///
/// 与任务的区别：任务是"用户发起的一件耗时的事"，审计是"内核做过的任何一次
/// 改动"。用户想弄清"谁把这个设置改了"时要看的是后者。
public struct AuditEntry: Decodable, Sendable, Identifiable {
    public let id: String
    public let ts: Date
    public let action: String
    public let target: String?
    /// `success` 或 `failure`。
    public let result: String
    public let detail: String?
    public let requestId: String?
    public let remote: String?

    public var failed: Bool { result != "success" }
}

public struct AuditList: Decodable, Sendable {
    public let items: [AuditEntry]
    public let nextCursor: String?
}
