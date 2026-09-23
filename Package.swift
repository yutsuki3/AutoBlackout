// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AutoBlackout",
    platforms: [.macOS(.v13)],
    targets: [
        // State-machine logic. Never touches a real display, only its protocol abstractions.
        .target(
            name: "AutoBlackoutCore",
            path: "Sources/AutoBlackoutCore"
        ),
        // The real-hardware surface (private API, CG callbacks, UI).
        .executableTarget(
            name: "AutoBlackout",
            dependencies: ["AutoBlackoutCore"],
            path: "Sources/AutoBlackout"
        ),
        // Tests for the parts of the executable that don't touch a real display (logger, state
        // store, diagnostics formatting, host info).
        .testTarget(
            name: "AutoBlackoutTests",
            dependencies: ["AutoBlackout", "AutoBlackoutCore"],
            path: "Tests/AutoBlackoutTests"
        ),
        .testTarget(
            name: "AutoBlackoutCoreTests",
            dependencies: ["AutoBlackoutCore"],
            path: "Tests/AutoBlackoutCoreTests"
        ),
    ]
)
