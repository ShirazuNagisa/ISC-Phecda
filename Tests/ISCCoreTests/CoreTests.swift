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

@Test func organizationArchiveRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let url = directory.appendingPathComponent("services.json")
    let service = PublishedService(name: "家庭媒体", kind: .httpsForward, domains: ["home.example.com"], ddnsID: "ddns", routeID: "route", favorite: true)
    try ServiceArchive(services: [service]).save(to: url)
    #expect(try ServiceArchive.load(from: url).services == [service])
    try FileManager.default.removeItem(at: directory)
}

@Test func identifiersCannotInjectPathOrQuery() { #expect(KernelClient.pathComponent("a/b?x=1") == "a%2Fb%3Fx%3D1") }
