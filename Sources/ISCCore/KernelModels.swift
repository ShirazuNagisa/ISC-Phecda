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

    /// GPU 占用。nil 表示**没有可采样的 GPU**（无头机器、虚拟机），
    /// 与"占用为 0"是两件事。
    ///
    /// 注意它是**设备级**的，不是 Phecda 自己的：macOS 没有按进程归因
    /// GPU 的途径。界面必须标注"整机 GPU"，否则用户会把它读成
    /// "Phecda 用了这么多 GPU" —— 而那正是 footprint 要消灭的误导。
    public let gpu: GpuMetrics?

    public var isSupported: Bool { backend != "unsupported" }
    public var memoryFraction: Double {
        memoryTotalBytes > 0 ? Double(memoryUsedBytes) / Double(memoryTotalBytes) : 0
    }
}

/// GPU 的占用。
public struct GpuMetrics: Decodable, Sendable {
    public let backend: String
    public let name: String?
    public let utilizationPercent: Double?

    /// 三态里的第一态：这个平台没有实现 GPU 采样。
    /// `utilizationPercent == nil` 而 `isSupported` 为真是第二态（这次没读到）。
    public var isSupported: Bool { backend != "unsupported" }
}

/// **内核自己 + 它托管的站点**的合计占用。
///
/// # 它与 HostMetrics 是两个问题
///
/// `HostMetrics` 是整台机器，这个是"Phecda 占了多少"。界面拿它当主数字
/// 之后，用户才不会在机器变卡时先去怀疑 Phecda —— 或者反过来，以为
/// 它什么都没占。
///
/// # 三条读法上的边界（内核侧的口径见 Core 的 D39）
///
///   - 含站点的**进程树**（`npm start` 会再 fork 出 node）；
///   - `memoryBytes` 是各进程 RSS 之和，是一个上界；
///   - `cpuPercent` 是各进程之和，**可能超过 100** —— 每个进程的 100%
///     指"一个核跑满"，所以画进度条前必须钳到 0...1。
///
/// # GPU 不在里面
///
/// 按进程归因 GPU 在 macOS 上做不到，硬塞进来就是把设备数字冒充成
/// Phecda 的数字。GPU 看 `HostMetrics.gpu`，并在界面上标注"整机"。
public struct FootprintMetrics: Decodable, Sendable {
    public let at: Date?
    public let cpuPercent: Double
    public let memoryBytes: Int
    /// 仅在 `netBackend` 是后端名时才有值：另外两种状态（不支持 / 没读到）
    /// 下内核**不发**这两个字段，界面据此显示"—"而不是 0。
    public let netRxBytesPerSec: Double?
    public let netTxBytesPerSec: Double?
    /// 网络数字的来源，三态：后端名（如 `darwin-nettop`）/ `unsupported` /
    /// `unavailable`。三者必须分开显示：把"没读到"说成 0 会让用户以为
    /// Phecda 不占网络。
    public let netBackend: String
    /// 参与合计的进程数，用于解释"这个数字算了几个人"。
    public let processes: Int

    /// 网络速率是否可用。
    public var hasNetwork: Bool { netRxBytesPerSec != nil && netTxBytesPerSec != nil }

    /// 进度条用的占比。
    ///
    /// 钳到 1 是必须的：多核机器上 CPU 之和会超过 100%，不钳的话
    /// 进度条会画到框外面去。
    public var cpuFraction: Double { min(1, max(0, cpuPercent / 100)) }
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
    /// 内核自身 + 站点的合计。旧内核不发这个字段，因此是可选的。
    public let footprint: FootprintMetrics?
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
    /// Cloudflare 隧道。见 REST 契约里 Settings.tunnel_enabled 的说明：
    /// 它解决的是直连模型解决不了的那类网络（CGNAT 家宽、校园网），
    /// 与 proxyEnabled 是**叠加**关系 —— 隧道把流量送到本机反代上。
    public var tunnelEnabled: Bool?
    /// cloudflared 的路径；留空则自动寻找。
    public var tunnelBinary: String?
    public var acmeEmail: String?
    public var acmeDirectory: String?
    public var acmeDnsCredentialId: String?

