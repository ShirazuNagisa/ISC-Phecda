import Foundation

public enum DockerSourcePlan: Codable, Sendable, Equatable {
    case compose(file: URL)
    case dockerfile(directory: URL)
    case image(reference: String)
    case command(image: String, arguments: [String])
}

public struct DockerPolicy: Codable, Sendable, Equatable {
    public var allowPrivileged: Bool
    public var allowHostNetwork: Bool
    public var allowHostMounts: Bool
    public init(allowPrivileged: Bool = false, allowHostNetwork: Bool = false, allowHostMounts: Bool = false) { self.allowPrivileged = allowPrivileged; self.allowHostNetwork = allowHostNetwork; self.allowHostMounts = allowHostMounts }
}

public struct DockerCommandPlan: Codable, Sendable, Equatable {
    public let arguments: [String]
    public let display: String
    public let requiresExplicitConfirmation: Bool
    public let warnings: [String]
    public init(arguments: [String], requiresExplicitConfirmation: Bool, warnings: [String]) { self.arguments = arguments; self.display = ( ["docker"] + arguments ).map(Self.quote).joined(separator: " "); self.requiresExplicitConfirmation = requiresExplicitConfirmation; self.warnings = warnings }
    private static func quote(_ value: String) -> String { value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil ? value : "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\"" }
}

public enum DockerPlanError: Error, LocalizedError, Sendable, Equatable { case invalidImageReference, invalidArgument, unavailablePrivilege(String), invalidPath; public var errorDescription: String? { switch self { case .invalidImageReference: "Invalid Docker image reference."; case .invalidArgument: "Docker arguments contain unsupported shell syntax."; case let .unavailablePrivilege(item): "Docker plan requires explicit permission for \(item)."; case .invalidPath: "The Docker path must be an absolute local path." } } }

public struct DockerPlanner: Sendable {
    public init() {}
    public func plan(source: DockerSourcePlan, name: String, ports: [Int] = [], policy: DockerPolicy = .init()) throws -> DockerCommandPlan {
        guard !name.isEmpty, name.rangeOfCharacter(from: CharacterSet(charactersIn: ";&|$`<>\n\r")) == nil else { throw DockerPlanError.invalidArgument }
        var args: [String]; var warnings: [String] = []
        switch source {
        case let .compose(file):
            guard file.isFileURL, file.path.hasPrefix("/") else { throw DockerPlanError.invalidPath }
            args = ["compose", "-f", file.path, "up", "--detach"]
        case let .dockerfile(directory):
            guard directory.isFileURL, directory.path.hasPrefix("/") else { throw DockerPlanError.invalidPath }
            args = ["build", "--tag", name, directory.path]
        case let .image(reference):
            guard Self.validImage(reference) else { throw DockerPlanError.invalidImageReference }
            args = ["run", "--name", name]
            args.append(contentsOf: ports.flatMap { ["--publish", "\($0):\($0)"] })
            args += [reference]
        case let .command(image, commandArguments):
            guard Self.validImage(image), commandArguments.allSatisfy(Self.validToken) else { throw DockerPlanError.invalidArgument }
            args = ["run", "--name", name]
            args.append(contentsOf: ports.flatMap { ["--publish", "\($0):\($0)"] })
            args += [image] + commandArguments
        }
        guard ports.allSatisfy({ (1...65535).contains($0) }) else { throw DockerPlanError.invalidArgument }
        let privileged = args.contains("--privileged")
        let hostNetwork = args.contains("--network=host") || args.contains("--network") && args.contains("host")
        let hostMount = args.contains("--volume") || args.contains("-v")
        let requires = privileged || hostNetwork || hostMount
        if privileged && !policy.allowPrivileged { throw DockerPlanError.unavailablePrivilege("privileged containers") }
        if hostNetwork && !policy.allowHostNetwork { throw DockerPlanError.unavailablePrivilege("host networking") }
        if hostMount && !policy.allowHostMounts { throw DockerPlanError.unavailablePrivilege("host mounts") }
        if requires { warnings.append("This plan affects host networking, privileges, or filesystem mounts.") }
        return DockerCommandPlan(arguments: args, requiresExplicitConfirmation: requires, warnings: warnings)
    }
    private static func validImage(_ value: String) -> Bool { !value.isEmpty && value.count < 256 && value.rangeOfCharacter(from: CharacterSet(charactersIn: " \t\n\r;&|$`<>")) == nil }
    private static func validToken(_ value: String) -> Bool { !value.isEmpty && value.rangeOfCharacter(from: CharacterSet(charactersIn: "\n\r;&|$`<>")) == nil }
}
