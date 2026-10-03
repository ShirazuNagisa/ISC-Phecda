import Foundation

public enum PresetCommand: String, Codable, Sendable, CaseIterable {
    case installNodeDependencies, installPythonDependencies, buildNode, buildPython, buildGo, buildJava, runNode, runPython, runGo, runJava

    public var executable: String { switch self { case .installNodeDependencies, .buildNode, .runNode: "npm"; case .installPythonDependencies, .buildPython, .runPython: "python3"; case .buildGo, .runGo: "go"; case .buildJava, .runJava: "java" } }
    public func arguments(workspace: URL) -> [String] { switch self { case .installNodeDependencies: ["install", "--ignore-scripts"]; case .installPythonDependencies: ["-m", "pip", "install", "-r", "requirements.txt"]; case .buildNode: ["run", "build"]; case .buildPython: ["-m", "compileall", "."]; case .buildGo: ["build", "-o", ".supervisor/bin/app", "."]; case .buildJava: ["-jar", "app.jar"]; case .runNode: ["start"]; case .runPython: ["-m", "http.server", "8000"]; case .runGo: [".supervisor/bin/app"]; case .runJava: ["-jar", "app.jar"] } }
}

public struct ProcessCommandPreview: Codable, Sendable, Equatable {
    public let preset: PresetCommand
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: URL
    public let display: String
    public init(preset: PresetCommand, workingDirectory: URL) {
        self.preset = preset; self.executable = preset.executable; self.arguments = preset.arguments(workspace: workingDirectory); self.workingDirectory = workingDirectory
        self.display = ([preset.executable] + self.arguments).map(Self.quote).joined(separator: " ")
    }
    private static func quote(_ value: String) -> String { value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil ? value : "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\"" }
}

public enum ProcessSupervisorError: Error, LocalizedError, Sendable, Equatable { case executableNotFound(String), invalidWorkspace, alreadyRunning, notRunning, terminated(Int32); public var errorDescription: String? { switch self { case let .executableNotFound(e): "Executable not found: \(e)"; case .invalidWorkspace: "The process workspace is not a directory."; case .alreadyRunning: "A process is already running."; case .notRunning: "No process is running."; case let .terminated(code): "Process exited with status \(code)." } } }

public protocol ProcessSupervising: Sendable {
    func preview(_ command: PresetCommand, workspace: URL) -> ProcessCommandPreview
    func run(_ command: PresetCommand, workspace: URL, output: (@Sendable (String) -> Void)?) async throws
    func cancel() async
}

public actor ProcessSupervisor: ProcessSupervising {
    private var process: Process?
    public init() {}
    nonisolated public func preview(_ command: PresetCommand, workspace: URL) -> ProcessCommandPreview { ProcessCommandPreview(preset: command, workingDirectory: workspace) }
    public func run(_ command: PresetCommand, workspace: URL, output: (@Sendable (String) -> Void)? = nil) async throws {
        guard process == nil else { throw ProcessSupervisorError.alreadyRunning }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspace.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw ProcessSupervisorError.invalidWorkspace }
        let preview = ProcessCommandPreview(preset: command, workingDirectory: workspace)
        let executableURL = try Self.resolve(preview.executable)
        let child = Process(); child.executableURL = executableURL; child.arguments = preview.arguments; child.currentDirectoryURL = workspace
        let pipe = Pipe(); child.standardOutput = pipe; child.standardError = pipe
        process = child
        defer { process = nil }
        if let output { pipe.fileHandleForReading.readabilityHandler = { handle in if let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty { output(text) } } }
        try child.run()
        while child.isRunning {
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { child.terminate(); throw error }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        if let output, let tail = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), !tail.isEmpty { output(tail) }
        try Task.checkCancellation()
        guard child.terminationStatus == 0 else { throw ProcessSupervisorError.terminated(child.terminationStatus) }
    }
    public func cancel() async { process?.terminate() }
    private static func resolve(_ executable: String) throws -> URL { let paths = ["/usr/bin/\(executable)", "/opt/homebrew/bin/\(executable)", "/usr/local/bin/\(executable)"]; guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw ProcessSupervisorError.executableNotFound(executable) }; return URL(fileURLWithPath: path) }
}
