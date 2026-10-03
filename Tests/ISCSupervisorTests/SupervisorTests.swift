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

    @Test func installsGeneratedZipIntoVersionedDirectory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let archive = root.appendingPathComponent("runtime.zip")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("fixture runtime".utf8).write(to: source.appendingPathComponent("runtime.txt"))
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", archive.path, "runtime.txt"]
        zip.currentDirectoryURL = source
        try zip.run()
        zip.waitUntilExit()
        #expect(zip.terminationStatus == 0)

        let artifact = try RuntimeArtifact(id: "fixture", runtime: "node", version: "22.1", url: URL(string: "https://fixture.invalid/runtime")!, sha256: String(repeating: "0", count: 64), archiveName: "node.zip")
        let catalog = RuntimeCatalog(manifest: RuntimeManifest(artifacts: [artifact]))
        let install = try RuntimeInstaller().install(runtime: "node", version: "22.1", from: catalog, archive: archive, to: root.appendingPathComponent("installed"))
        #expect(try String(contentsOf: install.appendingPathComponent("runtime.txt"), encoding: .utf8) == "fixture runtime")
        #expect(throws: RuntimeDownloadError.destinationExists) {
            try RuntimeInstaller().install(artifact, archive: archive, to: root.appendingPathComponent("installed"))
        }
    }

    @Test func rejectsUnsafeInstallComponents() throws {
        let archive = URL(fileURLWithPath: "/tmp/unused.zip")
        let artifact = try RuntimeArtifact(id: "fixture", runtime: "../escape", version: "1", url: URL(string: "https://fixture.invalid/runtime")!, sha256: String(repeating: "0", count: 64), archiveName: "runtime.zip")
        #expect(throws: RuntimeDownloadError.invalidInstallPath) {
            try RuntimeInstaller().install(artifact, archive: archive, to: FileManager.default.temporaryDirectory)
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
