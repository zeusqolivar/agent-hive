// swift-tools-version: 6.0
import PackageDescription

// Two platforms build from this one manifest.
//
// On macOS everything is as it was: the HiveCore library, the HiveApp SwiftUI executable, and the tests.
// On Windows the Mac app cannot build at all (it imports SwiftUI, AppKit and WebKit), and SwiftPM has no
// per-platform target switch. So the app's product and target are declared only on macOS: `Package.swift` is
// Swift, and it is compiled for the host. That keeps every file under `Sources/HiveApp` untouched rather than
// wrapping a thousand lines in `#if os(macOS)`, and it leaves `swift build` and `scripts/bundle.sh` working
// unchanged on the Mac.
//
// Windows adds two C targets that HiveCore only depends on there:
//   CSQLite     the SQLite amalgamation, because Windows has no system SQLite module to import.
//   CWinProcess NtQueryInformationProcess(ProcessCommandLineInformation), which WinSDK does not expose.
var products: [Product] = [
    .library(name: "HiveCore", targets: ["HiveCore"]),
    // The headless helper the Windows shell talks to (phase 2). It builds on macOS too, which is how the
    // protocol's tests and a `--dump` comparison run there.
    .executable(name: "hive-core", targets: ["HiveCoreHelper"]),
]
var targets: [Target] = [
    .target(
        name: "HiveCore",
        dependencies: [
            .target(name: "CSQLite", condition: .when(platforms: [.windows])),
            .target(name: "CWinProcess", condition: .when(platforms: [.windows])),
        ]
    ),
    // The amalgamation is public-domain SQLite 3.54.1 (2026-06-05), https://sqlite.org/download.html.
    // Regenerate by replacing Sources/CSQLite/sqlite3.c and sqlite3.h from that zip.
    .target(name: "CSQLite", path: "Sources/CSQLite"),
    .target(name: "CWinProcess", path: "Sources/CWinProcess",
            linkerSettings: [.linkedLibrary("ntdll")]),
    .executableTarget(name: "HiveCoreHelper", dependencies: ["HiveCore"]),
    .testTarget(
        name: "HiveCoreTests",
        dependencies: [
            "HiveCore",
            .target(name: "CSQLite", condition: .when(platforms: [.windows])),
            .target(name: "CWinProcess", condition: .when(platforms: [.windows])),
        ],
        resources: [.copy("Fixtures")]
    ),
]

#if os(macOS)
products.append(.executable(name: "HiveApp", targets: ["HiveApp"]))
targets.append(
    .executableTarget(
        name: "HiveApp",
        dependencies: ["HiveCore"],
        exclude: ["Info.plist", "Resources/AppIcon.icns"],
        resources: [.copy("Resources/web")]
    )
)
#endif

let package = Package(
    name: "AgentHive",
    platforms: [.macOS(.v15)],
    products: products,
    targets: targets
)
