import Foundation
import CISC

/// All pointers are confined to a synchronous C call and freed on every return path.
public final class KernelClient: Sendable {
    private let lifecycleQueue = DispatchQueue(label: "app.isc.lifecycle", qos: .userInitiated)
    private let requestQueue = DispatchQueue(label: "app.isc.requests", qos: .userInitiated)
    private let eventQueue = DispatchQueue(label: "app.isc.events", qos: .utility)
    public init() {}

    private static func take(_ pointer: UnsafeMutablePointer<CChar>?) throws -> JSONValue {
        guard let pointer else { throw KernelError(code: "empty_reply", message: "The kernel returned no response.") }
        defer { isc_free_string(pointer) }
        return try JSONValue.parse(String(cString: pointer))
    }
    /// 读取内核声明的接口版本。
    ///
    /// 这是**唯一**能在启动内核之前判断"界面与内核是否配对"的地方：
    /// 版本不匹配时启动内核没有意义（每个请求都会 404），而用户看到的
    /// 会是一片空白而不是一句可读的原因。
    static func rawInterfaceVersion() throws -> String { try text(isc_api_version()) }

    private static func text(_ pointer: UnsafeMutablePointer<CChar>?) throws -> String {
        guard let pointer else { throw KernelError(code: "empty_reply", message: "The kernel returned no response.") }
        defer { isc_free_string(pointer) }
        return String(cString: pointer)
    }
    private func perform(on queue: DispatchQueue, _ work: @escaping @Sendable () throws -> JSONValue) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    public func start(dataDirectory: String) async throws -> JSONValue {
        try await perform(on: lifecycleQueue) {
            let version = try Self.rawInterfaceVersion()
            guard version == Self.requiredAPIVersion else {
                throw KernelError(code: "api_version", status: 0,
                    message: "This build of ISC Phecda needs a \(Self.requiredAPIVersion) kernel interface, but the bundled kernel reports \(version). The app and the kernel library must be updated together.")
            }
            return try KernelReply(dataDirectory.withCString { pointer in
                try Self.take(isc_start(UnsafeMutablePointer(mutating: pointer)))
            }).body
        }
    }
    public func stop() async throws -> JSONValue {
        try await perform(on: lifecycleQueue) { try KernelReply(Self.take(isc_stop())).body }
    }
    public func status() async throws -> JSONValue {
        try await perform(on: requestQueue) { try KernelReply(Self.take(isc_status_json())).body }
    }
    public func call(_ method: String, _ path: String, body: JSONValue? = nil) async throws -> KernelReply {
        try await callRaw(method, path, body: body?.text())
    }
    public func callRaw(_ method: String, _ path: String, body payload: String? = nil) async throws -> KernelReply {
        let envelope = try await perform(on: requestQueue) {
            try method.withCString { methodPointer in
                try path.withCString { pathPointer in
                    if let payload {
                        return try payload.withCString { bodyPointer in
                            try Self.take(isc_call(UnsafeMutablePointer(mutating: methodPointer), UnsafeMutablePointer(mutating: pathPointer), UnsafeMutablePointer(mutating: bodyPointer)))
                        }
                    }
                    return try Self.take(isc_call(UnsafeMutablePointer(mutating: methodPointer), UnsafeMutablePointer(mutating: pathPointer), nil))
                }
            }
        }
        return try KernelReply(envelope)
    }
    public func events(since: Int64, timeoutMilliseconds: Int32 = 300) async throws -> JSONValue {
        try await perform(on: eventQueue) { try KernelReply(Self.take(isc_events_json(since, timeoutMilliseconds))).body }
    }
    /// 把一段用户可控的标识符安全地放进 URL 路径。
    ///
    /// 允许 RFC 3986 的 unreserved 集合（字母数字与 `-._~`）而不是只允许
    /// 字母数字：内核的 id 是 base64url 与 UUID，全都含 `-` 或 `_`，
    /// 每个都百分号编码虽然仍然正确，但会让日志与错误信息里的 URL 难以辨认。
    /// `/`、`?`、`#` 依然被编码，因此注入不了路径或查询。
    public static func pathComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
