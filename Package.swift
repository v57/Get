// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "Get", platforms: [.macOS(.v13)],
  products: [
    .library(name: "GetKit", targets: ["GetKit"]),
    .library(name: "Torrent", targets: ["Torrent"]),
    .library(name: "URLDownload", targets: ["URLDownload"]),
  ],
  targets: [
    .target(
      name: "GetKit",
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
    .target(
      name: "Torrent", dependencies: ["GetKit"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
    .target(
      name: "URLDownload", dependencies: ["GetKit"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
    .testTarget(
      name: "GetKitTests", dependencies: ["GetKit"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
    .testTarget(
      name: "TorrentTests", dependencies: ["Torrent"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
    .testTarget(
      name: "URLDownloadTests", dependencies: ["URLDownload"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
  ])
