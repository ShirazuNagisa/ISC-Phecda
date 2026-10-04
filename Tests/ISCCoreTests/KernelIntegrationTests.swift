import Foundation
import Testing
@testable import ISCCore

/// 端到端跑通真实的 C ABI：vendored 内核、它的 HTTP 处理器与 SQLite。
///
/// 单元测试锁住的是**接口形状**，这个测试锁住的是那个形状存在的**理由** ——
/// 一份源码目录真的能被识别、被登记、被启动起来。
///
/// `libisc` 每进程只允许一个内核实例，因此整条流程放在一个测试里，
/// 并且每条退出路径都要把它停掉。
@Test func hostingFlowEndToEnd() async throws {
    let kernel = KernelClient()
    let workspace = FileManager.default.temporaryDirectory
        .appendingPathComponent("isc-phecda-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }

    // 版本不匹配是最严重的一类故障：每一屏都空着，而用户不知道原因。
    // 因此在启动之前就必须能判断出来。
    #expect(try KernelClient.interfaceVersion() == KernelClient.requiredAPIVersion)

    _ = try await kernel.start(dataDirectory: workspace.path)
    do {
        try await exerciseHosting(kernel, workspace: workspace)
    } catch {
        _ = try? await kernel.stop()
        throw error
    }
    _ = try? await kernel.stop()
}

private func exerciseHosting(_ kernel: KernelClient, workspace: URL) async throws {
    // 1. 内核认得出这是静态站点，并给出依据。
    try write("<h1>hi</h1>", to: workspace.appendingPathComponent("index.html"))
    let inspection = try await kernel.inspectSource(path: workspace.path)
    #expect(inspection.recommendedPresetId == "static-html")
    #expect(inspection.evidence.contains { $0.file == "index.html" })

    // 2. 预设目录里既有各类技术栈，也有自定义服务器这条兜底。
    let presets = try await kernel.presets()
    #expect(presets.contains { $0.id == "static-html" })
    #expect(presets.contains { $0.id == "custom" })
    let staticPreset = try #require(presets.first { $0.id == "static-html" })
    #expect(staticPreset.isStatic)

    // 3. 登记一个站点：只登记，不执行任何构建。
    var request = AppCreateRequest(name: "集成测试站点", presetId: "static-html", sourcePath: workspace.path)
    request.autoStart = true
    let app = try await kernel.createApp(request)
    #expect(app.state == "draft")
    #expect(app.localPort > 1023, "内核必须分配一个非特权端口")
    #expect(app.isStatic)

    // 4. 列表与详情读得到同一条记录。
    let listed = try await kernel.apps()
    #expect(listed.contains { $0.id == app.id })
    #expect(try await kernel.app(app.id).name == "集成测试站点")

    // 5. 部署：静态站点不需要任何运行时，因此这一步既不下载也不构建。
    let accepted = try await kernel.deployApp(app.id)
    #expect(!accepted.jobId.isEmpty)

    // 6. 等它真的可用。任务可能在部署完成前就返回（202），因此这里轮询
    //    的是**站点状态**而不是任务状态 —— 前者才是用户关心的东西。
    //
    //    条件是"running **且** healthy"，而不是只看 state：内核先把状态置为
    //    running，再去等健康检查（它可能长达一分钟）。只看 state 会读到
    //    一个刚起来、其实还没能提供服务的中间态。
    let running = try await waitForApp(kernel, id: app.id, timeout: .seconds(30)) {
        $0.state == "running" && $0.health == "healthy"
    }
    #expect(running.state == "running")
    #expect(try await kernel.stopApp(app.id) == ())
    let stopped = try await kernel.app(app.id)
    #expect(stopped.state == "stopped")

    // 7. 运行时的清单能读，且不会为不存在的类型凭空造出条目。
    let runtimes = try await kernel.runtimes()
    #expect(runtimes.allSatisfy { !$0.kind.isEmpty })

    // 8. 只读的两个看板接口：指标可能"不支持"，但绝不能报错。
    let metrics = try await kernel.metrics()
    #expect(metrics.host.cpuPercent >= 0)
    let advisories = try await kernel.advisories()
    #expect(advisories.allSatisfy { !$0.title.isEmpty })

    // 9. 删除是幂等的，并且会先停掉它。
    try await kernel.deleteApp(app.id)
    #expect(try await kernel.apps().contains { $0.id == app.id } == false)
}

private func write(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url)
}

/// 轮询直到站点满足条件。
///
/// 部署是异步的（接口返回 202），因此"部署成功"只能由站点自己的状态
/// 来证明，而不是由接口返回了什么。
private func waitForApp(
    _ kernel: KernelClient, id: String, timeout: Duration,
    until satisfied: (AppRecord) -> Bool
) async throws -> AppRecord {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    var latest = try await kernel.app(id)
    while ContinuousClock.now < deadline {
        latest = try await kernel.app(id)
        if satisfied(latest) { return latest }
        if latest.state == "failed" {
            throw KernelError(code: "deploy_failed", message: latest.lastError ?? "the app entered the failed state")
        }
        try await Task.sleep(for: .milliseconds(200))
    }
    throw KernelError(code: "timeout", message: "the app stayed in \(latest.state)/\(latest.health) for \(timeout)")
}
