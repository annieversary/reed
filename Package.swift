// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Reed",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "ReedCore", targets: ["ReedCore"]),
        .executable(name: "Reed", targets: ["Reed"])
    ],
    targets: [
        .target(name: "ReedCore", resources: [.process("Resources")]),
        .executableTarget(name: "Reed", dependencies: ["ReedCore"]),
        .testTarget(name: "ReedCoreTests", dependencies: ["ReedCore"], resources: [.copy("Fixtures")])
    ]
)
