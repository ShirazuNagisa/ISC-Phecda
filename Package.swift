// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ISC-Phecda",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "ISCPhecda", targets: ["ISCApp"]), .library(name: "ISCCore", targets: ["ISCCore"])],
    targets: [
        .systemLibrary(name: "CISC", path: "Vendor/ISC"),
        .target(name: "ISCCore", dependencies: ["CISC"], linkerSettings: [.unsafeFlags(["-L", "Vendor/ISC", "-lisc", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../Vendor/ISC", "-Xlinker", "-rpath", "-Xlinker", "/Users/shirazu/Documents/project/ISC-Phecda/Vendor/ISC"])]),
        .executableTarget(name: "ISCApp", dependencies: ["ISCCore"], swiftSettings: [.defaultIsolation(MainActor.self), .enableUpcomingFeature("NonisolatedNonsendingByDefault")]),
        .testTarget(name: "ISCCoreTests", dependencies: ["ISCCore"])
    ]
)
