// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ISC-Phecda",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "ISCPhecda", targets: ["ISCApp"]), .executable(name: "PhecdaSupervisor", targets: ["PhecdaSupervisor"]), .library(name: "ISCCore", targets: ["ISCCore"]), .library(name: "ISCSupervisor", targets: ["ISCSupervisor"])],
    targets: [
        .systemLibrary(name: "CISC", path: "Vendor/ISC"),
        // Kernel lookup paths, all relative to the loading binary so the product stays
        // relocatable — never an absolute path from the machine that happened to build it.
        // Each entry serves one layout, and unused entries are simply skipped by dyld:
        //   @executable_path/../Frameworks     the .app bundle built by Scripts/build-app.sh
        //   @loader_path/../../..              a test bundle loading the copy in the products
        //                                      directory that Scripts/test.sh places
        //   @loader_path/../../../../Vendor/ISC  an executable run straight from the checkout
        // SwiftPM additionally contributes `@loader_path` for a copy beside the executable.
        .target(name: "ISCCore", dependencies: ["CISC"], linkerSettings: [.unsafeFlags(["-L", "Vendor/ISC", "-lisc", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks", "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../..", "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../../Vendor/ISC"])]),
        .target(name: "ISCSupervisor"),
        .executableTarget(name: "PhecdaSupervisor", dependencies: ["ISCSupervisor"]),
        .executableTarget(name: "ISCApp", dependencies: ["ISCCore", "ISCSupervisor"], swiftSettings: [.defaultIsolation(MainActor.self), .enableUpcomingFeature("NonisolatedNonsendingByDefault")]),
        .testTarget(name: "ISCCoreTests", dependencies: ["ISCCore"]),
        .testTarget(name: "ISCSupervisorTests", dependencies: ["ISCSupervisor"])
    ]
)
