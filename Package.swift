// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OmpUsageBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "OmpUsageBar", targets: ["OmpUsageBar"]),
        .executable(name: "NerfTrackCheck", targets: ["NerfTrackCheck"]),
        .library(name: "OmpUsageCore", targets: ["OmpUsageCore"]),
    ],
    targets: [
        .target(
            name: "OmpUsageCore",
            path: "Sources/OmpUsageCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "OmpUsageBar",
            dependencies: ["OmpUsageCore"],
            path: "Sources/OmpUsageBar"
        ),
        .executableTarget(
            name: "NerfTrackCheck",
            dependencies: ["OmpUsageCore"],
            path: "Sources/NerfTrackCheck"
        ),
        .testTarget(
            name: "OmpUsageCoreTests",
            dependencies: ["OmpUsageCore"],
            path: "Tests/OmpUsageCoreTests"
        ),
    ]
)
