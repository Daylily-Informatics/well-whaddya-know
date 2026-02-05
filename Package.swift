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
    ],
    dependencies: [
        // Swift Testing from release/6.0 branch, compatible with Swift 6.0
        .package(url: "https://github.com/apple/swift-testing.git", branch: "release/6.0"),
    ],
    targets: [
        // Shared/Storage module
        .target(
            name: "Storage",
            path: "Sources/Shared/Storage"
        ),

        // Unit tests using Swift Testing
        .testTarget(
            name: "StorageTests",
            dependencies: [
                "Storage",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/Unit"
        ),
    ]
)

