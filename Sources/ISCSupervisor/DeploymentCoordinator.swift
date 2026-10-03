import Foundation

public struct DeploymentPlan: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let workspace: URL
    public let installCommands: [PresetCommand]
    public let buildCommand: PresetCommand?
    public let runCommand: PresetCommand
    public let localPort: Int
    public let runtimeArtifact: RuntimeArtifact?
    public let runtimeRoot: URL?
    public init(id: UUID = UUID(), workspace: URL, installCommands: [PresetCommand] = [], buildCommand: PresetCommand? = nil, runCommand: PresetCommand, localPort: Int, runtimeArtifact: RuntimeArtifact? = nil, runtimeRoot: URL? = nil) throws {
        guard workspace.isFileURL, workspace.path.hasPrefix("/"), (1...65535).contains(localPort), (runtimeArtifact == nil) == (runtimeRoot == nil) else { throw DeploymentPlanError.invalidPlan }
        self.id = id; self.workspace = workspace; self.installCommands = installCommands; self.buildCommand = buildCommand; self.runCommand = runCommand; self.localPort = localPort; self.runtimeArtifact = runtimeArtifact; self.runtimeRoot = runtimeRoot
    }
    public var previews: [ProcessCommandPreview] { installCommands.map { ProcessCommandPreview(preset: $0, workingDirectory: workspace) } + (buildCommand.map { [ProcessCommandPreview(preset: $0, workingDirectory: workspace)] } ?? []) + [ProcessCommandPreview(preset: runCommand, workingDirectory: workspace)] }
}

public enum DeploymentPlanError: Error, LocalizedError, Sendable, Equatable {
    case invalidPlan
    case unsupportedCommand(PresetCommand)
    public var errorDescription: String? { switch self { case .invalidPlan: "The deployment plan is invalid."; case let .unsupportedCommand(command): "The preset command is not supported: \(command.rawValue)." } }
}

public actor DeploymentCoordinator {
    private let jobs: SupervisorJobStore
    private let ledger: DeploymentLedger?
    private var processes: [UUID: ProcessSupervisor] = [:]
    public init(jobs: SupervisorJobStore = SupervisorJobStore(), ledger: DeploymentLedger? = nil) { self.jobs = jobs; self.ledger = ledger }

    /// Checkpoints a generated release directory without touching the user source.
    public func checkpoint(_ plan: DeploymentPlan, releaseDirectory: URL) async throws -> DeploymentRecord {
        guard let ledger else { throw DeploymentLedgerError.persistenceFailed }
        return try await ledger.record(
            deploymentID: plan.id,
            sourceDirectory: plan.workspace,
            releaseDirectory: releaseDirectory,
            runCommand: plan.runCommand,
            localPort: plan.localPort
        )
    }

    public func activateRelease(_ releaseID: UUID) async throws -> DeploymentRecord {
        guard let ledger else { throw DeploymentLedgerError.persistenceFailed }
        return try await ledger.activate(releaseID)
    }

    /// Stops the managed process before switching the pointer and restarting the prior release.
    public func rollback(_ deploymentID: UUID) async throws -> DeploymentRecord {
        guard let ledger, let process = processes[deploymentID] else {
            throw DeploymentLedgerError.noPreviousRelease(deploymentID)
        }
        if await process.running { try await process.stop() }
        let record = try await ledger.rollback(deploymentID: deploymentID)
        try await process.start(record.runCommand, workspace: record.releaseDirectory) { _ in }
        return record
    }

    public func submit(_ plan: DeploymentPlan) async -> UUID {
        let process = ProcessSupervisor(); processes[plan.id] = process
        let job = SupervisorJob(id: plan.id, kind: "deployment")
        return await jobs.submit(job) { [weak process] update in
            guard let process else { throw DeploymentPlanError.invalidPlan }
            update(.queued, 0, "Queued")
            if let artifact = plan.runtimeArtifact, let runtimeRoot = plan.runtimeRoot {
                update(.downloadingRuntime, 0.05, "Downloading \(artifact.runtime) \(artifact.version)")
                let archive = runtimeRoot.appendingPathComponent(".downloads", isDirectory: true).appendingPathComponent(artifact.archiveName)
                _ = try await RuntimeDownloader().download(artifact, to: archive)
                update(.downloadingRuntime, 0.25, "Installing \(artifact.runtime) \(artifact.version)")
                let installed = try RuntimeInstaller().install(artifact, archive: archive, to: runtimeRoot)
                await process.setToolchainRoot(installed)
            }
            for (index, command) in plan.installCommands.enumerated() {
                update(.installingDependencies, Double(index) / Double(max(plan.installCommands.count, 1)), "Installing \(command.rawValue)")
                try await process.run(command, workspace: plan.workspace) { _ in }
            }
            if let build = plan.buildCommand {
                update(.building, 0.6, "Building")
                try await process.run(build, workspace: plan.workspace) { _ in }
            }
            update(.starting, 0.85, "Starting")
            try await process.start(plan.runCommand, workspace: plan.workspace) { _ in }
            update(.running, 0.9, "Running on 127.0.0.1:\(plan.localPort)")
            while await process.running { try await Task.sleep(for: .milliseconds(250)) }
            try Task.checkCancellation()
        }
    }
    public func cancel(_ id: UUID) async { await jobs.cancel(id); await processes[id]?.cancel() }
    public func states() async -> [SupervisorTaskState] { await jobs.allStates() }
}