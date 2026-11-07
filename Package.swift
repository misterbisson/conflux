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
        // llama.cpp, built by its project for Apple platforms. Pinned by
        // version and checksum: a tag can be moved, a checksum can't. Keep
        // LlamaRuntime.build in step with the version here.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b12110/llama-b12110-xcframework.zip",
            checksum: "fca702506b04cba11c7f1226056371d16ddfa80e1248da979166a1eec36c415f"
        ),

        // The gateway, the scheduler, and the hosts that run models.
        .target(name: "ConfluxCore", dependencies: ["llama"]),
        // The Mac app, and `conflux serve` without a window.
        .executableTarget(name: "conflux", dependencies: ["ConfluxCore"]),
        .testTarget(name: "ConfluxCoreTests", dependencies: ["ConfluxCore", "llama"]),

        // Phase 0: measure what one endpoint can do. See docs/phase-0.md.
        .target(name: "ConfluxBench"),
        .executableTarget(name: "conflux-bench", dependencies: ["ConfluxBench"]),
        .testTarget(name: "ConfluxBenchTests", dependencies: ["ConfluxBench"]),
    ]
)