    /// 公网访问：在**用户自己的**域名下建一条随机子域名。
    public var remotePublicEnabled: Bool?
    /// 子域名挂在哪个域名下。
    ///
    /// 用户只回答这一个问题：哪把凭据、哪个区域由这个域名唯一决定，
    /// 内核自己反查得出来。
    public var remotePublicDomain: String?

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

// MARK: - 远程访问（ISC Mizar）

/// 远程监听的运行状态。
///
/// `state` 用 String 而不是 enum：内核多一个取值时，界面应该显示它而不是
/// 解码失败 —— 这一条对整个文件都成立，不只是这里。
public struct RemoteStatus: Decodable, Sendable {
    public let state: String
    public let enabled: Bool
    public let port: Int
    public let listening: Bool?
    /// 客户端可以尝试的候选地址（含端口），顺序即建议的尝试顺序。
    public let addresses: [String]?
    public let hostname: String?
    public let spkiSha256: String?
    /// 公钥指纹短码，形如 `A1B2-C3D4`，供两端人工核对。
    public let fingerprintShort: String?
    public let tlsNotAfter: Date?
    public let deviceCount: Int
    public let pairing: RemotePairingSession?
    public let apnsConfigured: Bool?
    public let apnsStatus: ApnsStatus?
    public let notificationsEnabled: Bool
    /// 最近一次监听失败的原因；空串表示正常。
    public let lastError: String?

    public let `public`: RemotePublicStatus?

    public var isRunning: Bool { state == "running" }
    public var hasError: Bool { !(lastError ?? "").isEmpty }
}

/// 公网访问的状态。
///
/// 与监听分开描述，因为两者解决的是**不同的问题**：
///
///   - **监听**决定"内核在这个端口上听不听、听在哪个地址上"。它一旦开着，
///     凡是能路由到这台机器的设备都能敲到这个端口（这也是它默认关闭、
///     端口可改的原因）；
///   - **公网访问**决定"这台机器在公网上的名字与证书"。它建一条指向本机
///     公网地址的子域名，并签一张受信任的证书 —— 手机因此能在**任何**
///     网络上连上，而不只是在同一局域网里。
///
/// 换句话说：局域网是候选地址之一，不是能力边界。
public struct RemotePublicStatus: Decodable, Sendable {
    public let enabled: Bool
    /// 凭据与区域都配好了、可以开始同步。
    ///
    /// 与 `enabled` 分开：勾了开关但没选域名时，用户需要知道差的是
    /// 哪一步，而不是看到一个"已开启"却什么都没发生。
    public let ready: Bool
    /// 子域名挂在哪个域名下（用户选的）。
    public let domain: String?
    /// 完整的子域名。
    public let host: String?
    /// "记录类型 → 地址值"。只含内核自己写的那几条。
    public let records: [String: String]?
    public let lastCheck: Check?

    public struct Check: Decodable, Sendable {
        public let at: Date
        public let verdict: String
        public let family: String?
        public let detail: String?

        public var isReachable: Bool { verdict == "reachable" }
        public var isUnknown: Bool { verdict == "unknown" }
    }

    public var ipv6: String? { records?["AAAA"] }
    public var ipv4: String? { records?["A"] }
}

/// 一个可以承载公网子域名的域名。
public struct RemotePublicDomain: Decodable, Sendable, Identifiable {
    public let domain: String
    public let provider: String

    public var id: String { domain }
}

/// APNs 凭据的状态（只有非敏感字段）。
public struct ApnsStatus: Decodable, Sendable {
    public let configured: Bool
    public let teamId: String?
    public let keyId: String?
    public let bundleId: String?
}

/// 保存 APNs 凭据的请求体。
public struct ApnsCredentials: Encodable, Sendable {
    public var teamId: String
    public var keyId: String
    public var bundleId: String
    public var privateKey: String

    public init(teamId: String, keyId: String, bundleId: String, privateKey: String) {
        self.teamId = teamId
        self.keyId = keyId
        self.bundleId = bundleId
        self.privateKey = privateKey
    }
}

/// 「做了一件事」的通用结果。
public struct ServiceActionResult: Decodable, Sendable {
    public let ok: Bool
    public let message: String?

    public init(ok: Bool, message: String?) {
        self.ok = ok
        self.message = message
    }
}

/// 一次配对会话。
public struct RemotePairingSession: Decodable, Sendable, Identifiable {
    public let id: String
    public let role: String
    public let label: String?
    /// 证书公钥指纹的短形式。
    ///
    /// 界面不再显示它 —— 指纹当初要"两端人工比一比"，正是因为六位码
    /// 不携带任何身份信息。二维码与配对链接里装着指纹，核对是内建的。
    /// 留着这个字段是因为它仍在契约里（CLI 会打印它）。
    public let fingerprintShort: String
    public let spkiSha256: String
    /// 候选地址（含端口）。界面不再逐条列出 —— 二维码与链接里都有。
    public let addresses: [String]
    public let expiresAt: Date
    /// 二维码里要编码的原文。**由内核生成**，界面只负责渲染成像素。
    public let qrPayload: String
    /// 载荷的**可复制**形式（`isc-remote://pair?d=…`）。
    ///
    /// 给"新设备没法扫码"准备的：点复制、发给自己、在新设备上粘一次。
    /// 它由**内核**生成 —— 链接格式是契约，让 GUI 自己拼一遍意味着
    /// 两个实现，而它们会漂移，症状是"某个版本的 App 粘不进去"。
    public let qrLink: String?
}

/// 一台已配对的远程设备。
public struct RemoteDevice: Decodable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let role: String
    /// 派生令牌的来源设备；空串表示直接配对而来。
    public let parentDeviceId: String?
    public let platform: String?
    public let model: String?
    public let osVersion: String?
    public let appVersion: String?
    public let notificationsEnabled: Bool
    public let createdAt: Date?
    public let updatedAt: Date?
    public let lastSeenAt: Date?
    public let lastSeenIp: String?
    public let revokedAt: Date?

