// swift-tools-version: 6.4
// The libraries; the app is the package in App/.

import PackageDescription

/// Another v57 repository: GitHub's main branch, or the checkout next to this one with `V57_LOCAL=1` (in Xcode,
/// open Get-Local.xcworkspace instead).
func v57(_ name: String) -> Package.Dependency {
  Context.environment["V57_LOCAL"] == nil
    ? .package(url: "https://github.com/v57/\(name).git", branch: "main") : .package(path: "../\(name)")
}

let package = Package(
  name: "Get", platforms: [.macOS(.v14)],
  products: [
    .library(name: "GetKit", targets: ["GetKit"]),
    .library(name: "Torrent", targets: ["Torrent"]),
    .library(name: "URLDownload", targets: ["URLDownload"]),
  ],
  dependencies: [
    // CodeProgress: the download's progress and time left, from how long the same kind of work took before.
    v57("Code")
  ],
  targets: [
    .target(
      name: "GetKit", dependencies: [.product(name: "CodeProgress", package: "Code")],
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

#if os(Windows) || os(Linux)
// Off Apple platforms the frameworks the libraries import (CryptoKit, Network, os) are v57/SwiftUI's stand-ins. Only
// here: v57/SwiftUI (with its swift-syntax) stays out of the package graph Xcode resolves.
package.dependencies += [v57("SwiftUI")]
let standIns: [Target.Dependency] = ["CryptoKit", "Network", "os"].map { .product(name: $0, package: "SwiftUI") }
for target in package.targets where ["GetKit", "Torrent", "URLDownload"].contains(target.name) {
  target.dependencies += standIns
}
#endif
