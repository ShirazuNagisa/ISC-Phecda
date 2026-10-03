import Foundation

public struct SupervisorJob: Sendable {
    public let id: UUID
    public let kind: String
    public init(id: UUID = UUID(), kind: String) { self.id = id; self.kind = kind }
}

public actor SupervisorJobStore {
    private var states: [UUID: SupervisorTaskState] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let location: URL?
    public init() { self.location = nil }
    public init(location: URL) throws {
        guard location.isFileURL, location.path.hasPrefix("/") else { throw SupervisorJobStoreError.invalidLocation }
        self.location = location
        if let data = try? Data(contentsOf: location), !data.isEmpty {
            self.states = Dictionary(uniqueKeysWithValues: try JSONDecoder.supervisorJobs.decode([SupervisorTaskState].self, from: data).map { ($0.id, $0) })
        }
    }
    public func state(for id: UUID) -> SupervisorTaskState? { states[id] }
    public func allStates() -> [SupervisorTaskState] { states.values.sorted { $0.updatedAt < $1.updatedAt } }
    public func submit(_ job: SupervisorJob, operation: @escaping @Sendable (_ update: @Sendable (SupervisorTaskPhase, Double, String?) async -> Void) async throws -> Void) -> UUID {
        let initial = SupervisorTaskState(id: job.id, kind: job.kind)
        states[job.id] = initial; persist()
        tasks[job.id] = Task { [weak self] in
            do {
                await self?.update(job.id, phase: .queued, progress: 0, message: "Queued")
                try await operation { [weak self] phase, progress, message in
                    guard let self else { return }
                    await self.update(job.id, phase: phase, progress: progress, message: message)
                }
                await self?.update(job.id, phase: .completed, progress: 1, message: "Completed")
            } catch is CancellationError { await self?.update(job.id, phase: .cancelled, progress: nil, message: "Cancelled") }
            catch { await self?.fail(job.id, error: error.localizedDescription) }
            await self?.removeTask(job.id)
        }
        return job.id
    }
    public func cancel(_ id: UUID) { tasks[id]?.cancel() }
    private func update(_ id: UUID, phase: SupervisorTaskPhase, progress: Double?, message: String?) { states[id]?.update(phase: phase, progress: progress, message: message); persist() }
    private func fail(_ id: UUID, error: String) { states[id]?.error = error; states[id]?.update(phase: .failed, message: error); persist() }
    private func removeTask(_ id: UUID) { tasks[id] = nil }
    private func persist() {
        guard let location else { return }
        do {
            let data = try JSONEncoder.supervisorJobs.encode(Array(states.values))
            try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = location.deletingLastPathComponent().appendingPathComponent(".\(location.lastPathComponent).\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: location.path) { _ = try FileManager.default.replaceItemAt(location, withItemAt: temporary) }
            else { try FileManager.default.moveItem(at: temporary, to: location) }
        } catch { /* state persistence must not kill a running job */ }
    }
}

public enum SupervisorJobStoreError: Error, LocalizedError, Sendable, Equatable { case invalidLocation; public var errorDescription: String? { "The Supervisor job state location is invalid." } }

private extension JSONEncoder {
    static var supervisorJobs: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]; return encoder }
}
private extension JSONDecoder {
    static var supervisorJobs: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}
