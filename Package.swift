// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Reed",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "ReedCore", targets: ["ReedCore"]),
        .executable(name: "Reed", targets: ["Reed"])
    ],
    dependencies: [
        // Keep in step with the version in scripts/generate_project.py.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5")
    ],
    targets: [
        .target(name: "ReedCore", resources: [.process("Resources")]),
        .executableTarget(name: "Reed", dependencies: ["ReedCore", .product(name: "FluidAudio", package: "FluidAudio")]),
        .testTarget(name: "ReedCoreTests", dependencies: ["ReedCore"], resources: [.copy("Fixtures")])
    ]
)
