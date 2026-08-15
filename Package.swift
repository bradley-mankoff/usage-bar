// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OmpUsageBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "OmpUsageBar", path: "Sources/OmpUsageBar")
    ]
)
