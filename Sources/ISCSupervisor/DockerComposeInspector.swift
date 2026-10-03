import Foundation

public struct DockerComposeSummary: Codable, Sendable, Equatable {
    public let services: [DockerComposeServiceSummary]
    public init(services: [DockerComposeServiceSummary]) { self.services = services }
}

public struct DockerComposeServiceSummary: Codable, Sendable, Equatable {
    public let name: String
    public let ports: [DockerComposePortSummary]
    public let volumes: [String]
    public let environmentVariableNames: [String]

    public init(name: String, ports: [DockerComposePortSummary], volumes: [String], environmentVariableNames: [String]) {
        self.name = name
        self.ports = ports
        self.volumes = volumes
        self.environmentVariableNames = environmentVariableNames
    }
}

public struct DockerComposePortSummary: Codable, Sendable, Equatable {
    /// A string preserves published port ranges as well as individual ports.
    public let published: String?
    public let target: Int
    public init(published: String?, target: Int) { self.published = published; self.target = target }
}

public enum DockerComposeInspectionError: Error, LocalizedError, Sendable, Equatable {
    case invalidFilePath, executableNotFound, commandLaunchFailed, commandFailed(Int32), invalidConfiguration

    public var errorDescription: String? {
        switch self {
        case .invalidFilePath: "Compose inspection requires an absolute file path without shell metacharacters."
        case .executableNotFound: "Docker executable was not found."
        case .commandLaunchFailed: "Docker Compose inspection could not be started."
        case let .commandFailed(status): "Docker Compose inspection exited with status \(status)."
        case .invalidConfiguration: "Docker Compose returned an invalid JSON configuration."
        }
    }
}

public protocol DockerComposeCommandRunner: Sendable {
    func run(arguments: [String]) async throws -> Data
}

public struct DockerComposeInspector: Sendable {
    private let runner: any DockerComposeCommandRunner

    public init(runner: any DockerComposeCommandRunner = DockerComposeProcessRunner()) { self.runner = runner }

    public func inspect(file: String) async throws -> DockerComposeSummary {
        try Task.checkCancellation()
        try validateComposeFilePath(file)
        let data = try await runner.run(arguments: ["compose", "-f", file, "config", "--format", "json"])
        try Task.checkCancellation()
        // Never expose raw output or decoding errors: either can contain environment secrets.
        let configuration: ComposeConfiguration
        do { configuration = try JSONDecoder().decode(ComposeConfiguration.self, from: data) }
        catch { throw DockerComposeInspectionError.invalidConfiguration }
        return DockerComposeSummary(services: configuration.services.sorted { $0.key < $1.key }.map { name, service in
            DockerComposeServiceSummary(name: name, ports: service.ports, volumes: service.volumes,
                                        environmentVariableNames: service.environmentVariableNames)
        })
    }
}

private func validateComposeFilePath(_ file: String) throws {
    let forbidden = CharacterSet(charactersIn: ";&|$`<>(){}[]*?!~\"'\\#").union(.controlCharacters)
    guard file.hasPrefix("/"), !file.hasSuffix("/"), file.rangeOfCharacter(from: forbidden) == nil else {
        throw DockerComposeInspectionError.invalidFilePath
    }
}

public struct DockerComposeProcessRunner: DockerComposeCommandRunner {
    public init() {}

    public func run(arguments: [String]) async throws -> Data {
        // Keep the production runner inspection-only, even when called directly.
        guard arguments.count == 6, arguments[0] == "compose", arguments[1] == "-f",
              Array(arguments[3...]) == ["config", "--format", "json"] else {
            throw DockerComposeInspectionError.invalidFilePath
        }
        try validateComposeFilePath(arguments[2])
        try Task.checkCancellation()
        guard let executable = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/usr/bin/docker"].first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { throw DockerComposeInspectionError.executableNotFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        do { try process.run() } catch { throw DockerComposeInspectionError.commandLaunchFailed }
        // Drain before waiting so a large Compose configuration cannot fill the pipe and deadlock.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try Task.checkCancellation()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw DockerComposeInspectionError.commandFailed(process.terminationStatus)
        }
        return data
    }
}

private struct ComposeConfiguration: Decodable {
    let services: [String: ComposeService]
}

private struct ComposeService: Decodable {
    let ports: [DockerComposePortSummary]
    let volumes: [String]
    let environmentVariableNames: [String]

    private enum CodingKeys: String, CodingKey { case ports, volumes, environment }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ports = try container.decodeIfPresent([ComposePort].self, forKey: .ports)?.map {
            DockerComposePortSummary(published: $0.published, target: $0.target)
        } ?? []
        volumes = try container.decodeIfPresent([ComposeVolume].self, forKey: .volumes)?.map(\.description) ?? []
        if try !container.contains(.environment) || container.decodeNil(forKey: .environment) {
            environmentVariableNames = []
        } else if let names = try? container.nestedContainer(keyedBy: EnvironmentKey.self, forKey: .environment) {
            // Only enumerate keys; environment values are never decoded or retained.
            environmentVariableNames = names.allKeys.map(\.stringValue).sorted()
        } else {
            let entries = try container.decode([String].self, forKey: .environment)
            environmentVariableNames = Array(Set(entries.map { String($0.prefix(while: { $0 != "=" })) })).sorted()
        }
    }
}

private struct EnvironmentKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private struct ComposePort: Decodable {
    let published: String?
    let target: Int
    private enum CodingKeys: String, CodingKey { case published, target }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decode(Int.self, forKey: .target)
        if let number = try? container.decode(Int.self, forKey: .published) { published = String(number) }
        else { published = try container.decodeIfPresent(String.self, forKey: .published) }
    }
}

private struct ComposeVolume: Decodable {
    let description: String
    private enum CodingKeys: String, CodingKey { case source, target, readOnly = "read_only" }

    init(from decoder: any Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) { description = value; return }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let source = try container.decodeIfPresent(String.self, forKey: .source)
        let target = try container.decode(String.self, forKey: .target)
        let readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        description = (source.map { "\($0):" } ?? "") + target + (readOnly ? ":ro" : "")
    }
}
