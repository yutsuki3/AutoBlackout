// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AutoBlackout",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AutoBlackout",
            path: "Sources/AutoBlackout"
        )
    ]
)
