import Foundation

public enum SupervisorClientError: Error, LocalizedError, Sendable, Equatable {
    case executableMissing(URL)
    case serviceExited
    case invalidResponse
    case remote(String)
    public var errorDescription: String? { switch self { case let .executableMissing(url): "Supervisor executable is missing: \(url.path)"; case .serviceExited: "The Supervisor service exited."; case .invalidResponse: "Supervisor returned an invalid response."; case let .remote(message): message } }
}

/// A small local JSON-lines client. One client owns one helper process and is
/// intentionally actor-isolated so request/response lines cannot interleave.
public actor SupervisorServiceClient {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private var buffer = Data()

    public init(executableURL: URL, stateDirectory: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { throw SupervisorClientError.executableMissing(executableURL) }
        let child = Process(); child.executableURL = executableURL; child.arguments = ["--state-directory", stateDirectory.path]
        let stdin = Pipe(); let stdout = Pipe(); child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.standardError
        try child.run()
        self.process = child; self.input = stdin.fileHandleForWriting; self.output = stdout.fileHandleForReading
    }

    public func request(_ request: SupervisorServiceRequest) throws -> SupervisorServiceResponse {
        guard process.isRunning else { throw SupervisorClientError.serviceExited }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        input.write(try encoder.encode(request)); input.write(Data([0x0A]))
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
                do {
                    let response = try SupervisorServiceCodec.decodeResponse(Data(line))
                    if let error = response.error { throw SupervisorClientError.remote(error.message) }
                    return response
                } catch let error as SupervisorClientError { throw error }
                catch { throw SupervisorClientError.invalidResponse }
            }
            let data = output.readData(ofLength: 4096)
            guard !data.isEmpty else { throw SupervisorClientError.serviceExited }
            buffer.append(data)
        }
    }

    public func submit(_ plan: DeploymentPlan) throws -> UUID {
        let response = try request(SupervisorServiceRequest(command: .submit, plan: plan))
        guard let id = response.deploymentID else { throw SupervisorClientError.invalidResponse }
        return id
    }

    public func cancel(_ id: UUID) throws { _ = try request(SupervisorServiceRequest(command: .cancel, deploymentID: id)) }
    public func rollback(_ id: UUID) throws -> SupervisorServiceResponse { try request(SupervisorServiceRequest(command: .rollback, deploymentID: id)) }
    public func list() throws -> SupervisorServiceResponse { try request(SupervisorServiceRequest(command: .list)) }
    public func shutdown() { process.terminate(); input.closeFile(); output.closeFile() }
}
