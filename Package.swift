// swift-tools-version:6.0
import PackageDescription

// The DSP code is also optimised in debug builds: the 30-minute drift simulation runs in the unit tests.
let optimizedC: [CSetting] = [.unsafeFlags(["-O2"], .when(configuration: .debug))]

let package = Package(
    name: "MicBridge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MicBridge", targets: ["MicBridge"]),
    ],
    targets: [
        // libsamplerate 0.2.2 (BSD-2-Clause), vendored unmodified; see Sources/CSampleRate/VENDORED.md.
        .target(
            name: "CSampleRate",
            path: "Sources/CSampleRate",
            exclude: ["COPYING", "VENDORED.md"],
            cSettings: [.define("HAVE_CONFIG_H")] + optimizedC
        ),
        // Real-time code only: IOProcs, ring buffer, resampling stage. Pure C, no allocation in callbacks.
        .target(
            name: "MicBridgeRT",
            dependencies: ["CSampleRate"],
            path: "Sources/MicBridgeRT",
            cSettings: optimizedC
        ),
        // Device matching, config, channel mapping (pure, testable) + the CoreAudio implementation.
        .target(
            name: "MicBridgeCore",
            dependencies: ["MicBridgeRT"],
            path: "Sources/MicBridgeCore",
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        // Agent + CLI.
        .executableTarget(
            name: "MicBridge",
            dependencies: ["MicBridgeCore"],
            path: "Sources/MicBridge"
        ),
        // Test-only C helpers: clock simulation driving the DSP stages, signal analysis, threaded ring stress.
        .target(
            name: "MicBridgeSim",
            dependencies: ["MicBridgeRT"],
            path: "Tests/MicBridgeSim",
            cSettings: optimizedC
        ),
        .testTarget(
            name: "MicBridgeCoreTests",
            dependencies: ["MicBridgeCore"],
            path: "Tests/MicBridgeCoreTests"
        ),
        .testTarget(
            name: "MicBridgeRTTests",
            dependencies: ["MicBridgeRT", "MicBridgeSim"],
            path: "Tests/MicBridgeRTTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
