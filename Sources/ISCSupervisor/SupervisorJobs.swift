import Foundation

public struct SupervisorJob: Sendable {
    public let id: UUID
    public let kind: String
    public init(id: UUID = UUID(), kind: String) { self.id = id; self.kind = kind }
}

public actor SupervisorJobStore {
    private var states: [UUID: SupervisorTaskState] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    public init() {}
    public func state(for id: UUID) -> SupervisorTaskState? { states[id] }
    public func allStates() -> [SupervisorTaskState] { states.values.sorted { $0.updatedAt < $1.updatedAt } }
    public func submit(_ job: SupervisorJob, operation: @escaping @Sendable (_ update: @Sendable (SupervisorTaskPhase, Double, String?) -> Void) async throws -> Void) -> UUID {
        let initial = SupervisorTaskState(id: job.id, kind: job.kind)
        states[job.id] = initial
        tasks[job.id] = Task { [weak self] in
            do {
                await self?.update(job.id, phase: .queued, progress: 0, message: "Queued")
                try await operation { [weak self] phase, progress, message in
                    guard let self else { return }
                    Task { await self.update(job.id, phase: phase, progress: progress, message: message) }
                }
                await self?.update(job.id, phase: .completed, progress: 1, message: "Completed")
            } catch is CancellationError {
                await self?.update(job.id, phase: .cancelled, progress: nil, message: "Cancelled")
            } catch {
                await self?.fail(job.id, error: error.localizedDescription)
            }
            await self?.removeTask(job.id)
        }
        return job.id
    }
    public func cancel(_ id: UUID) { tasks[id]?.cancel() }
    private func update(_ id: UUID, phase: SupervisorTaskPhase, progress: Double?, message: String?) { states[id]?.update(phase: phase, progress: progress, message: message) }
    private func fail(_ id: UUID, error: String) { states[id]?.error = error; states[id]?.update(phase: .failed, message: error) }
    private func removeTask(_ id: UUID) { tasks[id] = nil }
}
