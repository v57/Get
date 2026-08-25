import AppKit
import SwiftUI
import os

@main struct GetApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene { WindowGroup { TorrentView() } }
}

/// Receives "Open With…" events (LaunchServices) for .torrent files and
/// forwards them to the download store.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  private static let log = Logger(subsystem: "dev.v57.get", category: "open")

  /// Set by the root view once its store exists (see `attach`).
  private static weak var store: DownloadStore?
  /// URLs from `application(_:open:)` that arrived before the view had a
  /// store to hand them to (cold start — Open With can fire before the
  /// first `onAppear`).
  private static var pendingURLs: [URL] = []

  func application(_ application: NSApplication, open urls: [URL]) {
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

#Preview { TorrentView() }
