import Foundation
import Testing
@testable import ISCSupervisor

struct OfficialRuntimeManifestTests {
    @Test func includesAllSupportedArm64RuntimeFamilies() throws {
        let manifest = try OfficialRuntimeManifest.make()
        #expect(Set(manifest.artifacts.map(\.runtime)) == ["php", "node", "python", "go", "java"])
        #expect(manifest.artifacts.allSatisfy { $0.url.scheme == "https" && $0.sha256.count == 64 && $0.archiveName.contains(".") })
    }
}
