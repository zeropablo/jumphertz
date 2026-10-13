// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MicBridge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MicBridge", targets: ["MicBridge"]),
    ],
    targets: [
        // Real-time code only: the IOProc and the atomics it reads. Pure C, no allocation in the callback.
        .target(
            name: "MicBridgeRT",
            path: "Sources/MicBridgeRT"
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
        .testTarget(
            name: "MicBridgeCoreTests",
            dependencies: ["MicBridgeCore"],
            path: "Tests/MicBridgeCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
