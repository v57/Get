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
    .library(name: "GetApp", targets: ["GetApp"]),
  ],
  dependencies: [
    // CodeProgress: the download's progress and time left, from how long the same kind of work took before.
    v57("Code"),
    // The app's: the shared design, in-app updates, screenshot scenes, the user's Hub devices and SSH to them.
    v57("Component"), v57("UpdateKit"), v57("Dev"), v57("Vault"), v57("Database"),
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
    // The app, all of it but its entry point (Sources/Get/GetMain.swift): the Xcode project builds that file into Get.app
    // with Resources (the icon, Info.plist and entitlements); on Linux and Windows the Get target below does.
    .target(
      name: "GetApp",
      dependencies: [
        "GetKit", "Torrent", "URLDownload", .product(name: "ComponentKit", package: "Component"),
        .product(name: "UpdateKit", package: "UpdateKit"), .product(name: "DevScreenshots", package: "Dev"),
        .product(name: "VaultKit", package: "Vault"), .product(name: "VaultUI", package: "Vault"),
        .product(name: "SSHTunnel", package: "Database"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v5), .defaultIsolation(MainActor.self), .enableUpcomingFeature("ApproachableConcurrency"),
        .enableUpcomingFeature("MemberImportVisibility"),
      ]),
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
// Off Apple platforms SwiftUI and the frameworks the libraries import (CryptoKit, Network, os) are v57/SwiftUI's
// stand-ins. Only here: on Apple platforms the apps use Apple's SwiftUI, and v57/SwiftUI (with its swift-syntax) stays
// out of the package graph Xcode resolves.
package.dependencies += [v57("SwiftUI")]
let standIns: [Target.Dependency] = ["CryptoKit", "Network", "os"].map { .product(name: $0, package: "SwiftUI") }
for target in package.targets where ["GetKit", "Torrent", "URLDownload", "GetApp"].contains(target.name) {
  target.dependencies += standIns
}
#if os(Windows)
// On Apple platforms `import Foundation` brings Combine (ObservableObject, @Published), URLSession and the file APIs
// SwiftUIPortability adds (trash, security-scoped URLs) along: every file gets them here too.
let appModules = ["Combine", "FoundationNetworking", "SwiftUIPortability"]
#else
// … and `import SwiftUI` brings Observation.
let appModules = ["Combine", "FoundationNetworking", "Observation", "SwiftUIPortability"]
#endif
let appSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v5), .defaultIsolation(MainActor.self), .enableUpcomingFeature("ApproachableConcurrency"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .unsafeFlags(appModules.flatMap { ["-Xfrontend", "-import-module", "-Xfrontend", $0] }),
]
for target in package.targets where target.name == "GetApp" {
  target.dependencies += [
    .product(name: "SwiftUI", package: "SwiftUI"), .product(name: "SwiftUIPortability", package: "SwiftUI"),
  ]
  target.swiftSettings = appSettings
}
// The entry point, Sources/Get/GetMain.swift, which the Xcode project builds on Apple platforms.
#if os(Windows)
// The app: a DLL the SwiftUI WinUI host loads (SwiftUI's Windows/scripts/build-app.ps1 -PackagePath <this package>
// -Product GetWinUI).
package.targets.append(
  .target(
    name: "Get", dependencies: ["GetApp", .product(name: "SwiftUI", package: "SwiftUI")],
    swiftSettings: appSettings))
package.products.append(.library(name: "GetWinUI", type: .dynamic, targets: ["Get"]))
#elseif os(Linux)
// The app on SwiftUI's GTK backend (V57_LOCAL=1 swift build --product Get).
package.targets.append(
  .executableTarget(
    name: "Get", dependencies: ["GetApp", .product(name: "SwiftUI", package: "SwiftUI")],
    swiftSettings: appSettings))
package.products.append(.executable(name: "Get", targets: ["Get"]))
#endif
#endif
