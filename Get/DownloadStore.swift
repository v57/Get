import CryptoKit
import Foundation
import Observation
import Torrent
import os

/// Owns the torrent sessions backing the UI. Holds one `DownloadItem` per
/// active torrent, keyed by infohash hex, and fans session events into the
/// matching item on the main actor.
@MainActor @Observable final class DownloadStore {
  private static let log = Logger(subsystem: "dev.v57.get", category: "store")

  /// One file inside a torrent download.
  struct DownloadFileItem: Identifiable {
    /// Index in the torrent's file list (the session's file index).
    let index: Int
    /// Display path (components joined with "/").
    let path: String
    /// File size in bytes.
    let length: Int64
    /// Verified bytes downloaded for this file.
    var verifiedBytes: Int64 = 0
    /// Contiguous verified prefix bytes — how much of this file is
    /// downloaded from its start (the sequential playable head).
    var sequentialBytes: Int64 = 0
    /// Download priority: 0 = none (after all prioritized files),
    /// 1...4 = fetched in priority order.
    var priority: Int = 0
    /// True while this file's pieces are not being fetched.
    var isPaused: Bool = false
    /// True once the file has been trashed (removed) from the download. Its
    /// on-disk data is deleted and its pieces are excluded from fetching; the
    /// download counts as complete without it. Restoring re-downloads it.
    var isRemoved: Bool = false

    var id: Int { index }
  }

  /// A single torrent download as shown in the list.
  struct DownloadItem: Identifiable {
    /// Infohash hex — unique per torrent.
    let id: String
    let title: String
    var state: TorrentState = .stopped
    var progress: Double = 0
    var speed: String = ""
    var peers: Int = 0
    /// Connected peers that hold every piece.
    var seeders: Int = 0
    /// Tracker-reported seeders/leechers (optional, latest announce).
    var trackerSeeders: Int?
    var trackerLeechers: Int?
    var error: String?
    /// The torrent's files (empty for non-torrent downloads).
    var files: [DownloadFileItem] = []
    /// Set when the download finishes and its files are moved out of
    /// `Downloading` into `Downloads` — the location Trash should use.
    var finalURL: URL?
  }

  private(set) var items: [DownloadItem] = []

  /// Set when `openTorrent` fails, for the view to surface as an alert.
  var lastError: String?

  private var sessions: [String: TorrentSession] = [:]
  private var eventTasks: [String: Task<Void, Never>] = [:]

  /// `~/Downloads` — where finished downloads end up.
  private static var downloadsRoot: URL {
    FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
  }

  /// `~/Downloads/Downloading` — where active downloads stage until they
  /// finish, then are moved to `downloadsRoot`.
  private static var activeDirectory: URL {
    downloadsRoot.appendingPathComponent("Downloading", isDirectory: true)
  }

