import ComponentKit
import SwiftUI
import UpdateKit
import os

public struct GetApp: App {
  #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  #endif

  /// Updates from GitHub Releases (Get.zip, built by Scripts/release.sh): checked daily
  /// once the user turns on automatic checks (never before), installed in place with a relaunch.
  private let updater = AppUpdater(github: "v57/Get", assetName: "Get.zip")

  /// Get's red, the one colour the app picks.
  static let accent = Color(red: 1, green: 0x3b / 255, blue: 0x30 / 255)

  public init() { updater.start() }

  public var body: some Scene {
    WindowGroup { TorrentView().componentKit(accent: Self.accent) }
      .commands { UpdaterCommands(updater: updater) }
  }
}

/// Receives "Open With…" events (LaunchServices) for .torrent files and
/// forwards them to the download store. On Windows and Linux the files come as
/// the paths the app was launched with.
@MainActor final class AppDelegate: NSObject {
  private static let log = Logger(subsystem: "dev.v57.get", category: "open")

  /// Set by the root view once its store exists (see `attach`).
  private static weak var store: DownloadStore?
  /// URLs from `application(_:open:)` that arrived before the view had a
  /// store to hand them to (cold start — Open With can fire before the
  /// first `onAppear`).
  private static var pendingURLs: [URL] = {
    #if os(macOS)
      []
    #else
      CommandLine.arguments.dropFirst().filter { $0.lowercased().hasSuffix(".torrent") }.map {
        URL(fileURLWithPath: $0)
      }
    #endif
  }()

  fileprivate func open(_ urls: [URL]) {
    Self.log.info("Open With: \(urls.map(\.path), privacy: .public)")
    if let store = Self.store {
      for url in urls { Task { await store.open(url: url) } }
    } else {
      Self.pendingURLs.append(contentsOf: urls)
    }
  }

  /// Attach the live store and drain any URLs queued before it existed.
  static func attach(store: DownloadStore) {
    self.store = store
    let pending = pendingURLs
    pendingURLs = []
    for url in pending { Task { await store.open(url: url) } }
  }
}

#if os(macOS)
  extension AppDelegate: NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) { open(urls) }
  }
#endif

#Preview { TorrentView().componentKit(accent: GetApp.accent) }
