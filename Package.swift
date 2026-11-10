// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "KlangPlayer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "KlangPlayer", path: "Sources/KlangPlayer"),
        .testTarget(name: "KlangPlayerTests", dependencies: ["KlangPlayer"], path: "Tests/KlangPlayerTests"),
    ]
)
