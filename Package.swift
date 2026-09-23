// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AutoBlackout",
    platforms: [.macOS(.v13)],
    targets: [
        // 状態遷移ロジック。実ディスプレイには一切触れず、プロトコル越しにのみ操作する。
        .target(
            name: "AutoBlackoutCore",
            path: "Sources/AutoBlackoutCore"
        ),
        // 実機との接点（非公開API・CGコールバック・UI）。
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
