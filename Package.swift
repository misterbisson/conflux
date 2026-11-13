// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "conflux",
    // macOS 27 and iPadOS 27: Apple's on-device model reads images from 27
    // (docs/plan.md, Phase 4).
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .executable(name: "conflux", targets: ["conflux"]),
        .executable(name: "conflux-bench", targets: ["conflux-bench"]),
        // For the Xcode app target in project.yml.
        .library(name: "ConfluxCore", targets: ["ConfluxCore"]),
        .library(name: "ConfluxUI", targets: ["ConfluxUI"]),
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

        // iroh, for connections between devices: QUIC with each device's
        // identity a public key. A static library behind a small C ABI, from
        // https://github.com/misterbisson/apple-iroh. Pinned by version and
        // checksum, like llama.
        .binaryTarget(
            name: "AppleIroh",
            url: "https://github.com/misterbisson/apple-iroh/releases/download/v0.10.0/AppleIroh.xcframework.zip",
            checksum: "15381c3650f98ab95cd3e2efcf552701be87cc2117ca46ace7566dc117bb346c"
        ),

        // The gateway, the scheduler, the hosts that run models, and the mesh.
        .target(
            name: "ConfluxCore",
            dependencies: ["llama", "AppleIroh"],
            // What apple-iroh's static library needs (its README).
            linkerSettings: [
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Network"),
                .linkedLibrary("c++"),
            ]
        ),
        // What the Mac app and the iPad app show the same way.
        .target(name: "ConfluxUI", dependencies: ["ConfluxCore"]),
        // The Mac app, and `conflux serve` without a window.
        .executableTarget(name: "conflux", dependencies: ["ConfluxCore", "ConfluxUI"]),
        .testTarget(name: "ConfluxCoreTests", dependencies: ["ConfluxCore", "llama"]),

        // Phase 0: measure what one endpoint can do. See docs/phase-0.md.
        .target(name: "ConfluxBench"),
        .executableTarget(name: "conflux-bench", dependencies: ["ConfluxBench"]),
        .testTarget(name: "ConfluxBenchTests", dependencies: ["ConfluxBench"]),
    ]
)
