import Foundation
import Testing
@testable import ISCSupervisor

struct DeploymentLedgerTests {
    @Test func recordsVersionsPersistAndNeverRemoveSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let first = root.appendingPathComponent("releases/1")
        let second = root.appendingPathComponent("releases/2")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("user content".utf8).write(to: source.appendingPathComponent("index.html"))
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        let deploymentID = UUID()
        let ledger = try DeploymentLedger(root: root)
        let one = try await ledger.record(deploymentID: deploymentID, sourceDirectory: source, releaseDirectory: first, runCommand: .serveStatic, localPort: 8080)
        _ = try await ledger.activate(one.id)
        let two = try await ledger.record(deploymentID: deploymentID, sourceDirectory: source, releaseDirectory: second, runCommand: .serveStatic, localPort: 8081)
        _ = try await ledger.activate(two.id)

        let restored = try DeploymentLedger(root: root)
        let snapshot = await restored.snapshot()
        #expect(snapshot.records.map(\.version) == [1, 2])
        #expect(snapshot.currentReleaseID == two.id)
        #expect(String(data: try Data(contentsOf: source.appendingPathComponent("index.html")), encoding: .utf8) == "user content")
        #expect(String(data: try Data(contentsOf: root.appendingPathComponent("current-release")), encoding: .utf8) == second.path)
    }

    @Test func rollbackAtomicallySelectsPreviousRelease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let first = root.appendingPathComponent("generated-a")
        let second = root.appendingPathComponent("generated-b")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        let deploymentID = UUID()
        let ledger = try DeploymentLedger(root: root)
        let one = try await ledger.record(deploymentID: deploymentID, sourceDirectory: source, releaseDirectory: first, runCommand: .serveStatic, localPort: 8080)
        _ = try await ledger.activate(one.id)
        let two = try await ledger.record(deploymentID: deploymentID, sourceDirectory: source, releaseDirectory: second, runCommand: .serveStatic, localPort: 8080)
        _ = try await ledger.activate(two.id)

        let rollback = try await ledger.rollback(deploymentID: deploymentID)
        #expect(rollback.id == one.id)
        let current = await ledger.currentRelease()
        #expect(current?.releaseDirectory == first)
        #expect(String(data: try Data(contentsOf: root.appendingPathComponent("current-release")), encoding: .utf8) == first.path)
    }
}
