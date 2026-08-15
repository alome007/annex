// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HAOSRunner",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "HAOSRunner",
            path: "Sources/HAOSRunner"
        ),
        .testTarget(
            name: "HAOSRunnerTests",
            dependencies: ["HAOSRunner"],
            path: "Tests/HAOSRunnerTests"
        ),
    ]
)
