// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "CloudKitSync",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .watchOS(.v10),
        .tvOS(.v17),
    ],
    products: [
        .library(
            name: "CloudKitSync",
            targets: ["CloudKitSync"]
        ),
    ],
    targets: [
        .target(
            name: "CloudKitSync",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
        .testTarget(
            name: "CloudKitSyncTests",
            dependencies: ["CloudKitSync"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
    ]
)
