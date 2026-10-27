// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

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
// Off Apple platforms the frameworks the libraries import (CryptoKit, Network, os) are v57/SwiftUI's stand-ins.
package.dependencies += [v57("SwiftUI")]
let standIns: [Target.Dependency] = ["CryptoKit", "Network", "os"].map { .product(name: $0, package: "SwiftUI") }
for target in package.targets where ["GetKit", "Torrent", "URLDownload"].contains(target.name) {
  target.dependencies += standIns
}
#if os(Windows)
// The app: a DLL the SwiftUI WinUI host loads (SwiftUI's Windows/scripts/build-app.ps1 -PackagePath <this package>
// -Product GetWinUI), built from the Xcode project's sources with its settings.
package.dependencies += [v57("Component"), v57("UpdateKit"), v57("Dev"), v57("Vault"), v57("Database")]
package.targets.append(
  .target(
    name: "GetApp",
    dependencies: [
      "GetKit", "Torrent", "URLDownload", .product(name: "SwiftUI", package: "SwiftUI"),
      .product(name: "ComponentKit", package: "Component"), .product(name: "UpdateKit", package: "UpdateKit"),
      .product(name: "DevScreenshots", package: "Dev"), .product(name: "VaultKit", package: "Vault"),
      .product(name: "SSHTunnel", package: "Database"),
    ] + standIns,
    path: "Get", exclude: ["Info.plist", "Assets.xcassets"],
    swiftSettings: [
      .swiftLanguageMode(.v5), .defaultIsolation(MainActor.self), .enableUpcomingFeature("ApproachableConcurrency"),
      .enableUpcomingFeature("MemberImportVisibility"),
      // On Apple platforms `import Foundation` brings Combine (ObservableObject, @Published), URLSession and the
      // file APIs SwiftUIPortability adds (trash, security-scoped URLs) along: every file gets them here too.
      .unsafeFlags(
        ["Combine", "FoundationNetworking", "SwiftUIPortability"].flatMap { ["-Xfrontend", "-import-module", "-Xfrontend", $0] }),
    ]))
package.products.append(.library(name: "GetWinUI", type: .dynamic, targets: ["GetApp"]))
#elseif os(Linux)
// The app on SwiftUI's GTK backend: an executable built from the Xcode project's sources with its settings
// (V57_LOCAL=1 swift build --product Get).
package.dependencies += [v57("Component"), v57("UpdateKit"), v57("Dev"), v57("Vault"), v57("Database")]
package.targets.append(
  .executableTarget(
    name: "GetApp",
    dependencies: [
      "GetKit", "Torrent", "URLDownload", .product(name: "SwiftUI", package: "SwiftUI"),
      .product(name: "SwiftUIPortability", package: "SwiftUI"), .product(name: "ComponentKit", package: "Component"),
      .product(name: "UpdateKit", package: "UpdateKit"), .product(name: "DevScreenshots", package: "Dev"),
      .product(name: "VaultKit", package: "Vault"), .product(name: "VaultUI", package: "Vault"),
      .product(name: "SSHTunnel", package: "Database"),
    ] + standIns,
    path: "Get", exclude: ["Info.plist", "AppIcon.icon"],
    swiftSettings: [
      .swiftLanguageMode(.v5), .defaultIsolation(MainActor.self), .enableUpcomingFeature("ApproachableConcurrency"),
      .enableUpcomingFeature("MemberImportVisibility"),
      // On Apple platforms `import Foundation` brings Combine (ObservableObject, @Published), URLSession and the
      // file APIs SwiftUIPortability adds (trash, security-scoped URLs) along, and `import SwiftUI` brings
      // Observation: every file gets them here too.
      .unsafeFlags(
        ["Combine", "FoundationNetworking", "Observation", "SwiftUIPortability"].flatMap {
          ["-Xfrontend", "-import-module", "-Xfrontend", $0]
        }),
    ]))
package.products.append(.executable(name: "Get", targets: ["GetApp"]))
#endif
#endif
