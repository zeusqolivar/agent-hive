// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentHive",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HiveCore", targets: ["HiveCore"]),
        .executable(name: "HiveApp", targets: ["HiveApp"]),
    ],
    targets: [
        .target(name: "HiveCore"),
        .executableTarget(
            name: "HiveApp",
            dependencies: ["HiveCore"],
            exclude: ["Info.plist"],
            resources: [.copy("Resources/web")]
        ),
        .testTarget(
            name: "HiveCoreTests",
            dependencies: ["HiveCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
