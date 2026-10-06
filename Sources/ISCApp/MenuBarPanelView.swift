import SwiftUI
import AppKit
import ISCCore

/// 菜单栏点击后弹出的简略信息台。
///
/// # 它回答什么、不回答什么
///
/// 只回答"现在怎么样"：这套东西自己占了多少、站点都在什么状态。
/// 任何需要点进去操作的事情都留给主窗口 —— 面板一旦开始承担导航，
/// 就会长成第二个界面，而菜单栏弹出的东西不该需要用户做决定。
///
/// # 一行两个、两行
///
/// 四个指标排成 2×2：CPU / GPU 一行，内存 / 网络 一行。刻意不做成
/// 一行四列 —— 那样每格只剩三十来点宽，数字会被截断成"1.2…"。
struct MenuBarPanelView: View {
    @Bindable var model: AppModel
    let openMainWindow: () -> Void
    let quit: () -> Void

    /// 面板最多列几个站点。
    ///
    /// 超过就折成一行"还有 n 个"：菜单栏面板一旦可以滚动，它就不再是
    /// "一眼看完"的东西了，用户不如直接开主窗口。
    private let maxSites = 6

    private var sites: [SiteStatus] { model.apps.map(SiteStatus.init) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            metrics
            if !sites.isEmpty { Divider(); siteList }
            Divider()
            actions
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "network").foregroundStyle(.tint)
            Text("ISC Phecda").font(.headline)
            Spacer(minLength: 8)
            Text(phaseText).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var phaseText: String {
        switch model.phase {
        case .running: tr("运行中", "Running")
        case .starting: tr("启动中", "Starting")
        case .stopping: tr("正在停止", "Stopping")
        case .failed: tr("内核异常", "Kernel failed")
        case .stopped: tr("内核未运行", "Kernel stopped")
        }
    }

    // MARK: - 2×2 指标

    private var footprint: FootprintMetrics? { model.metrics?.footprint }
    private var gpu: GpuMetrics? { model.metrics?.host.gpu }

    private var metrics: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                PanelMetric(title: "CPU",
                            value: cpuValue,
                            fraction: footprint?.cpuFraction,
                            note: footprint == nil ? tr("暂无数据", "No data") : nil,
                            tint: .blue)
                PanelMetric(title: "GPU",
                            value: gpuValue,
                            fraction: gpu?.utilizationPercent.map { min(1, max(0, $0 / 100)) },
                            note: gpuNote,
                            tag: tr("整机", "Device"),
                            tint: .orange)
            }
            GridRow {
                PanelMetric(title: tr("内存", "Memory"),
                            value: footprint?.memoryBytes.formattedBytes ?? "—",
                            fraction: nil,
                            note: footprint == nil ? tr("暂无数据", "No data") : nil,
                            tint: .purple)
                PanelMetric(title: tr("网络", "Network"),
                            value: netValue,
                            fraction: nil,
                            note: netNote,
                            tint: .teal)
            }
        }
    }

    private var cpuValue: String {
        guard let footprint else { return "—" }
        return footprint.cpuPercent.formattedPercent
    }

    /// GPU 是三态的，缺一样都会骗人：
    /// 没有 GPU 字段 = 这台机器没有可采样的加速器；`unsupported` = 平台
    /// 没实现；有 backend 但没数值 = 这次没读到。
    private var gpuValue: String {
        guard let gpu, gpu.isSupported, let utilization = gpu.utilizationPercent else { return "—" }
        return utilization.formattedPercent
    }

    private var gpuNote: String? {
        guard let gpu else { return tr("无 GPU", "No GPU") }
        if !gpu.isSupported { return tr("不支持", "Unsupported") }
        if gpu.utilizationPercent == nil { return tr("未读到", "No reading") }
        return nil
    }

    /// 网络也是三态，而且"没读到"必须显示成"未读到"而不是 0 ——
    /// 0 会让用户以为 Phecda 根本不占网络。
    private var netValue: String {
        guard let footprint, footprint.hasNetwork, let rx = footprint.netRxBytesPerSec else {
            return "—"
        }
        return rx.formattedRate
    }

    private var netNote: String? {
        guard let footprint else { return tr("暂无数据", "No data") }
        if footprint.hasNetwork, let tx = footprint.netTxBytesPerSec {
            return tr("↑ \(tx.formattedRate)", "↑ \(tx.formattedRate)")
        }
        switch footprint.netBackend {
        case "unsupported": return tr("不支持", "Unsupported")
        case "unavailable": return tr("未读到", "No reading")
        default: return tr("暂无数据", "No data")
        }
    }

    // MARK: - 站点

    private var siteList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(sites.prefix(maxSites)) { site in
                HStack(spacing: 7) {
                    Circle().fill(site.color).frame(width: 6, height: 6)
                    Text(site.name).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(site.label).font(.caption).foregroundStyle(.secondary)
                }
            }
            if sites.count > maxSites {
                Text(tr("还有 \(sites.count - maxSites) 个站点",
                        "\(sites.count - maxSites) more"))
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 底部

    private var actions: some View {
        HStack {
            Button(tr("打开主窗口", "Open window"), action: openMainWindow)
                .buttonStyle(.glass)
            Spacer()
            Button(tr("退出", "Quit"), action: quit)
                .buttonStyle(.glass)
        }
        .controlSize(.small)
    }
}

