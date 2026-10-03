import SwiftUI
import ISCSupervisor

struct SupervisorTasksView: View {
    let model: AppModel
    @State private var tasks: [SupervisorTaskState] = []
    @State private var message: String?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(tr("Supervisor 任务", "Supervisor tasks")).font(.largeTitle.bold())
                Spacer()
                Button { load() } label: { Image(systemName: "arrow.clockwise") }.help(tr("刷新任务", "Refresh tasks"))
            }
            if let message { Text(message).foregroundStyle(.secondary) }
            if tasks.isEmpty && !loading {
                ContentUnavailableView(tr("暂无 Supervisor 任务", "No Supervisor tasks"), systemImage: "checklist")
            } else {
                List(tasks) { task in
                    HStack(spacing: 12) {
                        Image(systemName: icon(for: task.phase)).foregroundStyle(color(for: task.phase))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(task.kind).font(.headline)
                            Text(task.message ?? task.phase.rawValue).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ProgressView(value: task.progress).frame(width: 110)
                        Text(task.phase.rawValue).font(.caption.monospaced())
                        if task.phase == .queued || task.phase == .running || task.phase == .building || task.phase == .installingDependencies || task.phase == .starting {
                            Button { cancel(task.id) } label: { Image(systemName: "stop.circle") }.buttonStyle(.borderless).help(tr("取消任务", "Cancel task"))
                        }
                    }.padding(.vertical, 5)
                }
            }
        }
        .padding(24)
        .task { load() }
    }

    private func load() {
        guard let client = model.supervisorClient else { message = tr("独立 Supervisor 未运行。", "Independent Supervisor is unavailable."); return }
        loading = true
        Task {
            do { tasks = try await client.list().jobs ?? []; message = nil }
            catch let caught { message = caught.localizedDescription }
            loading = false
        }
    }

    private func cancel(_ id: UUID) {
        guard let client = model.supervisorClient else { return }
        Task {
            do { try await client.cancel(id); load() }
            catch let caught { message = caught.localizedDescription }
        }
    }

    private func icon(for phase: SupervisorTaskPhase) -> String {
        switch phase { case .completed: "checkmark.circle.fill"; case .failed: "xmark.octagon.fill"; case .cancelled: "stop.circle.fill"; case .running: "play.circle.fill"; default: "clock" }
    }
    private func color(for phase: SupervisorTaskPhase) -> Color {
        switch phase { case .completed: .green; case .failed: .red; case .cancelled: .orange; default: .secondary }
    }
}
