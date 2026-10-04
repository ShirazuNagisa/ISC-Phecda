import Foundation
import Testing
@testable import ISCCore

@Test func jsonRoundTrip() throws {
    let value = try JSONValue.parse(#"{"name":"家庭服务","enabled":true,"values":[1,null,"x"]}"#)
    #expect(value["name"].string == "家庭服务")
    #expect(value["enabled"].bool)
    #expect(try JSONValue.parse(value.text()) == value)
}

@Test func errorUsesMachineCode() throws {
    let value = try JSONValue.parse(#"{"ok":false,"code":"conflict","status":409,"error":"状态冲突"}"#)
    do { _ = try KernelReply(value); Issue.record("Expected error") }
    catch let error as KernelError { #expect(error.code == "conflict"); #expect(error.status == 409) }
}

@Test func collectionPreservesOtherItems() throws {
    let a: JSONValue = .object(["id": .string("a")])
    let b: JSONValue = .object(["id": .string("b")])
    let replacement: JSONValue = .object(["id": .string("a"), "name": .string("new")])
    let result = try CollectionEdit.replacing(id: "a", with: replacement, baseline: [a,b], current: [a,b])
    #expect(result.items.contains(b)); #expect(result.items.contains(replacement)); #expect(result.items.count == 2)
}

// Published services live in the kernel now, so the archive is read-only and exists solely to
// import a file written by an earlier build.
@Test func legacyArchiveIsReadableForOneTimeImport() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("services.json")
    let service = PublishedService(name: "家庭媒体", kind: .httpsForward, domains: ["home.example.com"], ddnsID: "ddns", routeID: "route", favorite: true)
    try JSONEncoder().encode(ServiceArchive(services: [service])).write(to: url)
    #expect(try ServiceArchive.load(from: url).services == [service])
    // An absent file is an empty archive, not a failure: there is simply nothing to import.
    #expect(try ServiceArchive.load(from: directory.appendingPathComponent("absent.json")).services.isEmpty)
}

@Test func identifiersCannotInjectPathOrQuery() { #expect(KernelClient.pathComponent("a/b?x=1") == "a%2Fb%3Fx%3D1") }

// MARK: - Kernel wire mapping for published services

private func kernelRow(_ overrides: [String: JSONValue] = [:]) -> JSONValue {
    var fields: [String: JSONValue] = [
        "id": .string("2B7E1B4C-0F3A-4C6E-9A2B-8D5F1C3E7A90"),
        "name": .string("家庭媒体"),
        "kind": .string("httpsForward"),
        "domains": .array([.string("home.example.com")]),
        "favorite": .bool(true),
        "order": .number(2)
    ]
    for (key, value) in overrides { fields[key] = value }
    return .object(fields)
}

@Test func kernelDecodeMapsEveryField() throws {
    let verified = Date(timeIntervalSince1970: 1_700_000_000)
    let row = kernelRow([
        "ddns_id": .string("ddns-1"), "route_id": .string("route-1"),
        "verified_at": .string(KernelTimestamp.text(verified)),
        "verified_fingerprint": .string("fp-1")
    ])
    let service = try #require(PublishedService(kernel: row))
    #expect(service.kind == .httpsForward)
    #expect(service.domains == ["home.example.com"])
    #expect(service.ddnsID == "ddns-1")
    #expect(service.routeID == "route-1")
    #expect(service.favorite)
    #expect(service.order == 2)
    #expect(service.verifiedAt == verified)
    #expect(service.verifiedFingerprint == "fp-1")
}

// A record this build cannot represent is skipped rather than turned into a placeholder the
// user could then write back into the kernel.
@Test func kernelDecodeRejectsRecordsThisBuildCannotRepresent() {
    #expect(PublishedService(kernel: kernelRow(["kind": .string("carrier-pigeon")])) == nil)
    #expect(PublishedService(kernel: kernelRow(["id": .string("not-a-uuid")])) == nil)
}

@Test func kernelEncodeOmitsAbsentOptionalsButAlwaysSendsFavoriteAndOrder() throws {
    let original = PublishedService(name: "站点", kind: .dynamicDomain, domains: ["a.example.com", "b.example.com"], ddnsID: "ddns-9", order: 1)
    let encoded = original.kernelJSON
    #expect(encoded["ddns_id"].string == "ddns-9")
    // Absent rather than null: the kernel reads a null as "clear this on purpose".
    #expect(encoded.object["route_id"] == nil)
    #expect(encoded.object["verified_at"] == nil)
    #expect(encoded["favorite"] == .bool(false))
    #expect(encoded["order"] == .number(1))
    #expect(try #require(PublishedService(kernel: encoded)) == original)
}

@Test func kernelCollectionEnvelopeRoundTripsAndSkipsUnknownRecords() {
    let a = PublishedService(name: "a", kind: .dynamicDomain, domains: ["a.example.com"])
    let b = PublishedService(name: "b", kind: .httpsForward, domains: ["b.example.com"])
    let payload = PublishedService.kernelCollection([a, b])
    #expect(payload["items"].array.count == 2)
    #expect(PublishedService.kernelCollection(from: payload) == [a, b])

    let mixed: JSONValue = .object(["items": .array([a.kernelJSON, .object(["id": .string("bad")])])])
    #expect(PublishedService.kernelCollection(from: mixed) == [a])
    #expect(PublishedService.kernelCollection(from: .null).isEmpty)
}

// The kernel writes time.RFC3339Nano, which drops the fractional part when it is zero.
@Test func kernelTimestampAcceptsBothShapesTheKernelCanEmit() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(KernelTimestamp.date(KernelTimestamp.text(date)) == date)
    #expect(KernelTimestamp.date("2023-11-14T22:13:20Z") == date)
    #expect(KernelTimestamp.date("2023-11-14T22:13:20.000000001Z") != nil)
    #expect(KernelTimestamp.date("") == nil)
    #expect(KernelTimestamp.date("not a date") == nil)
}
