// APNs 推送的界面侧入口。真正的实现是**闭源**库 libiscap.dylib（ISC-Ap），
// 它在发行版里以 Vendor/AP 的形态随包提供 —— 源码仓库里没有它。
//
// # 这个文件为什么在 Sources/CAp/，却不是 SwiftPM 的 target
//
// 它必须由**应用 target**编译，因为"能不能 import CAp"取决于应用 target 的
// SWIFT_INCLUDE_PATHS，而那条设置只在 Release 下由 Configs/Release.xcconfig
// 可选地提供。SwiftPM 的 target 有自己的编译标志，应用 target 的设置传不进去：
// 做成包的 target 的话，Release 里也会走"没有模块"那条分支，于是推送永远不可用 ——
// 而且看起来一切正常。
//
// 目录名沿用内核那一层的命名（CISC ← Vendor/ISC），这里是 CAp ← Vendor/AP。
//
// # 两种构建，同一份源码
//
//   Vendor/AP 在    → canImport(CAp) 为真，调用真实 C ABI；
//   Vendor/AP 不在  → 同样的 API，但每个操作都返回 .unavailable
//                     （"此构建不含推送能力"）。
//
// 后者不是权宜之计，而是需求本身：从 GitHub 拿源码自己编译的人拿不到这个库，
// 编出来的应用没有推送能力，但**照样能构建、能运行**。
//
// # 凭据从哪来
//
// Key ID / Team ID / Topic 是**配置**，写成默认值（它们不是秘密：Key ID 出现在
// 每一个 JWT 头里）。私钥路径由调用方传入 —— 它指向用户机器上的 .p8，
// 库里一个字都不该写死。

#if canImport(CAp)
import CAp
#endif
import Foundation

// MARK: - 错误

/// 推送失败的原因。
///
/// 失败是一种**结果**而不是异常：Apple 回的那句话（`BadDeviceToken`、
/// `ExpiredProviderToken`、`TopicDisallowed`…）是排查时唯一有用的东西，
/// 转述成错误码就丢了，抛掉它更是。
public enum ApnsError: Error, Equatable, Sendable {
    /// 这个构建里没有推送能力 —— 源码自编译的情形。
    case unavailable
    /// 库的 C ABI 版本与这一层期望的不一致。
    case versionMismatch(found: String)
    /// 库或 Apple 拒绝了这次调用（原样带上对方的说明）。
    case rejected(reason: String)
    /// 库返回了看不懂的东西 —— 只可能是版本错配或库被换掉了。
    case malformedResponse(String)
}

extension ApnsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "此构建不含推送能力"
        case .versionMismatch(let found):
            "推送库的接口版本是 \(found)，这一层只认 \(ApnsService.expectedAPIVersion)"
        case .rejected(let reason):
            "推送失败：\(reason)"
        case .malformedResponse(let raw):
            "推送库返回了无法解析的内容：\(raw)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .unavailable:
            "这个构建没有随包提供闭源推送库 libiscap（Vendor/AP）。从源码自行编译的版本本就没有推送能力，这不是需要修复的问题。"
        case .versionMismatch:
            "重新用配套的 ISC-Ap 跑一次 Scripts/vendor-ap.sh，把 Vendor/AP 换成本层认识的版本。"
        case .rejected, .malformedResponse:
            nil
        }
    }
}

// MARK: - 配置

/// 投递一条通知所需的全部配置。
public nonisolated struct ApnsConfiguration: Sendable, Equatable {
    /// Apple 后台那把钥匙的标识。不是秘密 —— 它会出现在每一个 JWT 头里。
    public static let defaultKeyID = "6P3DR8XSC2"
    /// 开发者团队 ID。不是秘密 —— 每个签名过的应用里都有。
    public static let defaultTeamID = "5Q2A46685M"
    /// APNs 的 topic。
    ///
    /// ⚠️ **是 Mizar 而不是 Phecda。** topic 必须是"收到通知后把它显示出来的
    /// 那个应用"—— Phecda 跑在 Mac 上、不发通知给自己，手机上的 Mizar 才是
    /// 接收方。写成 app.isc.phecda 会返回 `TopicDisallowed`，而那个错误不会
    /// 提示"是你选错了 App"。
    public static let defaultTopic = "app.isc.mizar"

    /// .p8 私钥的路径。**由调用方传入** —— 库里不写死任何路径。
    public var keyPath: String
    public var keyID: String
    public var teamID: String
    public var topic: String
    /// 打正式环境还是沙箱环境。
    ///
    /// 没有默认值，必须显式选：用错环境的症状是 `BadDeviceToken`，而设备
    /// 令牌本身完全正常 —— 只是它属于另一个环境。这种错误不该由默认值决定。
    /// App Store 版本收到的令牌属于正式环境。
    public var production: Bool

    public init(keyPath: String,
                production: Bool,
                keyID: String = ApnsConfiguration.defaultKeyID,
                teamID: String = ApnsConfiguration.defaultTeamID,
                topic: String = ApnsConfiguration.defaultTopic) {
        self.keyPath = keyPath
        self.production = production
        self.keyID = keyID
        self.teamID = teamID
        self.topic = topic
    }
}

// MARK: - 服务