    public var revoked: Bool { revokedAt != nil }
    public var isDerived: Bool { !(parentDeviceId ?? "").isEmpty }
}

public struct RemoteDeviceList: Decodable, Sendable {
    public let items: [RemoteDevice]
}

/// 开配对会话的请求体。
public struct RemotePairingRequest: Encodable, Sendable {
    public var role: String
    public var label: String?

    public init(role: String, label: String?) {
        self.role = role
        self.label = label
    }
}

/// 改远程访问设置的请求体（字段留 nil 表示不改）。
public struct RemoteSettingsPatch: Encodable, Sendable {
    public var enabled: Bool?
    public var port: Int?
    public var notificationsEnabled: Bool?

    // 必须显式声明：省值的成员初始化器默认是 internal，而界面在另一个 target 里。
    public init(enabled: Bool? = nil, port: Int? = nil, notificationsEnabled: Bool? = nil) {
        self.enabled = enabled
        self.port = port
        self.notificationsEnabled = notificationsEnabled
    }
}

/// 改一台设备的请求体（字段留 nil 表示不改）。
public struct RemoteDevicePatch: Encodable, Sendable {
    public var label: String?
    public var role: String?
    public var notificationsEnabled: Bool?

    public init(label: String? = nil, role: String? = nil, notificationsEnabled: Bool? = nil) {
        self.label = label
        self.role = role
        self.notificationsEnabled = notificationsEnabled
    }
}


// MARK: - Cloudflare 隧道

/// 隧道的运行状态。
///
/// `state` 有六种取值而不是一个布尔量：用户真正需要知道的是**卡在哪一步**，
/// 而"没开""缺 cloudflared""缺授权""连不上"要采取的动作完全不同。
/// 只把它当开关读的界面会把后四种混成"开着但没用"。
public struct TunnelStatus: Decodable, Sendable {
    public let enabled: Bool
    public let state: String
    public let name: String
    public let id: String?
    public let hostname: String?
    public let connections: Int
    public let binary: String?
    public let proxyPort: Int
    public let lastError: String?
    public let logTail: [String]?

    /// 已经连上 Cloudflare 边缘，可以承载流量。
    public var isRunning: Bool { state == "running" }

    /// 是否卡住了（需要用户做点什么才能跑起来）。
    ///
    /// 只回答"卡没卡住"，**不回答"卡在哪"** —— 后者是要显示给用户看的话，
    /// 而文案属于界面层（这一层没有 tr）。
    public var isBlocked: Bool {
        state == "no_binary" || state == "no_account" || state == "failed"
    }
}


// MARK: - 公网可达性

/// 一个域名最近一次的公网可达性检查结果。
public struct ReachabilityItem: Decodable, Sendable, Identifiable {
    public let appId: String
    public let name: String
    public let domain: String
    public let ok: Bool
    public let statusCode: Int?
    public let latencyMs: Int?
    public let checkedAt: Date?
    public let error: String?
    /// 这次检查是否真的走了公网路径。
    ///
    /// 隧道模式下为真 —— 请求会出机器、到 Cloudflare 边缘、再顺着隧道
    /// 回来，途经的每一段都是公网用户会经过的。没有隧道时走 NAT 发夹，
    /// 运营商放不放行都会"成功"，因此**不能**当成公网可达的证据。
    public let trustworthy: Bool
    /// 连续失败次数。单次失败通常只是网络抖动。
    public let consecutiveFailures: Int

    public var id: String { domain }

    /// 是否值得当成"坏了"来显示。
    ///
    /// 单次失败不报：网络抖动、Cloudflare 边缘切换都会造成一次失败，
    /// 每次都标红会让用户很快学会忽略这个提示 —— 那比不提示更糟。
    public var isFailing: Bool { !ok && consecutiveFailures >= 2 }
}

public struct ReachabilityList: Decodable, Sendable {
    public let items: [ReachabilityItem]
}
