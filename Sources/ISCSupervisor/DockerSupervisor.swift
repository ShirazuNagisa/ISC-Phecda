import Foundation

public enum DockerSupervisorError: Error, LocalizedError, Sendable, Equatable {
    case executableNotFound
    case invalidPlan
    case commandFailed(Int32)
    public var errorDescription: String? { switch self { case .executableNotFound: "Docker executable was not found."; case .invalidPlan: "The Docker command plan is invalid."; case let .commandFailed(code): "Docker exited with status \(code)." } }
}

public struct DockerContainerInspection: Codable, Sendable, Equatable {
    public let name: String
    public let running: Bool
    public let status: String
    public let ports: [String]
    public let health: String?
    public init(name: String, running: Bool, status: String, ports: [String] = [], health: String? = nil) { self.name = name; self.running = running; self.status = status; self.ports = ports; self.health = health }
}

public struct DockerComposeServiceInspection: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let service: String
    public let state: String
    public let health: String?
    public let ports: [String]
    public init(service: String, state: String, health: String? = nil, ports: [String] = []) { self.id = service; self.service = service; self.state = state; self.health = health; self.ports = ports }
}

public enum DockerLogError: Error, LocalizedError, Sendable, Equatable {
    case invalidTail
    public var errorDescription: String? { "Docker log tail must be between 1 and 10000 lines." }
}

