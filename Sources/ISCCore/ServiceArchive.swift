import Foundation

public enum ServiceKind: String, Codable, Sendable, CaseIterable { case dynamicDomain, httpsForward }
public struct PublishedService: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var kind: ServiceKind
    public var domains: [String]
    public var ddnsID: String?
    public var routeID: String?
    public var favorite: Bool
    public var order: Int
    public var verifiedAt: Date?
    public var verifiedFingerprint: String?
    public init(id: UUID = UUID(), name: String, kind: ServiceKind, domains: [String], ddnsID: String? = nil, routeID: String? = nil, favorite: Bool = false, order: Int = 0, verifiedAt: Date? = nil, verifiedFingerprint: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.domains = domains; self.ddnsID = ddnsID; self.routeID = routeID; self.favorite = favorite; self.order = order; self.verifiedAt = verifiedAt; self.verifiedFingerprint = verifiedFingerprint
    }
}
/// The pre-kernel archive format.
///
/// Published services now live in ISC-Core (`/v1/public-services`); this type only exists to
/// read a `services.json` written by an earlier build so it can be imported once. It is
/// deliberately read-only: writing the file again would recreate the second source of truth
/// that moving the records into the kernel removed.
public struct ServiceArchive: Codable, Sendable {
    public var version: Int = 1
    public var services: [PublishedService] = []
    public init(services: [PublishedService] = []) { self.services = services }
    public static func load(from url: URL) throws -> ServiceArchive {
        guard FileManager.default.fileExists(atPath: url.path) else { return ServiceArchive() }
        let archive = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard archive.version == 1 else { throw KernelError(code: "archive_version", message: "Unsupported service archive version") }
        return archive
    }
}

/// Refuse replacement when another window/client has edited the collection.
public enum CollectionEdit {
    public static func replacing(id: String, with replacement: JSONValue?, baseline: [JSONValue], current: [JSONValue]) throws -> JSONValue {
        guard baseline == current else { throw KernelError(code: "stale_edit", message: "Configuration changed. Refresh before saving.") }
        var items = current.filter { $0.id != id }
        if let replacement { items.append(replacement) }
        return .object(["items": .array(items)])
    }
}
