import Foundation
import Testing
@testable import ISCSupervisor

struct RuntimeManifestStoreTests {
    @Test func manifestPersistsAndRejectsInsecureRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = try RuntimeArtifact(id: "node-arm64", runtime: "node", version: "22", url: URL(string: "https://example.invalid/node.tar.gz")!, sha256: String(repeating: "a", count: 64), archiveName: "node.tar.gz")
        let store = try RuntimeManifestStore(location: root.appendingPathComponent("runtime-manifest.json"))
        try await store.replace(with: RuntimeManifest(artifacts: [artifact]))
        let restored = try RuntimeManifestStore(location: root.appendingPathComponent("runtime-manifest.json"))
        #expect(await restored.manifest()?.artifacts.first?.id == "node-arm64")
        await #expect(throws: RuntimeManifestStoreError.insecureURL) {
            try await restored.refresh(url: URL(string: "http://example.invalid/manifest.json")!, expectedSHA256: String(repeating: "a", count: 64), loader: FixtureManifestLoader(data: Data()))
        }
    }

    @Test func preferredArtifactSelectsHighestVersion() throws {
        let artifacts = try ["1.9.0", "22.1.0", "22.10.0"].map { version in
            try RuntimeArtifact(id: "node-\(version)", runtime: "node", version: version, url: URL(string: "https://example.invalid/\(version).zip")!, sha256: String(repeating: "b", count: 64), archiveName: "node.zip")
        }
        let catalog = RuntimeCatalog(manifest: RuntimeManifest(artifacts: artifacts))
        #expect(catalog.preferred(runtime: "node")?.version == "22.10.0")
        #expect(catalog.preferred(runtime: "node", version: "1.9.0")?.version == "1.9.0")
    }
}

private struct FixtureManifestLoader: RuntimeDataLoader {
    let data: Data
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
