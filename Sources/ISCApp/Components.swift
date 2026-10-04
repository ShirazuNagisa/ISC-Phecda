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
///
/// 三张卡必须**一样高**。此前网络那张少一行（CPU 与内存有占比条、网络没有），
/// 于是它比另外两张矮一截 —— 并排的三张卡参差不齐，看起来像是网络那张
/// 出了问题。修法不是给它硬塞一个没有意义的占比条，而是让第三行**两种形态
/// 高度一致**：有占比就画条，没有就放一行说明。
struct MetricCard: View {
    /// 第三行显示什么。
    enum Detail {
        /// 0...1 的占比。
        case fraction(Double)
        /// 一行说明（用在没有占比可言的指标上，例如网络速率）。
        case text(String)
    }

    let title: String
    let value: String
    /// 第三行。
    let detail: Detail
    /// 第四行：补充说明。
    let caption: String?
    let symbol: String
    let tint: Color

    /// 第三行的固定高度。
    ///
    /// 写死是刻意的：`ProgressView` 与一行文字的自然高度不同，靠它们各自
    /// 撑出来的高度就不可能一致，而"一致"正是这里要的东西。
    private let detailHeight: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1)
                .minimumScaleFactor(0.6)
            Group {
                switch detail {
                case .fraction(let fraction):
                    ProgressView(value: min(max(fraction, 0), 1)).tint(tint)
                case .text(let text):
                    Text(text).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(height: detailHeight)
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
                    // 建议的正文常常是底层工具的原样报错（可能很长且没有空格），
                    // 必须按可用宽度换行，而不是反过来要求更多宽度。
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
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

    /// 正文的最大宽度。
    ///
    /// 这个上限不是为了好看，是为了**别把左侧栏挤没**：正文里常常是服务商
    /// 或内核抛回来的错误（一条长得没有空格可断的 URL），而 Text 的理想宽度
    /// 就是它一行排开的宽度。理想宽度会一路往上传，NavigationSplitView 只好
    /// 从侧栏抽宽度去满足它 —— 结果就是 DNS 服务商一出错，整个左侧栏变空。
    /// 给正文钉一个上限，这条传导链就断了。
    static let messageMaxWidth: CGFloat = 460

    /// 行数上限。宽度上限挡不住"在零宽提案下算出几百行高"这种情况，
    /// 行数上限可以 —— 两个方向都钉住，正文才彻底不参与布局博弈。
    static let messageMaxLines = 8

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .lineLimit(Self.messageMaxLines)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 0, maxWidth: Self.messageMaxWidth)
                .clipped()
            if let action {
                Button(action.label, action: action.run).buttonStyle(.glassProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