/// 面板里的一格指标。
///
/// `note` 非空表示"这个数现在没有"，此时**不显示** value：把"不支持"
/// 和"0%"并排放在一起，用户只会记住那个 0。
private struct PanelMetric: View {
    let title: String
    let value: String
    let fraction: Double?
    let note: String?
    var tag: String? = nil
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                if let tag {
                    // "整机"这个角标不是装饰：GPU 是设备级的，而同一排的
                    // CPU 是 Phecda 自己的。不标出来就是把两种口径并排
                    // 摆着让用户自己猜。
                    Text(tag)
                        .font(.system(size: 9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(tint.opacity(0.15), in: .capsule)
                        .foregroundStyle(tint)
                }
                Spacer(minLength: 0)
            }
            Text(note ?? value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(note == nil ? .primary : .secondary)
            if let fraction {
                ProgressView(value: fraction).tint(tint).controlSize(.small)
            } else {
                // 占位：让有进度条和没进度条的格子一样高，
                // 否则 2×2 网格会参差不齐。
                Color.clear.frame(height: 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 一个站点在面板里的状态。
///
/// # 为什么是四类而不是三类
///
/// 内核有 8 个状态。硬压成"运行中/中断/未运行"三类的话，"正在部署"
/// 只能被塞进"运行中"（骗人：它还没起来）或"未运行"（也骗人：它正在动）。
/// 因此保留第四类"部署中"，只在实际出现时显示。
struct SiteStatus: Identifiable {
    enum Kind {
        case running, interrupted, stopped, deploying
    }

    let id: String
    let name: String
    let kind: Kind

    init(_ app: AppRecord) {
        id = app.id
        name = app.name
        switch app.state {
        case "running":
            // 起来了但健康检查不过，是"中断"而不是"运行中" —— 用户
            // 需要知道的正是这个区别。
            kind = app.health == "unhealthy" ? .interrupted : .running
        case "failed":
            kind = .interrupted
        case "stopped":
            kind = .stopped
        default:
            kind = app.isBusy ? .deploying : .stopped
        }
    }

    var label: String {
        switch kind {
        case .running: tr("运行中", "Running")
        case .interrupted: tr("中断", "Interrupted")
        case .stopped: tr("未运行", "Stopped")
        case .deploying: tr("部署中", "Deploying")
        }
    }

    var color: Color {
        switch kind {
        case .running: .green
        case .interrupted: .red
        case .stopped: .secondary
        case .deploying: .blue
        }
    }
}
