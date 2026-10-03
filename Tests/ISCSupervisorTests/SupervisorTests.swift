import Foundation
import Testing
@testable import ISCSupervisor

struct SupervisorTests {
    @Test func taskStateRoundTripsAndClampsProgress() throws {
        var state = SupervisorTaskState(kind: "build", progress: 2)
        #expect(state.progress == 1)
        state.update(phase: .building, progress: 0.4, message: "Compiling")
        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(SupervisorTaskState.self, from: data)
        #expect(restored == state)
        #expect(restored.phase == .building)
    }

    @Test func dockerPlannerOnlyPlansAndRejectsPrivilege() throws {
        let planner = DockerPlanner()
        let plan = try planner.plan(source: .image(reference: "nginx:1.27"), name: "web", ports: [8080])
        #expect(plan.arguments == ["run", "--name", "web", "--publish", "8080:8080", "nginx:1.27"])
        #expect(plan.requiresExplicitConfirmation == false)
        #expect(throws: DockerPlanError.unavailablePrivilege("privileged containers")) {
            try planner.plan(source: .command(image: "alpine", arguments: ["--privileged"]), name: "unsafe")
        }
    }

    @Test func downloaderVerifiesInjectedFixtureAndWritesAtomically() async throws {
        let payload = Data("hello".utf8)
        let digest = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        let artifact = try RuntimeArtifact(id: "fixture", runtime: "test", version: "1", url: URL(string: "https://fixture.invalid/runtime")!, sha256: digest, archiveName: "runtime.zip")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("runtime.zip")
        let downloader = RuntimeDownloader(loader: FixtureLoader(data: payload))
        _ = try await downloader.download(artifact, to: destination)
        #expect(try Data(contentsOf: destination) == payload)
    }
}

private struct FixtureLoader: RuntimeDataLoader {
    let data: Data
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}