/// 推送服务的**无状态**门面。
///
/// 状态（凭据、供应商令牌）都在闭源库那一侧：C ABI 本来就是这么定的
/// （`iscap_configure` 配置一次，`iscap_push` 复用）。这里再存一份只会有
/// 两份真相，而它们迟早不一致。
public nonisolated enum ApnsService {
    /// 这一层认识的 C ABI 版本。与内核的 `isc_api_version` 是同一个思路：
    /// 版本对不上时明确报错，而不是让调用方在运行期撞上难以理解的失败。
    public static let expectedAPIVersion = "v1"

    /// 这个构建有没有推送能力。
    public static var isAvailable: Bool {
        #if canImport(CAp)
        true
        #else
        false
        #endif
    }

    /// 库自报的 C ABI 版本；这个构建没有库时是 nil。
    public static var apiVersion: String? {
        #if canImport(CAp)
        iscapTakeString(iscap_api_version())
        #else
        nil
        #endif
    }

    /// 配置凭据。投递之前必须调用一次。
    ///
    /// 不读私钥文件 —— 真正的读取推迟到第一次投递（库侧如此设计），所以
    /// 路径写错时这里会成功、第一次推送才失败。文档写在这里免得后来人
    /// 以为"配置成功"等于"密钥没问题"。
    @discardableResult
    public static func configure(_ configuration: ApnsConfiguration) -> Result<Void, ApnsError> {
        #if canImport(CAp)
        let version = iscapTakeString(iscap_api_version())
        guard version == expectedAPIVersion else {
            return .failure(.versionMismatch(found: version))
        }
        let status = withCStrings(configuration.keyPath,
                                  configuration.keyID,
                                  configuration.teamID,
                                  configuration.topic) { keyPath, keyID, teamID, topic in
            iscap_configure(keyPath, keyID, teamID, topic, configuration.production ? 1 : 0)
        }
        guard status == 0 else {
            return .failure(.rejected(reason: iscapTakeString(iscap_last_error())))
        }
        return .success(())
        #else
        _ = configuration
        return .failure(.unavailable)
        #endif
    }

    /// 投递一条通知。
    ///
    /// `@concurrent`：库侧的投递是**阻塞**的（最多 30 秒的 HTTP 往返），
    /// 不能占着主 actor 跑 —— 那会让界面卡到超时为止。
    @discardableResult
    @concurrent
    public static func push(deviceToken: String,
                            title: String,
                            body: String,
                            collapseID: String = "") async -> Result<Void, ApnsError> {
        #if canImport(CAp)
        let raw = withCStrings(deviceToken, title, body, collapseID) { token, title, body, collapse in
            iscapTakeString(iscap_push(token, title, body, collapse))
        }
        guard let data = raw.data(using: .utf8),
              let reply = try? JSONDecoder().decode(PushReply.self, from: data) else {
            return .failure(.malformedResponse(raw))
        }
        // 库用 JSON 而不是错误码回话，就是为了让 Apple 那句 reason 原样传上来。
        return reply.ok ? .success(()) : .failure(.rejected(reason: reply.error))
        #else
        _ = (deviceToken, title, body, collapseID)
        return .failure(.unavailable)
        #endif
    }
}

#if canImport(CAp)

/// `iscap_push` 的回话。
///
/// `nonisolated`：应用 target 的默认隔离是 MainActor（工程里的
/// `SWIFT_DEFAULT_ACTOR_ISOLATION`），不写的话这个 struct 连同它的
/// `Decodable` 一致性都会是 MainActor 的 —— 而在 `@concurrent` 的 push 里
/// 用不了它（"main actor-isolated conformance of 'PushReply' to 'Decodable'
/// cannot be used in @concurrent context"）。这个类型只是一次 JSON 解码的
/// 形状，与 actor 无关。
private nonisolated struct PushReply: Decodable {
    let ok: Bool
    let error: String
}

/// 取走库返回的 C 字符串并**释放它**。
///
/// 这块内存是 C 侧 `malloc` 出来的：不调用 `iscap_free_string` 就是每次
/// 推送泄漏一个字符串。`defer` 放在这里而不是每个调用点，是因为"忘记释放"
/// 不会报错、只会慢慢涨。
private nonisolated func iscapTakeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
    guard let pointer else { return "" }
    defer { iscap_free_string(pointer) }
    return String(cString: pointer)
}

/// 把四个 Swift 字符串借给库的 `char *` 参数。
///
/// # 为什么需要这一层
///
/// cgo 生成的头文件把参数写成 `char *` 而不是 `const char *`
/// （见 Vendor/AP/libiscap.h），于是 Swift 要求**可变**指针，而 `String`
/// 只能隐式转成不可变的那种。库那一侧只读这些参数（Go 里是 `C.GoString`），
/// 所以去掉 const 是安全的 —— 但"安全"要靠这里说清楚，因为类型系统不再管了。
///
/// 借来的指针只在这一层闭包执行期间有效，库必须当场把内容拷走：它确实是
/// 这么做的（`C.GoString` 立刻复制）。
private nonisolated func withCStrings<R>(
    _ first: String,
    _ second: String,
    _ third: String,
    _ fourth: String,
    _ body: (UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>,
             UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>) -> R
) -> R {
    var a = Array(first.utf8CString)
    var b = Array(second.utf8CString)
    var c = Array(third.utf8CString)
    var d = Array(fourth.utf8CString)
    // utf8CString 至少含结尾那个 NUL，所以 baseAddress 不可能是 nil ——
    // 下面四个 `!` 陈述的就是这件事。
    return a.withUnsafeMutableBufferPointer { pa in
        b.withUnsafeMutableBufferPointer { pb in
            c.withUnsafeMutableBufferPointer { pc in
                d.withUnsafeMutableBufferPointer { pd in
                    body(pa.baseAddress!, pb.baseAddress!, pc.baseAddress!, pd.baseAddress!)
                }
            }
        }
    }
}

#endif
