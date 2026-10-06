// swift-tools-version: 6.4
import Foundation
import PackageDescription

// v0.4.1 修订「占用」的口径与菜单栏的形态：
//
//   - 菜单栏图标不再每点一次开一个窗口。它弹一个简略信息台（CPU / GPU /
//     内存 / 网络 的 2×2 网格 + 逐站状态），主窗口只能从面板打开，
//     且全局只有一个实例（D39 的内核侧口径）。
//   - 首页四张卡改成"Phecda 自己占了多少"（内核 + 站点进程树），
//     GPU 仍然只能显示设备级利用率，因此明确标注"整机 GPU"。
//   - 启动不再自动打开主窗口：菜单栏常驻应用一启动就弹窗很打扰。
//
// v0.3.0 新增「远程访问」页（D38）：内核的远程面在界面上可开、可配、
// 可配对、可看设备与审计，并且能装 APNs 凭据去验证推送。
//
// v0.2.0 把 Phecda 收敛成纯 GUI：内核以 dylib 包体形式内嵌（D24），
// 运行时供给、应用部署与进程守护、指标与建议全部在 ISC-Core 里。
// 因此这里不再有 ISCSupervisor / PhecdaSupervisor 两个 target ——
// 曾经的 GUI 侧进程守护已经违反 D25（内核独占业务服务生命周期）。

// 内核库所在的绝对路径。
//
// # 为什么需要它
//
// `libisc.dylib` 的 install name 是 `@rpath/libisc.dylib`，因此客户端必须在
// 运行时找到它。下面那几条相对 rpath 覆盖的是 SwiftPM 的产物布局
// （`.build/out/Products/<config>/`，SwiftPM 会把 dylib 拷到可执行文件旁边）。
//
// 但 Xcode 的产物在 DerivedData 下，而 DerivedData 与源码目录**没有任何
// 相对关系** —— 从 `Build/Products/Debug` 往上走多少层都到不了仓库。于是
// 在 Xcode 里 Run 会直接挂在 dyld：Library not loaded。
//
// 因此把仓库里 Vendor/ISC 的绝对路径也加进 rpath。它只在"本机源码构建"时
// 有意义：分发出去的产物在没有这个路径的机器上，dyld 会自然落到后面那几条
// 相对 rpath 上，行为不受影响。
let vendorPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Vendor/ISC")
    .path

let package = Package(
    name: "ISC-Phecda",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "ISCPhecda", targets: ["ISCApp"]),
        .library(name: "ISCCore", targets: ["ISCCore"]),
    ],
    targets: [
        .systemLibrary(name: "CISC", path: "Vendor/ISC"),
        .target(
            name: "ISCCore",
            dependencies: ["CISC"],
            linkerSettings: [
                .unsafeFlags([
                    "-L", "Vendor/ISC", "-lisc",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../..",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../../Vendor/ISC",
                    "-Xlinker", "-rpath", "-Xlinker", vendorPath,
                ])
            ]
        ),
        .executableTarget(
            name: "ISCApp",
            dependencies: ["ISCCore"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        .testTarget(name: "ISCCoreTests", dependencies: ["ISCCore"]),
    ]
)
