// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "conflux",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "conflux", targets: ["conflux"]),
        .executable(name: "conflux-bench", targets: ["conflux-bench"]),
    ],
    targets: [
        // Phase 1: the gateway, the scheduler and the llama-server host.
        .target(name: "ConfluxCore"),
        // The Mac app, and `conflux serve` without a window.
        .executableTarget(name: "conflux", dependencies: ["ConfluxCore"]),
        .testTarget(name: "ConfluxCoreTests", dependencies: ["ConfluxCore"]),

        // Phase 0: measure what one endpoint can do. See docs/phase-0.md.
        .target(name: "ConfluxBench"),
        .executableTarget(name: "conflux-bench", dependencies: ["ConfluxBench"]),
        .testTarget(name: "ConfluxBenchTests", dependencies: ["ConfluxBench"]),
    ]
)
