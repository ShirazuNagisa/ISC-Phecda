import Foundation
import Testing
@testable import ISCSupervisor

struct SupervisorJobStoreTests {
    @Test func completedStateRestoresFromDisk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let location = root.appendingPathComponent("jobs.json")
        let store = try SupervisorJobStore(location: location)
        let id = await store.submit(SupervisorJob(kind: "fixture")) { update in
            await update(.building, 0.5, "Building fixture")
        }
        var restoredState: SupervisorTaskState?
        for _ in 0..<100 {
            let restored = try SupervisorJobStore(location: location)
            restoredState = await restored.state(for: id)
            if restoredState?.phase == .completed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(restoredState?.phase == .completed)
        #expect(restoredState?.progress == 1)
    }
}
