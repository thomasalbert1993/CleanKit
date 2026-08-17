// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CleanKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "CleanKit",
            targets: ["CleanKit"]
        ),
    ],
    targets: [
        .target(
            name: "CleanKit"
        ),
        .testTarget(
            name: "CleanKitTests",
            dependencies: ["CleanKit"]
        ),
    ]
)