  /// Where copies of active `.torrent` files live so downloads can be
  /// resumed on relaunch: `~/Library/Application Support/Get/Torrents/`.
  private static var torrentsDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
      .appendingPathComponent("Get/Torrents", isDirectory: true)
  }

  /// Per-torrent "paused" marker, alongside the `.torrent` copy. Present →
  /// the download must be restored already-paused on the next launch;
  /// absent → restore as running. Written on pause, removed on resume.
  private static func pausedMarkerURL(id: String) -> URL {
    Self.torrentsDirectory.appendingPathComponent("\(id).paused")
  }

  init() {
    // Reopen every torrent that was active in a previous run. Sessions
    // pick up the persisted resume state automatically (verified pieces
    // are skipped), so interrupted downloads continue on relaunch.
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: Self.torrentsDirectory, includingPropertiesForKeys: nil)) ?? []
    for url in files where url.pathExtension.lowercased() == "torrent" {
      // Errors (corrupt copy, missing data) must not spam the launch;
      // a failed restore is just a skipped download. Restore a download
      // that was pre-marked paused (paused last session) as paused, so
      // relaunching never resumes it.
      let id = url.deletingPathExtension().lastPathComponent
      let wasPaused = FileManager.default.fileExists(atPath: Self.pausedMarkerURL(id: id).path)
      Task { try? await openTorrent(url: url, initiallyPaused: wasPaused) }
    }
    if !files.isEmpty { Self.log.info("Resuming \(files.count) saved download(s)") }
    Self.removeActiveDirectoryIfEmpty()
  }

  /// Remove `~/Downloads/Downloading` when it's empty (e.g. a previous run
  /// crashed after the last download was moved out). Harmless no-op when
  /// it has content or doesn't exist.
  private static func removeActiveDirectoryIfEmpty() {
    let dir = activeDirectory
    guard FileManager.default.fileExists(atPath: dir.path) else { return }
    guard (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true else {
      return
    }
    try? FileManager.default.removeItem(at: dir)
  }

  /// Open a `.torrent` file from any source (file importer, drag & drop,
  /// "Open With…"). Starts the download; failures surface as `lastError`.
  func open(url: URL) async {
    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
    do { try await openTorrent(url: url) } catch { lastError = error.localizedDescription }
  }

  /// Parse a `.torrent` file and start downloading it. When
  /// `initiallyPaused` is true the session is brought up (resume state
  /// loaded, files prepared) but left idle, so a download that was paused
  /// last session stays paused on relaunch.
  func openTorrent(url: URL, initiallyPaused: Bool = false) async throws {
    let torrent = try TorrentSession.parse(url: url)
    let id = torrent.infoHash.map { String(format: "%02x", $0) }.joined()

    // Already known (or still listed after cancel) — don't duplicate.
    guard !items.contains(where: { $0.id == id }) else { return }

    // Keep a copy so the download can be resumed on relaunch.
    persistTorrentCopy(from: url, id: id)

    var settings = TorrentSettings()
    // Active downloads stage in ~/Downloads/Downloading; on completion
    // they move to ~/Downloads.
    settings.saveDirectory = Self.activeDirectory
    // Peer discovery beyond trackers, like the reference clients:
    // DHT finds live peers, PEX exchanges them over established links.
    settings.useDHT = true
    settings.usePEX = true
    // Accept inbound connections so other clients (e.g. Transmission)
    // can connect to us as a peer.
    settings.useInbound = true

    let session = TorrentSession(torrent: torrent, settings: settings)
    sessions[id] = session
    let files = torrent.files.enumerated().map { index, file in
      DownloadFileItem(index: index, path: file.path.joined(separator: "/"), length: file.length)
    }
    items.append(
      DownloadItem(id: id, title: torrent.name, state: initiallyPaused ? .paused : .stopped,
        files: files))

    let task = Task { [weak self] in
      defer { self?.eventTasks[id] = nil }
      for await event in await session.events { self?.apply(event, to: id) }
    }
    eventTasks[id] = task

    do { try await session.start(initiallyPaused: initiallyPaused) } catch {
      items.firstIndex { $0.id == id }.map { items[$0].error = error.localizedDescription }
      throw error
    }
  }

  /// Stop a download and clean up its session. The files stay on disk and
  /// the item stays listed (as `.stopped`); the persisted `.torrent` copy
  /// is removed so it does NOT come back on relaunch.
  func cancel(itemID: String) {
    eventTasks[itemID]?.cancel()
    eventTasks[itemID] = nil

    guard let session = sessions.removeValue(forKey: itemID) else { return }
    Task { await session.cancel() }
    removeTorrentCopy(id: itemID)
    removePausedMarker(id: itemID)

    if let index = items.firstIndex(where: { $0.id == itemID }) {
      items[index].state = .stopped
      items[index].speed = ""
      items[index].peers = 0
    }
  }

  /// Delete a download: stop the session, remove the item, move the
  /// downloaded files to the Trash, and drop its resume state + persisted
  /// `.torrent` copy so nothing comes back on relaunch.
  func trash(itemID: String) async {
    eventTasks[itemID]?.cancel()
    eventTasks[itemID] = nil

    guard let session = sessions.removeValue(forKey: itemID) else {
      items.removeAll { $0.id == itemID }
      return
    }
    await session.cancel()

    // Target the moved-to-Downloads location if the download finished;
    // otherwise the still-staged location under Downloading.
    let stagedRoot = await session.dataRootURL()
    let root: URL
    if let index = items.firstIndex(where: { $0.id == itemID }),
      let finalURL = items[index].finalURL
    {
      root = finalURL
    } else {
      root = stagedRoot
    }

    // Move the download's files to the Trash (best effort — a download
    // that never wrote anything has nothing to trash).
    try? FileManager.default.trashItem(at: root, resultingItemURL: nil)

    items.removeAll { $0.id == itemID }
    removeTorrentCopy(id: itemID)
    removePausedMarker(id: itemID)
    try? FileManager.default.removeItem(at: ResumeState.fileURL(infoHashHex: itemID))
    Self.removeActiveDirectoryIfEmpty()
  }

  /// Pause the whole download (stops requesting; in-flight blocks finish).
  func pause(itemID: String) {
    guard let index = items.firstIndex(where: { $0.id == itemID }),
      items[index].state == .downloading
    else { return }
    items[index].state = .paused
    persistPausedMarker(id: itemID)
    Task { await sessions[itemID]?.pause() }
  }

  /// Resume a paused download.
  func resume(itemID: String) {
    guard let index = items.firstIndex(where: { $0.id == itemID }), items[index].state == .paused
    else { return }
    items[index].state = .downloading
    removePausedMarker(id: itemID)
    Task { await sessions[itemID]?.resume() }
  }

  /// Toggle pause/resume for a whole download (for sidebar buttons).
  func togglePause(itemID: String) {
    if let index = items.firstIndex(where: { $0.id == itemID }), items[index].state == .paused {
      resume(itemID: itemID)
    } else {
      pause(itemID: itemID)
    }
  }

  // MARK: - Priorities

  /// Set one file's priority (0 clears it) and push the whole priority
  /// table to the session so the picker reorders immediately.
  func setPriority(_ priority: Int, fileIndex: Int, itemID: String) {
    guard let index = items.firstIndex(where: { $0.id == itemID }),
      items[index].files.indices.contains(fileIndex)
    else { return }
    items[index].files[fileIndex].priority = priority
    pushPriorities(itemID: itemID)
  }

  /// Clear every priority for a torrent (entering priority mode).
  func clearAllPriorities(itemID: String) {
    guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
    for fileIndex in items[index].files.indices { items[index].files[fileIndex].priority = 0 }
    pushPriorities(itemID: itemID)
  }

  private func pushPriorities(itemID: String) {
    guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
    let table = Dictionary(
      uniqueKeysWithValues: items[index].files.compactMap { file in
        file.priority > 0 ? (file.index, file.priority) : nil
      })
    Task { await sessions[itemID]?.setFilePriorities(table) }
  }

  // MARK: - Per-file pause

  /// Pause or resume one file: its pieces drop out of the fetch order
  /// until resumed.
  func setFilePaused(_ paused: Bool, fileIndex: Int, itemID: String) {
    guard let index = items.firstIndex(where: { $0.id == itemID }),
      items[index].files.indices.contains(fileIndex)
    else { return }
    items[index].files[fileIndex].isPaused = paused
    Task { await sessions[itemID]?.setFilePaused(paused, fileIndex: fileIndex) }
  }

  /// Toggle one file's paused state (for row buttons).
  func toggleFilePaused(fileIndex: Int, itemID: String) {
    guard let index = items.firstIndex(where: { $0.id == itemID }),
      items[index].files.indices.contains(fileIndex)
    else { return }
    setFilePaused(!items[index].files[fileIndex].isPaused, fileIndex: fileIndex, itemID: itemID)
  }

  /// Remove (trash) one file from the download: its pieces quit the fetch
  /// order, its on-disk data is deleted, and it no longer counts toward
  /// completion. The file is shown struck-through and can be restored.
  func removeFile(fileIndex: Int, itemID: String) {
    guard let index = items.firstIndex(where: { $0.id == itemID }),
      items[index].files.indices.contains(fileIndex)
    else { return }
    items[index].files[fileIndex].isRemoved = true
    // A removed file is not "paused" — it is gone from the fetch entirely.
    items[index].files[fileIndex].isPaused = false
    items[index].files[fileIndex].verifiedBytes = 0
    Task { await sessions[itemID]?.setFileRemoved(true, fileIndex: fileIndex) }
  }

  /// Restore a previously removed file: re-include it in the download and
  /// re-download its data from scratch (it was deleted while removed).
  func restoreFile(fileIndex: Int, itemID: String) {
    guard let index = items.firstIndex(where: { $0.id == itemID }),
      items[index].files.indices.contains(fileIndex)
    else { return }
    items[index].files[fileIndex].isRemoved = false
    items[index].files[fileIndex].isPaused = false
    Task { await sessions[itemID]?.setFilePaused(false, fileIndex: fileIndex) }
    Task { await sessions[itemID]?.setFileRemoved(false, fileIndex: fileIndex) }
  }

  // MARK: - Persistence (resume on relaunch)

  /// Copy a `.torrent` file into the app's library so the download can be
  /// resumed after a relaunch. Best effort — a failed copy just means no
  /// auto-resume for this torrent.
  private func persistTorrentCopy(from url: URL, id: String) {
    do {
      let data = try Data(contentsOf: url)
      try FileManager.default.createDirectory(
        at: Self.torrentsDirectory, withIntermediateDirectories: true)
      try data.write(
        to: Self.torrentsDirectory.appendingPathComponent("\(id).torrent"), options: .atomic)
    } catch {
      // Best effort: skip auto-resume for this torrent.
    }
  }

  private func removeTorrentCopy(id: String) {
    try? FileManager.default.removeItem(
      at: Self.torrentsDirectory.appendingPathComponent("\(id).torrent"))
  }

  /// Record that a download is paused so a relaunch restores it as paused
  /// (not running). Best effort — a failed write just means next launch
  /// resumes the download instead.
  private func persistPausedMarker(id: String) {
    try? FileManager.default.createDirectory(
      at: Self.torrentsDirectory, withIntermediateDirectories: true)
    try? Data("paused".utf8).write(to: Self.pausedMarkerURL(id: id), options: .atomic)
  }

  private func removePausedMarker(id: String) {
    try? FileManager.default.removeItem(at: Self.pausedMarkerURL(id: id))
  }

  // MARK: - Events

  private func apply(_ event: TorrentEvent, to id: String) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    switch event {
    case .state(let state):
      items[index].state = state
      if case .failed(let message) = state {
        items[index].error = message
        Self.log.error("[\(id, privacy: .public)] failed: \(message, privacy: .public)")
      } else {
        Self.log.info("[\(id, privacy: .public)] state -> \(state.label, privacy: .public)")
      }
      if state == .completed { finalizeCompletedDownload(itemID: id, index: index) }
    case .peer(let peerEvent):
      switch peerEvent {
      case .connected(let host):
        Self.log.info("[\(id, privacy: .public)] peer connected: \(host, privacy: .public)")
      case .disconnected(let host):
        Self.log.info("[\(id, privacy: .public)] peer disconnected: \(host, privacy: .public)")
      case .dropped(let host):
        Self.log.info("[\(id, privacy: .public)] peer dropped: \(host, privacy: .public)")
      }
    case .stats(let stats):
      items[index].progress = stats.progress
      items[index].speed = Self.formatSpeed(stats.downloadSpeed)
      items[index].peers = stats.peersConnected
      items[index].seeders = stats.seedersConnected
      items[index].trackerSeeders = stats.trackerSeeders
      items[index].trackerLeechers = stats.trackerLeechers
      if stats.fileVerifiedBytes.count == items[index].files.count
        && stats.fileSequentialBytes.count == items[index].files.count
      {
        for fileIndex in items[index].files.indices {
          items[index].files[fileIndex].verifiedBytes = stats.fileVerifiedBytes[fileIndex]
          items[index].files[fileIndex].sequentialBytes = stats.fileSequentialBytes[fileIndex]
        }
      }
    case .error(let message):
      items[index].error = message
      Self.log.error("[\(id, privacy: .public)] engine error: \(message, privacy: .public)")
    case .pieceVerified(let piece):
      Self.log.info("[\(id, privacy: .public)] piece \(piece, privacy: .public) verified")
    }
  }

  /// Move a finished download's files from `~/Downloads/Downloading` into
  /// `~/Downloads`, drop its resume state/persisted torrent (a completed
  /// download must not be re-fetched on relaunch), and remove the staging
  /// directory when it's now empty.
  private func finalizeCompletedDownload(itemID: String, index: Int) {
    guard let session = sessions[itemID] else { return }
    Task {
      let from = await session.dataRootURL()
      let to = Self.downloadsRoot.appendingPathComponent(from.lastPathComponent)

      // Only move when the download is still staged (not already there).
      if from.deletingLastPathComponent().path != Self.downloadsRoot.path,
        FileManager.default.fileExists(atPath: from.path)
      {
        do { try FileManager.default.moveItem(at: from, to: to) } catch CocoaError
          .fileWriteFileExists
        {
          // A file with the same name is already in Downloads. If
          // it's byte-identical (a previous completed run of this
          // same torrent), the staged copy is redundant — the
          // existing file IS the finished download. Anything else
          // collides: keep staging and surface it.
          if Self.filesMatch(at: from, and: to) {
            try? FileManager.default.removeItem(at: from)
            Self.log.info(
              "Completed download already exists in Downloads (\(to.lastPathComponent, privacy: .public)); kept existing copy"
            )
          } else {
            items[index].error =
              "A different \"\(to.lastPathComponent)\" already exists in Downloads"
            Self.log.error(
              "Move blocked: \(to.lastPathComponent, privacy: .public) exists in Downloads and differs"
            )
            return
          }
        } catch {
          Self.log.error(
            "Couldn't move \(from.lastPathComponent, privacy: .public) to Downloads: \(error.localizedDescription, privacy: .public)"
          )
          return
        }
      }

      // Record the final location so Trash targets the moved files.
      if let i = items.firstIndex(where: { $0.id == itemID }) { items[i].finalURL = to }

      // A finished download is no longer "active": drop its resume
      // state and persisted copy so relaunch won't re-add it.
      removeTorrentCopy(id: itemID)
      try? FileManager.default.removeItem(at: ResumeState.fileURL(infoHashHex: itemID))

      Self.removeActiveDirectoryIfEmpty()
      Self.log.info("Moved \(to.lastPathComponent, privacy: .public) to Downloads")
    }
  }

  /// Byte-identical check for the move-collision case: same length, then
  /// SHA-256 over both files (chunked, constant memory).
  private static func filesMatch(at a: URL, and b: URL) -> Bool {
    let fm = FileManager.default
    guard let sa = try? fm.attributesOfItem(atPath: a.path)[.size] as? Int64,
      let sb = try? fm.attributesOfItem(atPath: b.path)[.size] as? Int64, sa == sb
    else { return false }
    func digest(_ url: URL) -> Data? {
      guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
      defer { try? handle.close() }
      var hasher = SHA256()
      while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
      }
      return Data(hasher.finalize())
    }
    guard let da = digest(a), let db = digest(b) else { return false }
    return da == db
  }

  private static func formatSpeed(_ bytesPerSecond: Double) -> String {
    guard bytesPerSecond > 0 else { return "" }
    let units = ["B/s", "KB/s", "MB/s", "GB/s"]
    var value = bytesPerSecond
    var unit = 0
    while value >= 1024, unit < units.count - 1 {
      value /= 1024
      unit += 1
    }
    return String(format: "%.1f %@", value, units[unit])
  }
}
