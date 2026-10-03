import Foundation
import Testing
@testable import ISCSupervisor

struct SupervisorServiceTests {
    @Test(arguments: SupervisorServiceRequest.Command.allProtocolCommands)
    func requestRoundTrips(command: SupervisorServiceRequest.Command) throws {
        let plan = try DeploymentPlan(workspace: URL(fileURLWithPath: "/tmp/fixture"), runCommand: .serveStatic, localPort: 8080)
        let request = SupervisorServiceRequest(requestID: "client-1", command: command, plan: command == .submit ? plan : nil, deploymentID: command == .cancel || command == .rollback ? plan.id : nil)
        let encoded = try JSONEncoder().encode(request)
        #expect(try SupervisorServiceCodec.decodeRequest(encoded) == request)
    }

    @Test func responseRoundTripsWithoutEmbeddedNewlines() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let state = SupervisorTaskState(kind: "deployment", message: "line one\nline two", updatedAt: date)
        let response = SupervisorServiceResponse(requestID: "list", jobs: [state], ledger: DeploymentLedgerSnapshot())
        let encoded = try SupervisorServiceCodec.encodeResponse(response)
        #expect(!encoded.contains(0x0A))
        #expect(try SupervisorServiceCodec.decodeResponse(encoded) == response)
        let failure = SupervisorServiceResponse(requestID: "bad", error: SupervisorServiceError(code: "invalid_request", message: "Invalid JSON"))
        #expect(try SupervisorServiceCodec.decodeResponse(SupervisorServiceCodec.encodeResponse(failure)) == failure)
        #expect(!failure.ok)
    }

    @Test func malformedRequestsDoNotPreventSubsequentPingAndList() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try SupervisorService(stateDirectory: directory)
        for text in ["not JSON", "{\"command\":\"shell\"}", "{\"command\":\"cancel\",\"deploymentID\":\"not-a-uuid\"}"] {
            let response = await service.handleLine(Data(text.utf8))
            #expect(!response.ok)
            #expect(response.error?.code == "invalid_request")
        }
        let ping = await service.handleLine(Data("{\"command\":\"ping\",\"requestID\":\"alive\"}".utf8))
        #expect(ping.ok)
        #expect(ping.requestID == "alive")
        let list = await service.handle(SupervisorServiceRequest(command: .list))
        #expect(list.ok)
        #expect(list.jobs?.isEmpty == true)
        #expect(list.ledger?.records.isEmpty == true)
    }

    @Test func missingPayloadsAndUnknownIDsReturnErrors() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try SupervisorService(stateDirectory: directory)
        for command in [SupervisorServiceRequest.Command.submit, .cancel, .rollback] {
            let response = await service.handle(SupervisorServiceRequest(requestID: "missing", command: command))
            #expect(response.error?.code == "invalid_request")
            #expect(response.requestID == "missing")
        }
        for command in [SupervisorServiceRequest.Command.cancel, .rollback] {
            let response = await service.handle(SupervisorServiceRequest(command: command, deploymentID: UUID()))
            #expect(response.error?.code == "unknown_deployment")
        }
    }

    @Test func decodedInvalidPlansAreRejectedBeforeSubmission() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try SupervisorService(stateDirectory: directory)
        let id = UUID()
        for (workspace, port) in [("file:///tmp/fixture", 0), ("https://fixture.invalid/workspace", 8080)] {
            let json = """
            {"command":"submit","requestID":"invalid","plan":{"id":"\(id)","workspace":"\(workspace)","installCommands":[],"runCommand":"serveStatic","localPort":\(port)}}
            """
            let response = await service.handleLine(Data(json.utf8))
            #expect(response.error?.code == "invalid_plan")
            #expect(response.requestID == "invalid")
        }
        let list = await service.handle(SupervisorServiceRequest(command: .list))
        #expect(list.jobs?.isEmpty == true)
    }

    @Test func submitCancelAndRollbackUseCoordinatorWithoutNetwork() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try SupervisorService(stateDirectory: directory)
        // A missing workspace fails before resolving or launching an executable.
        let plan = try DeploymentPlan(workspace: directory.appendingPathComponent("missing"), runCommand: .serveStatic, localPort: 8080)
        let submit = SupervisorServiceRequest(command: .submit, plan: plan)
        let accepted = await service.handle(submit)
        #expect(accepted.ok)
        #expect(accepted.deploymentID == plan.id)
        let duplicate = await service.handle(submit)
        #expect(duplicate.error?.code == "duplicate_deployment")
        let list = await service.handle(SupervisorServiceRequest(command: .list))
        #expect(list.jobs?.map(\.id) == [plan.id])
        let cancelled = await service.handle(SupervisorServiceRequest(command: .cancel, deploymentID: plan.id))
        #expect(cancelled.ok)
        let rollback = await service.handle(SupervisorServiceRequest(command: .rollback, deploymentID: plan.id))
        #expect(rollback.error?.code == "operation_failed")
        await service.shutdown()
    }

    @Test(arguments: ["../escape.zip", "bad\narchive.zip", "bad\u{0000}archive.zip"])
    func unsafeRuntimeArchiveNamesAreRejected(archiveName: String) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try SupervisorService(stateDirectory: directory)
        let artifact = try RuntimeArtifact(id: "fixture", runtime: "node", version: "1", url: URL(string: "https://fixture.invalid/archive")!, sha256: String(repeating: "0", count: 64), archiveName: archiveName)
        let plan = try DeploymentPlan(workspace: directory, runCommand: .serveStatic, localPort: 8080, runtimeArtifact: artifact, runtimeRoot: directory)
        let response = await service.handle(SupervisorServiceRequest(command: .submit, plan: plan))
        #expect(response.error?.code == "invalid_plan")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PhecdaSupervisorTests-\(UUID().uuidString)", isDirectory: true)
    }
}

private extension SupervisorServiceRequest.Command {
    static let allProtocolCommands: [Self] = [.ping, .list, .submit, .cancel, .rollback]
}
