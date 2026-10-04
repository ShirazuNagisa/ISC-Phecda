import SwiftUI
import ISCCore

/// 站点的状态色。
///
/// 只按状态给颜色，不按"用户希望它是什么样"给 —— 一个 failed 的站点
/// 不应该看起来和 running 的一样。
extension String {
    var stateColor: Color {
        switch self {
        case "running": .green
        case "failed": .red
        case "stopped", "draft": .secondary
        case "provisioning", "installing", "building", "starting", "stopping": .orange
        default: .secondary
        }
    }

    var stateLabel: String {
        switch self {
        case "draft": tr("未部署", "Not deployed")
        case "provisioning": tr("准备运行时", "Preparing runtime")
        case "installing": tr("安装依赖", "Installing")
        case "building": tr("构建中", "Building")
        case "starting": tr("启动中", "Starting")
        case "running": tr("运行中", "Running")
        case "stopping": tr("停止中", "Stopping")
        case "stopped": tr("已停止", "Stopped")
        case "failed": tr("失败", "Failed")
        default: self
        }
    }

    var healthSymbol: String {
        switch self {
        case "healthy": "checkmark.circle.fill"
        case "unhealthy": "exclamationmark.triangle.fill"
        case "starting": "clock"
        default: "questionmark.circle"
        }
    }

    var healthColor: Color {
        switch self {
        case "healthy": .green
        case "unhealthy": .orange
        default: .secondary
        }
    }

    var severityColor: Color {
        switch self {
        case "blocking": .red
        case "warning": .orange
        default: .blue
        }
    }

    var severitySymbol: String {
        switch self {
        case "blocking": "exclamationmark.octagon.fill"
        case "warning": "exclamationmark.triangle.fill"
        default: "info.circle.fill"
        }
    }
}

struct StatePill: View {
    let state: String
    let health: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(state.stateColor).frame(width: 7, height: 7)
            Text(state.stateLabel).font(.caption).foregroundStyle(.secondary)
            if state == "running" {
                Image(systemName: health.healthSymbol)
                    .font(.caption2)
                    .foregroundStyle(health.healthColor)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.quaternary.opacity(0.4), in: .capsule)
    }
}

/// 首页上的一张指标卡。
struct MetricCard: View {
    let title: String
    let value: String
    let caption: String?
    let symbol: String
    let tint: Color
    /// 0...1 的占比；为 nil 时不画进度条。
    var fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            if let fraction {
                ProgressView(value: min(max(fraction, 0), 1)).tint(tint)
            }
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

/// 一条建议。
struct AdvisoryRow: View {
    let advisory: Advisory
    let apply: (Advisory) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: advisory.severity.severitySymbol)
                .foregroundStyle(advisory.severity.severityColor)
                .font(.callout)
            VStack(alignment: .leading, spacing: 3) {
                Text(advisory.title).font(.callout.weight(.medium))
                if let detail = advisory.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if let action = advisory.action {
                Button(action.label) { apply(advisory) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(advisory.severity.severityColor.opacity(0.07), in: .rect(cornerRadius: 10))
    }
}

struct EmptyHint: View {
    let symbol: String
    let title: String
    let message: String
    var action: (label: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let action {
                Button(action.label, action: action.run).buttonStyle(.glassProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
