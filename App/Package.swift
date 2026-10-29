// swift-tools-version: 6.4
// The app, a package of its own beside the libraries (..), so the repositories it depends on can depend on this one's
// libraries without a cycle between packages.

import PackageDescription

/// Another v57 repository: GitHub's main branch, or the checkout next to this one with `V57_LOCAL=1` (in Xcode,
/// open Get-Local.xcworkspace instead).
func v57(_ name: String) -> Package.Dependency {
  Context.environment["V57_LOCAL"] == nil
    ? .package(url: "https://github.com/v57/\(name).git", branch: "main") : .package(path: "../../\(name)")
}

/// This repository's libraries, the package at "..": SwiftPM names a path dependency after its folder, which is Get in
/// the main checkout and the worktree's own name in a worktree.
let kits = String(Context.packageDirectory.split(whereSeparator: { $0 == "/" || $0 == "\\" }).dropLast().last ?? "Get")

let package = Package(
  name: "GetApp", platforms: [.macOS(.v14)],
  products: [.library(name: "GetApp", targets: ["GetApp"])],
  dependencies: [
    .package(path: ".."),
    // The shared design, in-app updates, screenshot scenes, the user's Hub devices and SSH to them.
    v57("Component"), v57("UpdateKit"), v57("Dev"), v57("Vault"), v57("Database"),
  ],
  targets: [
    // The app, all of it but its entry point (Sources/Get/GetMain.swift): Get.xcodeproj builds that file into Get.app
    // with Resources (the icon, Info.plist and entitlements); on Linux and Windows the Get target below does.
    .target(
      name: "GetApp",
      dependencies: [
        .product(name: "GetKit", package: kits), .product(name: "Torrent", package: kits),
        .product(name: "URLDownload", package: kits), .product(name: "ComponentKit", package: "Component"),
        .product(name: "UpdateKit", package: "UpdateKit"), .product(name: "DevScreenshots", package: "Dev"),
        .product(name: "VaultKit", package: "Vault"), .product(name: "VaultUI", package: "Vault"),
        .product(name: "SSHTunnel", package: "Database"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v5), .defaultIsolation(MainActor.self), .enableUpcomingFeature("ApproachableConcurrency"),
        .enableUpcomingFeature("MemberImportVisibility"),
      ])
  ])

#if os(Windows) || os(Linux)
// Off Apple platforms SwiftUI and the frameworks the app imports (CryptoKit, Network, os) are v57/SwiftUI's stand-ins.
// Only here: on Apple platforms the app uses Apple's SwiftUI, and v57/SwiftUI (with its swift-syntax) stays out of the
// package graph Xcode resolves.
package.dependencies += [v57("SwiftUI")]
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
  target.dependencies += ["CryptoKit", "Network", "os", "SwiftUI", "SwiftUIPortability"].map {
    .product(name: $0, package: "SwiftUI")
  }
  target.swiftSettings = appSettings
}
// The entry point, Sources/Get/GetMain.swift, which Get.xcodeproj builds on Apple platforms.
#if os(Windows)
// The app: a DLL the SwiftUI WinUI host loads (SwiftUI's Windows/scripts/build-app.ps1 -PackagePath <this App folder>
// -Product GetWinUI).
package.targets.append(
  .target(
    name: "Get", dependencies: ["GetApp", .product(name: "SwiftUI", package: "SwiftUI")],
    swiftSettings: appSettings))
package.products.append(.library(name: "GetWinUI", type: .dynamic, targets: ["Get"]))
#elseif os(Linux)
// The app on SwiftUI's GTK backend (in App/: V57_LOCAL=1 swift build --product Get).
package.targets.append(
  .executableTarget(
    name: "Get", dependencies: ["GetApp", .product(name: "SwiftUI", package: "SwiftUI")],
    swiftSettings: appSettings))
package.products.append(.executable(name: "Get", targets: ["Get"]))
#endif
#endif
