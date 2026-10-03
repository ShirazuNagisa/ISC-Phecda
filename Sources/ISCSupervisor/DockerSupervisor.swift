import Foundation

public enum DockerSupervisorError: Error, LocalizedError, Sendable, Equatable {
    case executableNotFound
    case invalidPlan
    case commandFailed(Int32)
    public var errorDescription: String? { switch self { case .executableNotFound: "Docker executable was not found."; case .invalidPlan: "The Docker command plan is invalid."; case let .commandFailed(code): "Docker exited with status \(code)." } }
}

public actor DockerSupervisor {
    private let planner: DockerPlanner
    private var activeNames: Set<String> = []
    public init(planner: DockerPlanner = DockerPlanner()) { self.planner = planner }

    public func plan(source: DockerSourcePlan, name: String, ports: [Int] = [], policy: DockerPolicy = .init()) throws -> DockerCommandPlan {
        try planner.plan(source: source, name: name, ports: ports, policy: policy)
    }

    @discardableResult
    public func start(source: DockerSourcePlan, name: String, ports: [Int] = [], policy: DockerPolicy = .init(), output: (@Sendable (String) -> Void)? = nil) async throws -> DockerCommandPlan {
        let plan = try planner.plan(source: source, name: name, ports: ports, policy: policy)
        try await run(arguments: plan.arguments, output: output)
        activeNames.insert(name)
        return plan
    }

    public func stop(name: String, remove: Bool = false, output: (@Sendable (String) -> Void)? = nil) async throws {
        guard !name.isEmpty, name.rangeOfCharacter(from: CharacterSet(charactersIn: ";&|$`<>\n\r")) == nil else { throw DockerSupervisorError.invalidPlan }
        try await run(arguments: ["stop", name], output: output)
        if remove { try await run(arguments: ["rm", "--force", name], output: output) }
        activeNames.remove(name)
    }

    public func isActive(_ name: String) -> Bool { activeNames.contains(name) }

    private func run(arguments: [String], output: (@Sendable (String) -> Void)?) async throws {
        guard !arguments.isEmpty, arguments.allSatisfy(Self.validArgument) else { throw DockerSupervisorError.invalidPlan }
        guard let executable = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/usr/bin/docker"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw DockerSupervisorError.executableNotFound }
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        if let output { pipe.fileHandleForReading.readabilityHandler = { handle in if let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty { output(text) } } }
        try process.run()
        while process.isRunning { try await Task.sleep(for: .milliseconds(50)); try Task.checkCancellation() }
        pipe.fileHandleForReading.readabilityHandler = nil
        if let output, let tail = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), !tail.isEmpty { output(tail) }
        guard process.terminationStatus == 0 else { throw DockerSupervisorError.commandFailed(process.terminationStatus) }
    }

    private static func validArgument(_ argument: String) -> Bool { !argument.isEmpty && argument.rangeOfCharacter(from: CharacterSet(charactersIn: ";&|$`<>\n\r")) == nil }
}