public actor DockerSupervisor {
    private let planner: DockerPlanner
    private var activeNames: Set<String> = []
    private var activeSources: [String: DockerSourcePlan] = [:]
    private let stateLocation: URL?
    public init(planner: DockerPlanner = DockerPlanner()) { self.planner = planner; self.stateLocation = nil }
    public init(planner: DockerPlanner = DockerPlanner(), stateLocation: URL) throws {
        guard stateLocation.isFileURL, stateLocation.path.hasPrefix("/") else { throw DockerSupervisorError.invalidPlan }
        self.planner = planner; self.stateLocation = stateLocation
        if let data = try? Data(contentsOf: stateLocation), !data.isEmpty {
            self.activeSources = try JSONDecoder().decode([String: DockerSourcePlan].self, from: data)
            self.activeNames = []
        }
    }

    public func reconcilePersistedSources() async {
        var live: Set<String> = []
        for (name, source) in activeSources {
            do {
                switch source {
                case let .compose(file):
                    let services = try await composeStatus(file: file)
                    if !services.isEmpty && services.allSatisfy({ ["running", "up"].contains($0.state.lowercased()) }) { live.insert(name) }
                default:
                    if try await inspect(name: name).running { live.insert(name) }
                }
            } catch { }
        }
        activeNames = live
        activeSources = activeSources.filter { live.contains($0.key) }
        persistState()
    }
    public func plan(source: DockerSourcePlan, name: String, ports: [Int] = [], policy: DockerPolicy = .init()) throws -> DockerCommandPlan {
        try planner.plan(source: source, name: name, ports: ports, policy: policy)
    }

    @discardableResult
    public func start(source: DockerSourcePlan, name: String, ports: [Int] = [], policy: DockerPolicy = .init(), waitForReady: Bool = false, output: (@Sendable (String) -> Void)? = nil) async throws -> DockerCommandPlan {
        let plan = try planner.plan(source: source, name: name, ports: ports, policy: policy)
        switch source {
        case .dockerfile:
            try await run(arguments: plan.arguments, output: output)
            let runArguments = ["run", "--detach", "--name", name] + ports.flatMap { ["--publish", "\($0):\($0)"] } + [name]
            try await run(arguments: runArguments, output: output)
        default:
            try await run(arguments: plan.arguments, output: output)
        }
        if waitForReady {
            do {
                if case let .compose(file) = source { _ = try await waitUntilComposeReady(file: file) }
                else { _ = try await waitUntilReady(name: name) }
            } catch {
                if case let .compose(file) = source { try? await run(arguments: ["compose", "-f", file.path, "down"], output: output) }
                else {
                    try? await run(arguments: ["stop", name], output: output)
                    try? await run(arguments: ["rm", "--force", name], output: output)
                }
                throw error
            }
        }
        activeNames.insert(name)
        activeSources[name] = source
        persistState()
        return plan
    }

    public func stop(name: String, remove: Bool = false, output: (@Sendable (String) -> Void)? = nil) async throws {
        guard !name.isEmpty, name.rangeOfCharacter(from: CharacterSet(charactersIn: ";&|$`<>\n\r")) == nil else { throw DockerSupervisorError.invalidPlan }
        if case let .compose(file) = activeSources[name] {
            var arguments = ["compose", "-f", file.path, "down"]
            if remove { arguments.append("--volumes") }
            try await run(arguments: arguments, output: output)
        } else {
            try await run(arguments: ["stop", name], output: output)
            if remove { try await run(arguments: ["rm", "--force", name], output: output) }
        }
        activeNames.remove(name)
        activeSources[name] = nil
        persistState()
    }

    public func inspect(name: String) async throws -> DockerContainerInspection {
        try Self.validateName(name)
        let data = try await runCapture(arguments: ["inspect", name])
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], let item = items.first,
              let state = item["State"] as? [String: Any], let running = state["Running"] as? Bool, let status = state["Status"] as? String else { throw DockerSupervisorError.invalidPlan }
        let ports = ((item["NetworkSettings"] as? [String: Any])?["Ports"] as? [String: Any])?.keys.sorted() ?? []
        let health = (state["Health"] as? [String: Any])?["Status"] as? String
        return DockerContainerInspection(name: name, running: running, status: status, ports: ports, health: health)
    }

    public func waitUntilReady(name: String, timeout: Duration = .seconds(60)) async throws -> DockerContainerInspection {
        let deadline = ContinuousClock.now + timeout
        while true {
            let inspection = try await inspect(name: name)
            if !inspection.running { throw DockerSupervisorError.commandFailed(1) }
            if inspection.health == nil || inspection.health == "healthy" { return inspection }
            if inspection.health == "unhealthy" || ContinuousClock.now >= deadline { throw DockerSupervisorError.commandFailed(1) }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    public func logs(name: String, tail: Int = 200) async throws -> String {
        try Self.validateName(name)
        guard (1...10_000).contains(tail) else { throw DockerLogError.invalidTail }
        return String(decoding: try await runCapture(arguments: ["logs", "--tail", String(tail), name]), as: UTF8.self)
    }

    public func waitUntilComposeReady(file: URL, timeout: Duration = .seconds(60)) async throws -> [DockerComposeServiceInspection] {
        let deadline = ContinuousClock.now + timeout
        while true {
            let services = try await composeStatus(file: file)
            guard !services.isEmpty else { throw DockerSupervisorError.invalidPlan }
            let failed = services.contains { ["exited", "dead", "unhealthy"].contains($0.state.lowercased()) || $0.health?.lowercased() == "unhealthy" }
            let ready = services.allSatisfy { service in
                let stateReady = ["running", "up"].contains(service.state.lowercased())
                let healthReady = service.health == nil || service.health?.lowercased() == "healthy"
                return stateReady && healthReady
            }
            if failed { throw DockerSupervisorError.commandFailed(1) }
            if ready { return services }
            if ContinuousClock.now >= deadline { throw DockerSupervisorError.commandFailed(1) }
            try await Task.sleep(for: .milliseconds(500))
        }
    }
    public func composeStatus(file: URL) async throws -> [DockerComposeServiceInspection] {
        try Self.validateComposeFile(file)
        let data = try await runCapture(arguments: ["compose", "-f", file.path, "ps", "--format", "json"])
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw DockerSupervisorError.invalidPlan }
        return rows.compactMap { row in
            guard let service = row["Service"] as? String ?? row["Name"] as? String else { return nil }
            let state = row["State"] as? String ?? "unknown"
            let health = row["Health"] as? String
            let ports: [String] = (row["Publishers"] as? [[String: Any]])?.compactMap { publisher in
                if let published = publisher["PublishedPort"] as? Int, let target = publisher["TargetPort"] as? Int { return "\(published):\(target)" }
                return nil
            } ?? []
            return DockerComposeServiceInspection(service: service, state: state, health: health, ports: ports)
        }.sorted { $0.service < $1.service }
    }

    public func composeLogs(file: URL, service: String? = nil, tail: Int = 200) async throws -> String {
        try Self.validateComposeFile(file)
        guard (1...10_000).contains(tail) else { throw DockerLogError.invalidTail }
        var arguments = ["compose", "-f", file.path, "logs", "--tail", String(tail)]
        if let service { try Self.validateName(service); arguments.append(service) }
        return String(decoding: try await runCapture(arguments: arguments), as: UTF8.self)
    }



    public func isActive(_ name: String) -> Bool { activeNames.contains(name) }

    private func persistState() {
        guard let stateLocation else { return }
        do {
            let data = try JSONEncoder().encode(activeSources)
            try FileManager.default.createDirectory(at: stateLocation.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = stateLocation.deletingLastPathComponent().appendingPathComponent(".\(stateLocation.lastPathComponent).\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: stateLocation.path) { _ = try FileManager.default.replaceItemAt(stateLocation, withItemAt: temporary) }
            else { try FileManager.default.moveItem(at: temporary, to: stateLocation) }
        } catch { }
    }
    private static func validateComposeFile(_ file: URL) throws {
        let forbidden = CharacterSet(charactersIn: ";&|$`<>(){}[]*?!~\"'\\#").union(.controlCharacters)
        guard file.isFileURL, file.path.hasPrefix("/"), !file.path.hasSuffix("/"), file.path.rangeOfCharacter(from: forbidden) == nil else { throw DockerSupervisorError.invalidPlan }
    }

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

    private func runCapture(arguments: [String]) async throws -> Data {
        guard !arguments.isEmpty, arguments.allSatisfy(Self.validArgument) else { throw DockerSupervisorError.invalidPlan }
        guard let executable = Self.executableURL() else { throw DockerSupervisorError.executableNotFound }
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        let output = Pipe(); process.standardOutput = output; process.standardError = output; process.standardInput = FileHandle.nullDevice
        try process.run()
        while process.isRunning { try await Task.sleep(for: .milliseconds(50)); try Task.checkCancellation() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { throw DockerSupervisorError.commandFailed(process.terminationStatus) }
        return data
    }

    private static func validateName(_ name: String) throws {
        guard !name.isEmpty, validArgument(name) else { throw DockerSupervisorError.invalidPlan }
    }
    private static func executableURL() -> URL? { ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/usr/bin/docker"].compactMap { FileManager.default.isExecutableFile(atPath: $0) ? URL(fileURLWithPath: $0) : nil }.first }
    private static func validArgument(_ argument: String) -> Bool { !argument.isEmpty && argument.rangeOfCharacter(from: CharacterSet(charactersIn: ";&|$`<>\n\r")) == nil }
}
