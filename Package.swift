// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "Get", platforms: [.macOS(.v13)],
  products: [
    .library(name: "Torrent", targets: ["Torrent"]),
    .library(name: "URLDownload", targets: ["URLDownload"]),
  ],
  targets: [
    .target(
      name: "DownloadCore",
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
    .target(
      name: "Torrent", dependencies: ["DownloadCore"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
    .target(
      name: "URLDownload", dependencies: ["DownloadCore"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
    .testTarget(
      name: "DownloadCoreTests", dependencies: ["DownloadCore"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
    .testTarget(
      name: "TorrentTests", dependencies: ["Torrent"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
    .testTarget(
      name: "URLDownloadTests", dependencies: ["URLDownload"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
  ])
