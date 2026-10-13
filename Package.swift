// swift-tools-version:6.0
import PackageDescription

// The DSP code is also optimised in debug builds: the 30-minute drift simulation runs in the unit tests.
let optimizedC: [CSetting] = [.unsafeFlags(["-O2"], .when(configuration: .debug))]

let package = Package(
    name: "Jumphertz",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Jumphertz", targets: ["Jumphertz"]),
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
            name: "JumphertzRT",
            dependencies: ["CSampleRate"],
            path: "Sources/JumphertzRT",
            cSettings: optimizedC
        ),
        // Device matching, config, channel mapping (pure, testable) + the CoreAudio implementation.
        .target(
            name: "JumphertzCore",
            dependencies: ["JumphertzRT"],
            path: "Sources/JumphertzCore",
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        // Agent + CLI.
        .executableTarget(
            name: "Jumphertz",
            dependencies: ["JumphertzCore"],
            path: "Sources/Jumphertz"
        ),
        // Test-only C helpers: clock simulation driving the DSP stages, signal analysis, threaded ring stress.
        .target(
            name: "JumphertzSim",
            dependencies: ["JumphertzRT"],
            path: "Tests/JumphertzSim",
            cSettings: optimizedC
        ),
        .testTarget(
            name: "JumphertzCoreTests",
            dependencies: ["JumphertzCore"],
            path: "Tests/JumphertzCoreTests"
        ),
        // Runs the built `Jumphertz` binary the way users do (through PATH, a symlink, another directory).
        .testTarget(
            name: "JumphertzCLITests",
            dependencies: ["Jumphertz"],
            path: "Tests/JumphertzCLITests"
        ),
        .testTarget(
            name: "JumphertzRTTests",
            dependencies: ["JumphertzRT", "JumphertzSim"],
            path: "Tests/JumphertzRTTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
