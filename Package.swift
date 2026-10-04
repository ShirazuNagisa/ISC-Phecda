// swift-tools-version: 6.4
import PackageDescription

// v0.2.0 把 Phecda 收敛成纯 GUI：内核以 dylib 包体形式内嵌（D24），
// 运行时供给、应用部署与进程守护、指标与建议全部在 ISC-Core 里。
// 因此这里不再有 ISCSupervisor / PhecdaSupervisor 两个 target ——
// 曾经的 GUI 侧进程守护已经违反 D25（内核独占业务服务生命周期）。
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
