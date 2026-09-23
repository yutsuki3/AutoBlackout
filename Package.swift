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
        .testTarget(
            name: "AutoBlackoutCoreTests",
            dependencies: ["AutoBlackoutCore"],
            path: "Tests/AutoBlackoutCoreTests"
        ),
    ]
)
