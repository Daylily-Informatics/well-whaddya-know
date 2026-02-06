// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "WellWhaddyaKnow",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "Storage",
            targets: ["Storage"]
        ),
        .library(
            name: "Sensors",
            targets: ["Sensors"]
        ),
        .library(
            name: "CoreModel",
            targets: ["CoreModel"]
        ),
        .library(
            name: "Timeline",
            targets: ["Timeline"]
        ),
        .library(
            name: "XPCProtocol",
            targets: ["XPCProtocol"]
        ),
        .library(
            name: "Reporting",
            targets: ["Reporting"]
        ),
        .executable(
            name: "wwkd",
            targets: ["WellWhaddyaKnowAgent"]
        ),
        .executable(
            name: "wwk",
            targets: ["WellWhaddyaKnowCLI"]
        ),
        .executable(
            name: "WellWhaddyaKnow",
            targets: ["WellWhaddyaKnowApp"]
        ),
    ],
    dependencies: [
        // Swift Testing from release/6.0 branch, compatible with Swift 6.0
        .package(url: "https://github.com/apple/swift-testing.git", branch: "release/6.0"),
        // ArgumentParser for CLI
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        // Shared/Storage module
        .target(
            name: "Storage",
            path: "Sources/Shared/Storage"
        ),

        // Shared/Sensors module - macOS sensor wrappers
        .target(
            name: "Sensors",
            dependencies: [],
            path: "Sources/Shared/Sensors"
        ),

        // Shared/CoreModel module - in-memory types for timeline processing
        .target(
            name: "CoreModel",
            dependencies: [],
            path: "Sources/Shared/CoreModel"
        ),

        // Shared/Timeline module - deterministic timeline builder
        .target(
            name: "Timeline",
            dependencies: ["CoreModel"],
            path: "Sources/Shared/Timeline"
        ),

        // Shared/XPCProtocol module - XPC interface definitions
        .target(
            name: "XPCProtocol",
            dependencies: ["CoreModel"],
            path: "Sources/Shared/XPCProtocol"
        ),

        // Shared/Reporting module - CSV/JSON export
        .target(
            name: "Reporting",
            dependencies: ["CoreModel", "Timeline"],
            path: "Sources/Shared/Reporting"
        ),

        // WellWhaddyaKnowAgent - background daemon (wwkd)
        .executableTarget(
            name: "WellWhaddyaKnowAgent",
            dependencies: ["Storage", "Sensors", "CoreModel", "Timeline", "XPCProtocol", "Reporting"],
            path: "Sources/WellWhaddyaKnowAgent",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),

        // WellWhaddyaKnowCLI - command line interface (wwk)
        .executableTarget(
            name: "WellWhaddyaKnowCLI",
            dependencies: [
                "Storage",
                "CoreModel",
                "Timeline",
                "XPCProtocol",
                "Reporting",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/WellWhaddyaKnowCLI",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),

        // WellWhaddyaKnowApp - menu bar application
        .executableTarget(
            name: "WellWhaddyaKnowApp",
            dependencies: [
                "Storage",
                "CoreModel",
                "Timeline",
                "XPCProtocol",
                "Reporting",
            ],
            path: "Sources/WellWhaddyaKnowApp",
            exclude: [
                "Info.plist",
                "WellWhaddyaKnow.entitlements",
                "LaunchAgents",
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),

        // Storage unit tests
        .testTarget(
            name: "StorageTests",
            dependencies: [
                "Storage",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/Unit/StorageTests",
            sources: ["StorageTests.swift", "ImmutabilityTests.swift", "ForeignKeyTests.swift", "MigrationTests.swift"]
        ),

        // Sensors unit tests
        .testTarget(
            name: "SensorTests",
            dependencies: [
                "Sensors",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/Unit/SensorTests"
        ),

        // Agent unit tests
        .testTarget(
            name: "AgentTests",
            dependencies: [
                "WellWhaddyaKnowAgent",
                "Storage",
                "Sensors",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/Unit/AgentTests"
        ),

        // CoreModel unit tests
        .testTarget(
            name: "CoreModelTests",
            dependencies: [
                "CoreModel",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/Unit/CoreModelTests"
        ),

        // Timeline unit tests
        .testTarget(
            name: "TimelineTests",
            dependencies: [
                "Timeline",
                "CoreModel",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/Unit/TimelineTests"
        ),

        // Reporting unit tests
        .testTarget(
            name: "ReportingTests",
            dependencies: [
                "Reporting",
                "Timeline",
                "CoreModel",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/Unit/ReportingTests"
        ),

        // XPC integration tests
        .testTarget(
            name: "XPCTests",
            dependencies: [
                "WellWhaddyaKnowAgent",
                "XPCProtocol",
                "Reporting",
                "Timeline",
                "CoreModel",
                "Storage",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/Integration/XPCTests"
        ),

        // Menu bar UI unit tests
        .testTarget(
            name: "MenuBarUITests",
            dependencies: [
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/Unit/MenuBarUITests"
        ),

        // CLI unit tests
        .testTarget(
            name: "CLITests",
            dependencies: [
                "WellWhaddyaKnowCLI",
                "Storage",
                "CoreModel",
                "Timeline",
                "XPCProtocol",
                "Reporting",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/Unit/CLITests"
        ),
    ]
)

