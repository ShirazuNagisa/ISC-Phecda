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
            let version = try Self.text(isc_api_version())
            guard version == "v1" else { throw KernelError(code: "api_version", message: "Unsupported kernel interface: \(version)") }
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
    public static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
}
