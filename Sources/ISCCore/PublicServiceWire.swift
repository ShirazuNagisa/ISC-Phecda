import Foundation

/// Published services are stored by ISC-Core (`/v1/public-services`), which is what makes a
/// deployment's `public_service_id` resolvable — the kernel clears that reference in the same
/// transaction that removes a service, so it can never dangle.
///
/// The rest of the app speaks to the kernel in JSON, so the mapping between the kernel's
/// snake_case contract and the UI model lives here and nowhere else. Nothing else needs to
/// know the wire names.
public extension PublishedService {
    /// Decodes one record from the kernel collection.
    ///
    /// Returns nil for a record this build cannot represent (unknown `kind`, unusable `id`)
    /// rather than inventing a placeholder the user could then edit into the kernel.
    init?(kernel row: JSONValue) {
        guard let id = UUID(uuidString: row["id"].string),
              let kind = ServiceKind(rawValue: row["kind"].string) else { return nil }
        self.init(
            id: id,
            name: row["name"].string,
            kind: kind,
            domains: row["domains"].array.map(\.string),
            ddnsID: row["ddns_id"].string.nonEmpty,
            routeID: row["route_id"].string.nonEmpty,
            favorite: row["favorite"].bool,
            order: Int(row["order"].number),
            verifiedAt: KernelTimestamp.date(row["verified_at"].string),
            verifiedFingerprint: row["verified_fingerprint"].string.nonEmpty
        )
    }

    /// Encodes one record in the kernel's shape.
    ///
    /// Optional fields are omitted rather than sent as null: the kernel's own writers treat
    /// "absent" as "unchanged", and an explicit null would read as a deliberate clear.
    var kernelJSON: JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(id.uuidString),
            "name": .string(name),
            "kind": .string(kind.rawValue),
            "domains": .array(domains.map { .string($0) }),
            "favorite": .bool(favorite),
            "order": .number(Double(order))
        ]
        if let ddnsID { fields["ddns_id"] = .string(ddnsID) }
        if let routeID { fields["route_id"] = .string(routeID) }
        if let verifiedAt { fields["verified_at"] = .string(KernelTimestamp.text(verifiedAt)) }
        if let verifiedFingerprint { fields["verified_fingerprint"] = .string(verifiedFingerprint) }
        return .object(fields)
    }

    /// The `{"items": [...]}` envelope both `GET` and `PUT /v1/public-services` use.
    static func kernelCollection(_ services: [PublishedService]) -> JSONValue {
        .object(["items": .array(services.map(\.kernelJSON))])
    }

    /// Decodes a collection response, skipping records this build cannot represent.
    static func kernelCollection(from reply: JSONValue) -> [PublishedService] {
        reply.items.compactMap(PublishedService.init(kernel:))
    }
}

/// The kernel exchanges times as RFC 3339 in UTC, with nanoseconds only when they are
/// non-zero (`time.RFC3339Nano`). Foundation's two ISO-8601 shapes disagree about fractional
/// seconds, so both directions accept either one.
///
/// Formatters are built per call on purpose: they are not `Sendable`, and a published-service
/// collection is a handful of records, so caching one would trade a real concurrency hazard
/// for no measurable gain.
public enum KernelTimestamp {
    public static func text(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    public static func date(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: raw) { return parsed }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

private extension String {
    /// An absent optional field arrives as an empty string through `JSONValue`.
    var nonEmpty: String? { isEmpty ? nil : self }
}
