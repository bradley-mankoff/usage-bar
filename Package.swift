// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UsageBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "UsageBar", targets: ["UsageBar"]),
        .library(name: "UsageCore", targets: ["UsageCore"]),
    ],
    targets: [
        .target(name: "UsageCore", path: "Sources/UsageCore"),
        .executableTarget(name: "UsageBar", dependencies: ["UsageCore"], path: "Sources/UsageBar"),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"], path: "Tests/UsageCoreTests"),
    ]
)
