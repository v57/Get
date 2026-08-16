// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Get",
    products: [
        .library(
            name: "Torrent",
            targets: ["Torrent"]
        ),
    ],
    targets: [
        .target(
            name: "Torrent",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "TorrentTests",
            dependencies: ["Torrent"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ]
)
