import Foundation

/// One request per JSON line. No executable paths or shell text are accepted.
public struct SupervisorServiceRequest: Codable, Sendable, Equatable {
    public enum Command: String, Codable, Sendable { case ping, list, submit, cancel, rollback }
    public let requestID: String?
    public let command: Command
    public let plan: DeploymentPlan?
    public let deploymentID: UUID?

    public init(requestID: String? = nil, command: Command, plan: DeploymentPlan? = nil, deploymentID: UUID? = nil) {
        self.requestID = requestID
        self.command = command
        self.plan = plan
        self.deploymentID = deploymentID
    }
}

public struct SupervisorServiceError: Codable, Sendable, Equatable {
    public let code: String
    public let message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
}

public struct SupervisorServiceResponse: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let requestID: String?
    public let ok: Bool
    public let deploymentID: UUID?
    public let jobs: [SupervisorTaskState]?
    public let ledger: DeploymentLedgerSnapshot?
    public let release: DeploymentRecord?
    public let error: SupervisorServiceError?

    public init(requestID: String? = nil, deploymentID: UUID? = nil, jobs: [SupervisorTaskState]? = nil, ledger: DeploymentLedgerSnapshot? = nil, release: DeploymentRecord? = nil, error: SupervisorServiceError? = nil) {
        self.protocolVersion = 1
        self.requestID = requestID
        self.ok = error == nil
        self.deploymentID = deploymentID
        self.jobs = jobs
        self.ledger = ledger
        self.release = release
        self.error = error
    }
}

public enum SupervisorServiceCodec {
    public static func decodeRequest(_ data: Data) throws -> SupervisorServiceRequest {
        try JSONDecoder().decode(SupervisorServiceRequest.self, from: data)
    }

    public static func encodeResponse(_ response: SupervisorServiceResponse) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(response)
    }

    public static func decodeResponse(_ data: Data) throws -> SupervisorServiceResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SupervisorServiceResponse.self, from: data)
    }
}

/// Local, trusted-client boundary. Jobs are in memory; release metadata is durable.
public actor SupervisorService {
    private let jobs: SupervisorJobStore
    private let ledger: DeploymentLedger
    private let coordinator: DeploymentCoordinator
    private var submittedIDs: Set<UUID> = []

    public init(stateDirectory: URL) throws {
        guard stateDirectory.isFileURL, stateDirectory.path.hasPrefix("/") else {
            throw DeploymentPlanError.invalidPlan
        }
        let jobs = SupervisorJobStore()
        let ledger = try DeploymentLedger(root: stateDirectory)
        self.jobs = jobs
        self.ledger = ledger
        self.coordinator = DeploymentCoordinator(jobs: jobs, ledger: ledger)
    }

    public func handleLine(_ data: Data) async -> SupervisorServiceResponse {
        let request: SupervisorServiceRequest
        do {
            request = try SupervisorServiceCodec.decodeRequest(data)
        } catch {
            return failure(nil, "invalid_request", error.localizedDescription)
        }
        return await handle(request)
    }

    public func handle(_ request: SupervisorServiceRequest) async -> SupervisorServiceResponse {
        do {
            switch request.command {
            case .ping:
                return SupervisorServiceResponse(requestID: request.requestID)
            case .list:
                return await SupervisorServiceResponse(requestID: request.requestID, jobs: jobs.allStates(), ledger: ledger.snapshot())
            case .submit:
                guard let plan = request.plan else {
                    return failure(request.requestID, "invalid_request", "submit requires a plan.")
                }
                // Synthesized Codable bypasses validating initializers; revalidate before execution.
                let validated = try DeploymentPlan(id: plan.id, workspace: plan.workspace, installCommands: plan.installCommands, buildCommand: plan.buildCommand, runCommand: plan.runCommand, localPort: plan.localPort, runtimeArtifact: plan.runtimeArtifact, runtimeRoot: plan.runtimeRoot)
                if let artifact = plan.runtimeArtifact {
                    _ = try RuntimeArtifact(id: artifact.id, runtime: artifact.runtime, version: artifact.version, url: artifact.url, sha256: artifact.sha256, size: artifact.size, archiveName: artifact.archiveName)
                    guard artifact.url.scheme == "https", let root = plan.runtimeRoot, root.isFileURL,
                          safeComponent(artifact.archiveName), safeComponent(artifact.runtime), safeComponent(artifact.version) else {
                        return failure(request.requestID, "invalid_plan", "Runtime downloads require HTTPS and safe local install paths.")
                    }
                }
                guard !submittedIDs.contains(plan.id) else {
                    return failure(request.requestID, "duplicate_deployment", "This deployment ID has already been submitted.")
                }
                // Reserve before awaiting so concurrent callers cannot overwrite jobs.
                submittedIDs.insert(plan.id)
                let id = await coordinator.submit(validated)
                return SupervisorServiceResponse(requestID: request.requestID, deploymentID: id)
            case .cancel, .rollback:
                guard let id = request.deploymentID else {
                    return failure(request.requestID, "invalid_request", "\(request.command.rawValue) requires a deploymentID.")
                }
                guard submittedIDs.contains(id) else {
                    return failure(request.requestID, "unknown_deployment", "No managed deployment exists with this ID.")
                }
                if request.command == .cancel {
                    await coordinator.cancel(id)
                    return SupervisorServiceResponse(requestID: request.requestID, deploymentID: id)
                }
                let record = try await coordinator.rollback(id)
                return SupervisorServiceResponse(requestID: request.requestID, deploymentID: id, release: record)
            }
        } catch {
            return failure(request.requestID, request.command == .submit ? "invalid_plan" : "operation_failed", error.localizedDescription)
        }
    }

    public func shutdown() async {
        for id in submittedIDs { await coordinator.cancel(id) }
    }

    private func safeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private func failure(_ requestID: String?, _ code: String, _ message: String) -> SupervisorServiceResponse {
        SupervisorServiceResponse(requestID: requestID, error: SupervisorServiceError(code: code, message: message))
    }
}
