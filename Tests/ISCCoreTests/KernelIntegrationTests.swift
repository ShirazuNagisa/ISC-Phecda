import Foundation
import Testing
@testable import ISCCore

/// End-to-end through the real C ABI: the vendored kernel, its HTTP handlers and its SQLite
/// store. The unit tests pin the wire shape; this pins the behaviour that shape exists for —
/// that a deployment's public binding cannot outlive the service it points at.
///
/// `libisc` allows one kernel per process, so this runs the whole flow in a single test and
/// stops the kernel on every exit path.
@Test func kernelOwnsPublishedServicesEndToEnd() async throws {
    let kernel = KernelClient()
    let dataDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("isc-phecda-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dataDirectory) }

    _ = try await kernel.start(dataDirectory: dataDirectory.path)
    do {
        try await exercisePublicServices(kernel, workspace: dataDirectory)
    } catch {
        _ = try? await kernel.stop()
        throw error
    }
    _ = try await kernel.stop()
}

private func exercisePublicServices(_ kernel: KernelClient, workspace: URL) async throws {
    // 1. A project for the deployment to belong to.
    let project = try await kernel.call("POST", "/v1/phecda/projects", body: .object([
        "name": .string("集成测试项目"),
        "purpose": .string("website"),
        "source": .object(["mode": .string("directory"), "value": .string(workspace.path)])
    ])).body
    let projectID = try #require(UUID(uuidString: project["id"].string), "kernel did not return a project id")

    // 2. The kernel is the store of record for published services.
    let service = PublishedService(
        name: "集成测试服务", kind: .httpsForward, domains: ["integration.example.com"],
        ddnsID: "ddns-integration", routeID: "route-integration", favorite: true, order: 3
    )
    let saved = try await kernel.call("PUT", "/v1/public-services", body: PublishedService.kernelCollection([service])).body
    #expect(PublishedService.kernelCollection(from: saved) == [service])

    let listed = try await kernel.call("GET", "/v1/public-services").body
    #expect(PublishedService.kernelCollection(from: listed) == [service])

    // 3. Bind a deployment to it.
    let deploymentID = UUID()
    let bound: JSONValue = .object([
        "id": .string(deploymentID.uuidString),
        "project_id": .string(projectID.uuidString),
        "preset_id": .string("node-auto"),
        "state": .string("running"),
        "local_port": .number(3000),
        "public_service_id": .string(service.id.uuidString)
    ])
    // Compared as UUID values, never as strings: the kernel stores and re-serialises UUIDs in
    // lower case, while Swift's `uuidString` is upper case. Both parse to the same value, and
    // nothing outside this file depends on the spelling.
    let deployment = try await kernel.call("POST", "/v1/phecda/deployments", body: bound).body
    #expect(UUID(uuidString: deployment["public_service_id"].string) == service.id)

    // 4. A state update that omits the binding must not unbind it. The Supervisor's progress
    //    loop rewrites deployment state every few hundred milliseconds; if those writes
    //    cleared the reference, publishing a service and then watching it deploy would
    //    silently unbind it.
    let stateUpdate: JSONValue = .object([
        "id": .string(deploymentID.uuidString),
        "project_id": .string(projectID.uuidString),
        "preset_id": .string("node-auto"),
        "state": .string("building")
    ])
    _ = try await kernel.call("POST", "/v1/phecda/deployments", body: stateUpdate).body
    let afterState = try await kernel.call("GET", "/v1/phecda/deployments/\(deploymentID.uuidString)").body
    #expect(afterState["state"].string == "building")
    #expect(UUID(uuidString: afterState["public_service_id"].string) == service.id)

    // 5. An inconsistent collection is refused as a whole, so the kernel never has to store a
    //    set it cannot keep self-consistent.
    let duplicateDomains: JSONValue = .object(["items": .array([
        service.kernelJSON,
        PublishedService(name: "另一个", kind: .dynamicDomain, domains: ["integration.example.com"]).kernelJSON
    ])])
    do {
        _ = try await kernel.call("PUT", "/v1/public-services", body: duplicateDomains)
        Issue.record("a domain claimed twice must be rejected")
    } catch let error as KernelError {
        // libisc reports the transport-level code; the problem body's finer `invalid_request`
        // travels inside the message.
        #expect(error.code == "bad_request")
        #expect(error.status == 400)
        #expect(error.message.contains("claimed by more than one"))
    }
    // The rejected write left the stored collection untouched.
    let unchanged = try await kernel.call("GET", "/v1/public-services").body
    #expect(PublishedService.kernelCollection(from: unchanged) == [service])

    // 6. The invariant: removing the service clears the deployment's reference in the same
    //    transaction, so the kernel cannot be left pointing at a record that is gone.
    _ = try await kernel.call("PUT", "/v1/public-services", body: PublishedService.kernelCollection([])).body
    let afterRemoval = try await kernel.call("GET", "/v1/phecda/deployments/\(deploymentID.uuidString)").body
    #expect(afterRemoval["public_service_id"] == .null)
    #expect(afterRemoval["state"].string == "building", "clearing the binding must not touch deployment state")

    // 7. And the deployment itself is still intact for a later re-bind.
    let reloaded = try await kernel.call("GET", "/v1/phecda/deployments").body
    #expect(reloaded.items.contains { UUID(uuidString: $0["id"].string) == deploymentID })
}
