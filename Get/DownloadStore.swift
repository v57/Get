import ComponentKit
import CryptoKit
import Foundation
import GetKit
import Observation
import SSHTunnel
import Torrent
import URLDownload
import os

/// Owns the download sessions backing the UI: torrents and plain URL
/// downloads. Holds one `DownloadItem` per download (keyed by infohash hex,
/// or `url-<hash>` for URLs) and fans session events into the matching item
/// on the main actor.
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

  /// A single download as shown in the list.
  struct DownloadItem: Identifiable {
    enum Kind { case torrent, url }

    /// Infohash hex for torrents, `url-<hash>` for URL downloads.
    let id: String
    /// Torrent name, or the file name of a URL download (once known).
    var title: String
    var state: TorrentState = .stopped
    /// The whole job's progress (the transfer and the check after it), from `DownloadProgress`.
    var progress: Double = 0
    /// Time left for the whole job, while it runs and every stage left has an estimate.
    var remaining: TimeInterval?
    /// Download speed in bytes per second; 0 unless downloading.
    var bytesPerSecond: Double = 0
    /// The speed as shown ("18.4 MB/s"), empty unless downloading.
    var speed: String { DownloadStore.formatSpeed(bytesPerSecond) }
    var peers: Int = 0
    /// Connected peers that hold every piece.
    var seeders: Int = 0
    /// Tracker-reported seeders/leechers (optional, latest announce).
    var trackerSeeders: Int?
    var trackerLeechers: Int?
    var error: String?
    /// The torrent's files in torrent order, indexed by file index (empty
    /// for non-torrent downloads).
    var files: [DownloadFileItem] = []
    /// File indices in natural name order: the order files are shown and
    /// downloaded in.
    var fileOrder: [Int] = []
    /// `files` in display order.
    var orderedFiles: [DownloadFileItem] { fileOrder.map { files[$0] } }
    /// Where the download is on disk: the single file, or the folder of a
    /// multi-file torrent. Staged under `Downloading` while active, then in
    /// `Downloads` once finished (and moved). Nil until known.
    var location: URL?
    /// The download is one file at `location` (not a folder of files).
    var isSingleFile = true

    var kind: Kind = .torrent
    /// URL downloads: where the file comes from.
    var sourceURL: URL?
    var receivedBytes: Int64 = 0
    /// File length, when the server reported it.
    var totalBytes: Int64?
    /// Parallel connections fetching segments right now.
    var connections = 0
    /// The server takes range requests: the download can resume.
    var resumable = false
    /// The checksum the user gave, checked when the download finishes.
    var checksum: Checksum?
    /// The checksum the finished file matched (the user's or the server's).
    var verifiedChecksum: Checksum?
    /// What the finished file will be checked against (the user's checksum, else the server's), once known.
    var plannedChecksum: Checksum?
    /// Downloads on another device (Download on…): the device's name, and where the file is there once saved.
    var device: String?
    var remotePath: String?

    /// The bytes the transfer has and needs: a link's, or a torrent's verified bytes over its files that weren't
    /// removed.
    var transferBytes: (received: Int64, total: Int64?) {
      guard kind == .torrent else { return (receivedBytes, totalBytes) }
      let kept = files.filter { !$0.isRemoved }
      return (kept.reduce(0) { $0 + $1.verifiedBytes }, kept.reduce(0) { $0 + $1.length })
    }
  }

  private(set) var items: [DownloadItem] = []

  /// Set when a download can't start, for the view to surface as an alert.
  var lastError: String?

  private var sessions: [String: TorrentSession] = [:]
  private var urlSessions: [String: URLDownloadSession] = [:]
  /// Downloads running on other devices: the command, and what to start again on Retry.
  private var remoteJobs: [String: (download: RemoteDownload, hostID: String, command: SSHCommand?)] = [:]
  private var eventTasks: [String: Task<Void, Never>] = [:]
  /// Each download's progress and time left, estimated from how long the same kind of work took before.
  private var progress: [String: DownloadProgress] = [:]
  /// Reads the running downloads' progress while any runs.
  private var progressTimer: Task<Void, Never>?

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

  /// Where active URL downloads keep their progress records so they resume
  /// on relaunch: `~/Library/Application Support/Get/URLs/<id>.json`.
  private static var urlsDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
      .appendingPathComponent("Get/URLs", isDirectory: true)
  }

  private static func urlRecordURL(id: String) -> URL {
    urlsDirectory.appendingPathComponent("\(id).json")
  }

  /// Per-download "paused" marker, alongside the `.torrent` copy or URL
  /// record. Present → the download must be restored already-paused on the
  /// next launch; absent → restore as running. Written on pause, removed on
  /// resume.
  private static func pausedMarkerURL(id: String) -> URL {
    (isURLDownload(id) ? urlsDirectory : torrentsDirectory).appendingPathComponent("\(id).paused")
  }

  private static func isURLDownload(_ id: String) -> Bool { id.hasPrefix("url-") }

  init() {
    // The screenshot demo shows made-up downloads and never restores the user's.
    if ScreenshotDemo.isOn {
      items = ScreenshotDemo.items
      return
    }
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

    // Same for URL downloads: each record knows how far its segments got.
    let records =
      (try? FileManager.default.contentsOfDirectory(
        at: Self.urlsDirectory, includingPropertiesForKeys: nil)) ?? []
    for url in records where url.pathExtension == "json" {
      let id = url.deletingPathExtension().lastPathComponent
      guard let record = URLDownloadRecord.load(from: url) else { continue }
      let wasPaused = FileManager.default.fileExists(atPath: Self.pausedMarkerURL(id: id).path)
      startURLDownload(record: record, id: id, initiallyPaused: wasPaused)
    }
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
    let announce = (torrent.announce ?? torrent.announceList.first?.first).flatMap { URL(string: $0) }
    progress[id] = DownloadProgress(transferID: DownloadProgress.torrentTransferID(announce: announce))
    var files = torrent.files.enumerated().map { index, file in
      DownloadFileItem(index: index, path: file.path.joined(separator: "/"), length: file.length)
    }
    // Restore the per-file policy the user configured last session (which the
    // session also applied inside start()): a paused file stays paused, a
    // removed file shows as removed, and priorities are re-applied. Without
    // this a relaunch would silently resume a file the user had paused.
    if let state = ResumeState.load(infoHashHex: id) {
      for fileIndex in state.pausedFiles where files.indices.contains(fileIndex) {
        files[fileIndex].isPaused = true
      }
      for (fileIndex, priority) in state.priorities where files.indices.contains(fileIndex) {
        files[fileIndex].priority = priority
      }
      for fileIndex in state.removedFiles where files.indices.contains(fileIndex) {
        files[fileIndex].isRemoved = true
      }
    }
    items.append(
      DownloadItem(
        id: id, title: torrent.name, state: initiallyPaused ? .paused : .stopped, files: files,
        fileOrder: torrent.naturalFileOrder,
        isSingleFile: torrent.files.count == 1 && torrent.files[0].path == [torrent.name]))
    let location = await session.dataRootURL()
    items.firstIndex { $0.id == id }.map { items[$0].location = location }

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
  /// or URL record is removed so it does NOT come back on relaunch.
  func cancel(itemID: String) {
    if stopRemote(itemID: itemID) { return }
    eventTasks[itemID]?.cancel()
    eventTasks[itemID] = nil

    if let session = sessions.removeValue(forKey: itemID) {
      Task { await session.cancel() }
      removeTorrentCopy(id: itemID)
    } else if let session = urlSessions.removeValue(forKey: itemID) {
      // The session saves its record while cancelling: remove it after.
      Task {
        await session.cancel()
        Self.removeURLRecord(id: itemID)
      }
    } else {
      return
    }
    removePausedMarker(id: itemID)
    progress[itemID]?.stop()

    if let index = items.firstIndex(where: { $0.id == itemID }) {
      items[index].state = .stopped
      items[index].bytesPerSecond = 0
      items[index].peers = 0
      items[index].remaining = nil
    }
  }

  /// Delete a download: stop the session, remove the item, move the
  /// downloaded files to the Trash, and drop its resume state + persisted
  /// `.torrent` copy so nothing comes back on relaunch.
  func trash(itemID: String) async {
    // A download on another device stops; its file there stays.
    if remoteJobs[itemID] != nil {
      _ = stopRemote(itemID: itemID)
      remoteJobs[itemID] = nil
      items.removeAll { $0.id == itemID }
      return
    }
    eventTasks[itemID]?.cancel()
    eventTasks[itemID] = nil
    progress.removeValue(forKey: itemID)?.stop()

    if let session = urlSessions.removeValue(forKey: itemID) {
      await session.cancel()
      if let location = items.first(where: { $0.id == itemID })?.location {
        try? FileManager.default.trashItem(at: location, resultingItemURL: nil)
      }
      items.removeAll { $0.id == itemID }
      Self.removeURLRecord(id: itemID)
      removePausedMarker(id: itemID)
      Self.removeActiveDirectoryIfEmpty()
      return
    }

    guard let session = sessions.removeValue(forKey: itemID) else {
      items.removeAll { $0.id == itemID }
      return
    }
    await session.cancel()

    // The moved-to-Downloads location if the download finished; otherwise
    // the still-staged location under Downloading.
    var root = items.first { $0.id == itemID }?.location
    if root == nil { root = await session.dataRootURL() }

    // Move the download's files to the Trash (best effort — a download
    // that never wrote anything has nothing to trash).
    if let root { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }

    items.removeAll { $0.id == itemID }
    removeTorrentCopy(id: itemID)
    removePausedMarker(id: itemID)
    try? FileManager.default.removeItem(at: ResumeState.fileURL(infoHashHex: itemID))
    Self.removeActiveDirectoryIfEmpty()
  }

  /// Pause the whole download (stops requesting; in-flight blocks finish).
  func pause(itemID: String) {
    guard let index = items.firstIndex(where: { $0.id == itemID }),
      items[index].state == .downloading, items[index].device == nil
    else { return }
    items[index].state = .paused
    persistPausedMarker(id: itemID)
    Task {
      await sessions[itemID]?.pause()
      await urlSessions[itemID]?.pause()
    }
  }

  /// Resume a paused download.
  func resume(itemID: String) {
    guard let index = items.firstIndex(where: { $0.id == itemID }), items[index].state == .paused
    else { return }
    items[index].state = .downloading
    removePausedMarker(id: itemID)
    Task {
      await sessions[itemID]?.resume()
      await urlSessions[itemID]?.resume()
    }
  }

  /// Try a failed URL download again, from where it stopped.
  func retry(itemID: String) {
    if let job = remoteJobs[itemID] {
      runRemote(job.download, hostID: job.hostID, id: itemID)
      return
    }
    guard let index = items.firstIndex(where: { $0.id == itemID }),
      case .failed = items[index].state, let session = urlSessions[itemID]
    else { return }
    items[index].error = nil
    Task { await session.resume() }
  }

  /// Toggle pause/resume for a whole download (for sidebar buttons).
  func togglePause(itemID: String) {
    if let index = items.firstIndex(where: { $0.id == itemID }), items[index].state == .paused {
      resume(itemID: itemID)
    } else {
      pause(itemID: itemID)
    }
  }

  // MARK: - URL downloads

  /// Download a link: http(s) files directly, `.torrent` links as torrents,
  /// local files as `.torrent` files. `checksum` is checked when a file
  /// download finishes. Failures surface as `lastError`.
  func download(from url: URL, checksum: Checksum? = nil) async {
    if url.isFileURL {
      await open(url: url)
      return
    }
    switch url.scheme?.lowercased() {
    case "http", "https": break
    case "magnet":
      lastError = "Magnet links aren't supported yet. Open the .torrent file instead."
      return
    default:
      lastError = "Get downloads http and https links."
      return
    }
    if url.pathExtension.lowercased() == "torrent" {
      await openTorrent(from: url)
      return
    }
    let id = Self.urlDownloadID(url)
    // Already listed — don't duplicate.
    guard !items.contains(where: { $0.id == id }) else { return }
    startURLDownload(record: URLDownloadRecord(url: url, checksum: checksum), id: id)
  }

  /// Fetch a `.torrent` link and open it as a torrent download.
  private func openTorrent(from url: URL) async {
    do {
      let (file, response) = try await URLSession.shared.download(from: url)
      defer { try? FileManager.default.removeItem(at: file) }
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        lastError =
          "\(url.lastPathComponent): HTTP \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))"
        return
      }
      try await openTorrent(url: file)
    } catch {
      lastError = error.localizedDescription
    }
  }

  /// A stable id per link, so the same link isn't downloaded twice at once.
  private static func urlDownloadID(_ url: URL) -> String {
    let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
    return "url-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  private func startURLDownload(
    record: URLDownloadRecord, id: String, initiallyPaused: Bool = false
  ) {
    let recordURL = Self.urlRecordURL(id: id)
    // Saved up front, so a relaunch before any progress still brings it back.
    record.save(to: recordURL)
    let session = URLDownloadSession(
      record: record, saveDirectory: Self.activeDirectory, recordURL: recordURL)
    urlSessions[id] = session
    progress[id] = DownloadProgress(
      transferID: DownloadProgress.transferID(url: record.url),
      checkID: (record.checksum ?? record.serverChecksum).map { Self.checkID($0.algorithm) })

    let name = record.url.lastPathComponent
    var item = DownloadItem(
      id: id, title: record.filename ?? (name.isEmpty || name == "/" ? record.url.host() ?? "Download" : name),
      state: initiallyPaused ? .paused : .stopped)
    item.kind = .url
    item.sourceURL = record.url
    item.checksum = record.checksum
    items.append(item)

    eventTasks[id] = Task { [weak self] in
      defer { self?.eventTasks[id] = nil }
      for await event in await session.events { self?.apply(event, to: id) }
    }
    Task { await session.start(initiallyPaused: initiallyPaused) }
  }

  private func apply(_ event: URLDownloadEvent, to id: String) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    switch event {
    case .state(let state):
      let shown: TorrentState =
        switch state {
        case .stopped: .stopped
        case .downloading: .downloading
        case .paused: .paused
        case .verifying: .checking
        case .completed: .completed
        case .failed(let message): .failed(message)
        }
      items[index].state = shown
      if shown != .downloading { items[index].bytesPerSecond = 0 }
      switch state {
      case .downloading:
        let bytes = items[index].transferBytes
        progress[id]?.transfer(received: bytes.received, of: bytes.total)
      case .verifying:
        let algorithm = (items[index].checksum ?? items[index].plannedChecksum)?.algorithm ?? .sha256
        progress[id]?.checking(Self.checkID(algorithm), bytes: items[index].totalBytes ?? items[index].receivedBytes)
      case .completed: progress[id]?.finish()
      case .paused, .stopped, .failed: progress[id]?.stop()
      }
      refreshProgress(id)
      switch state {
      case .failed(let message):
        items[index].error = message
        Self.log.error("[\(id, privacy: .public)] failed: \(message, privacy: .public)")
      case .completed:
        items[index].error = nil
        finalizeURLDownload(itemID: id)
      default: break
      }
    case .stats(let stats):
      // Bytes arriving again clears a "retrying" note.
      if stats.receivedBytes > items[index].receivedBytes, items[index].state == .downloading {
        items[index].error = nil
      }
      items[index].receivedBytes = stats.receivedBytes
      items[index].totalBytes = stats.totalBytes
      items[index].plannedChecksum = stats.checksum
      progress[id]?.planCheck(stats.checksum.map { Self.checkID($0.algorithm) })
      if items[index].state == .downloading {
        progress[id]?.transfer(received: stats.receivedBytes, of: stats.totalBytes)
      } else {
        progress[id]?.idle(received: stats.receivedBytes, of: stats.totalBytes)
      }
      refreshProgress(id)
      items[index].connections = stats.connections
      items[index].resumable = stats.resumable
      items[index].bytesPerSecond = items[index].state == .downloading ? stats.downloadSpeed : 0
    case .file(let url):
      items[index].location = url
      items[index].title = url.lastPathComponent
    case .verified(let checksum):
      items[index].verifiedChecksum = checksum
    case .error(let message):
      items[index].error = "Retrying: \(message)"
    }
  }

  /// Move a finished URL download from `Downloading` into `Downloads`
  /// (numbering the name if it is taken) and forget its record.
  private func finalizeURLDownload(itemID: String) {
    guard let index = items.firstIndex(where: { $0.id == itemID }),
      let from = items[index].location
    else { return }
    if from.deletingLastPathComponent().standardizedFileURL
      == Self.activeDirectory.standardizedFileURL
    {
      let name = URLDownloadSession.uniqueName(from.lastPathComponent) {
        FileManager.default.fileExists(atPath: Self.downloadsRoot.appendingPathComponent($0).path)
      }
      let to = Self.downloadsRoot.appendingPathComponent(name)
      do {
        try FileManager.default.moveItem(at: from, to: to)
        items[index].location = to
        items[index].title = name
      } catch {
        items[index].error = "Couldn't move \(from.lastPathComponent) to Downloads: \(error.localizedDescription)"
        return
      }
    }
    Self.removeURLRecord(id: itemID)
    removePausedMarker(id: itemID)
    Self.removeActiveDirectoryIfEmpty()
    Self.log.info("Moved \(self.items[index].title, privacy: .public) to Downloads")
  }

  private static func removeURLRecord(id: String) {
    try? FileManager.default.removeItem(at: urlRecordURL(id: id))
  }

  // MARK: - Downloads on other devices

  /// Downloads a link on another device (a host via Hub, see `HubDevices`) into its `~/Downloads`, with the
  /// progress streamed back. Only http(s) files: torrents need Get running there.
  func download(from url: URL, checksum: Checksum? = nil, onDevice hostID: String) {
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.pathExtension.lowercased() != "torrent"
    else {
      lastError = "Another device downloads http and https files; open torrents on this Mac."
      return
    }
    let digest = SHA256.hash(data: Data((hostID + "|" + url.absoluteString).utf8))
    let id = "remote-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    guard !items.contains(where: { $0.id == id }) || remoteJobs[id]?.command == nil else { return }
    let download = RemoteDownload(url: url, checksum: checksum)
    if !items.contains(where: { $0.id == id }) {
      var item = DownloadItem(id: id, title: download.fileName)
      item.kind = .url
      item.sourceURL = url
      item.checksum = checksum
      item.device = HubDevices.name(of: hostID) ?? "Another device"
      items.append(item)
    }
    runRemote(download, hostID: hostID, id: id)
  }

  private func runRemote(_ download: RemoteDownload, hostID: String, id: String) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    guard let host = HubDevices.host(id: hostID) else {
      items[index].state = .failed("The device is no longer on your Hub.")
      return
    }
    items[index].state = .downloading
    items[index].error = nil
    do {
      let (command, finished) = try HubDevices.start(download, on: host) { [weak self] event in
        self?.apply(event, toRemote: id)
      }
      remoteJobs[id] = (download, hostID, command)
      Task { [weak self] in
        let result = await finished.result
        self?.remoteFinished(id: id, command: command, result: result)
      }
    } catch {
      remoteJobs[id] = (download, hostID, nil)
      items[index].state = .failed(error.localizedDescription)
      items[index].error = error.localizedDescription
    }
  }

  private func apply(_ event: RemoteDownload.Event, toRemote id: String) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    switch event {
    case .progress(let fraction): items[index].progress = fraction
    case .saved(let path):
      items[index].remotePath = path
      items[index].title = (path as NSString).lastPathComponent
    case .checksum(let hex):
      if let expected = items[index].checksum {
        if expected.hex == hex {
          items[index].verifiedChecksum = expected
        } else {
          items[index].error = "The file on \(items[index].device ?? "the device") doesn’t match the \(expected.algorithm.rawValue) checksum."
        }
      }
    case .failed(let message): items[index].error = message
    }
  }

  private func remoteFinished(id: String, command: SSHCommand, result: Result<Int32?, Error>) {
    guard remoteJobs[id]?.command === command, let index = items.firstIndex(where: { $0.id == id }) else { return }
    remoteJobs[id]?.command = nil
    switch result {
    case .success(0?) where items[index].remotePath != nil && items[index].error == nil:
      items[index].progress = 1
      items[index].state = .completed
    case .success(nil):
      items[index].state = .stopped
    case .success(let status):
      let message = items[index].error ?? "The download stopped there (exit code \(status.map(String.init) ?? "?"))."
      items[index].state = .failed(message)
      items[index].error = message
    case .failure(let error):
      items[index].state = .failed(error.localizedDescription)
      items[index].error = error.localizedDescription
    }
  }

  /// Stops a download on another device; false when the item isn't one.
  private func stopRemote(itemID: String) -> Bool {
    guard let job = remoteJobs[itemID] else { return false }
    job.command?.stop()
    remoteJobs[itemID]?.command = nil
    if let index = items.firstIndex(where: { $0.id == itemID }) { items[index].state = .stopped }
    return true
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

  // MARK: - Download-only scope

  /// Restrict the download to a chosen file — and, when `andAfter` is true,
  /// every file after it in display order — by pausing and trashing every other file that is
  /// not already fully downloaded. Fully downloaded files are left in place
  /// (their data is already on disk); files inside the kept range are
  /// unpaused (or restored, if previously removed) so the download proceeds.
  func downloadOnly(fileIndex: Int, itemID: String, andAfter: Bool = false) {
    guard let index = items.firstIndex(where: { $0.id == itemID }),
      items[index].files.indices.contains(fileIndex)
    else { return }

    // Snapshot for the completeness check, since trashing mutates the items.
    let files = items[index].files
    func isComplete(_ f: DownloadFileItem) -> Bool { f.verifiedBytes >= f.length }

    // Ensure a kept file is active: restore it if it was removed, otherwise
    // unpause it if it was paused. Complete files that are already active are
    // left alone to avoid redundant engine calls.
    func keepActive(_ i: Int) {
      let f = items[index].files[i]
      if f.isRemoved {
        restoreFile(fileIndex: i, itemID: itemID)
      } else if f.isPaused {
        setFilePaused(false, fileIndex: i, itemID: itemID)
      }
    }

    // The kept files: the chosen one, plus (for "only this and after") every
    // file after it in display order.
    let order = items[index].fileOrder
    let kept: [Int] =
      andAfter ? Array(order.drop(while: { $0 != fileIndex })) : [fileIndex]
    let keptSet = Set(kept)

    for (i, file) in files.enumerated() {
      if keptSet.contains(i) { continue }
      // A fully downloaded file stays — it's already on disk.
      if isComplete(file) { continue }
      // Pause + trash everything else that isn't finished.
      removeFile(fileIndex: i, itemID: itemID)
    }

    // Activate the kept files so the download actually proceeds.
    for i in kept { keepActive(i) }
  }

  // MARK: - Open and reveal

  /// The download on disk, if it is there yet.
  func existingLocation(itemID: String) -> URL? {
    guard let url = items.first(where: { $0.id == itemID })?.location,
      FileManager.default.fileExists(atPath: url.path)
    else { return nil }
    return url
  }

  /// One file of a torrent on disk, if it is there yet (a file that has not
  /// received data, or a removed one, has no file).
  func existingFileURL(fileIndex: Int, itemID: String) -> URL? {
    guard let item = items.first(where: { $0.id == itemID }), let root = item.location,
      item.files.indices.contains(fileIndex)
    else { return nil }
    let url =
      item.isSingleFile
      ? root
      : item.files[fileIndex].path.split(separator: "/").reduce(root) {
        $0.appendingPathComponent(String($1))
      }
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  /// Show the download in the file manager, selected in its folder.
  func reveal(itemID: String) {
    guard let url = existingLocation(itemID: itemID) else { return }
    KitDesktop.reveal([url])
  }

  /// Open a single-file download in its default app. Works while it is
  /// still downloading (a video can play as it arrives).
  func open(itemID: String) {
    guard items.first(where: { $0.id == itemID })?.isSingleFile == true,
      let url = existingLocation(itemID: itemID)
    else { return }
    KitDesktop.open(url)
  }

  func revealFile(fileIndex: Int, itemID: String) {
    guard let url = existingFileURL(fileIndex: fileIndex, itemID: itemID) else { return }
    KitDesktop.reveal([url])
  }

  func openFile(fileIndex: Int, itemID: String) {
    guard let url = existingFileURL(fileIndex: fileIndex, itemID: itemID) else { return }
    KitDesktop.open(url)
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
      at: Self.pausedMarkerURL(id: id).deletingLastPathComponent(),
      withIntermediateDirectories: true)
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
      // Speed is only meaningful while downloading; a finished, paused or
      // failed download must not keep showing its last reading.
      if state != .downloading { items[index].bytesPerSecond = 0 }
      switch state {
      case .downloading:
        let bytes = items[index].transferBytes
        progress[id]?.transfer(received: bytes.received, of: bytes.total)
      case .completed: progress[id]?.finish()
      case .checking: break
      case .paused, .stopped, .failed: progress[id]?.stop()
      }
      refreshProgress(id)
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
      items[index].bytesPerSecond = items[index].state == .downloading ? stats.downloadSpeed : 0
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
      let bytes = items[index].transferBytes
      if items[index].state == .downloading {
        progress[id]?.transfer(received: bytes.received, of: bytes.total)
      } else {
        progress[id]?.idle(received: bytes.received, of: bytes.total)
      }
      refreshProgress(id)
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

      // Record the final location so Trash and Open target the moved files.
      if let i = items.firstIndex(where: { $0.id == itemID }) { items[i].location = to }

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

  // MARK: - Progress

  private static func checkID(_ algorithm: Checksum.Algorithm) -> String {
    DownloadProgress.checkID(algorithm: algorithm.rawValue)
  }

  /// Shows a download's progress and time left now, and keeps reading them on a timer while any download runs.
  private func refreshProgress(_ id: String) {
    guard let tracker = progress[id], let index = items.firstIndex(where: { $0.id == id }) else { return }
    let reading = tracker.reading()
    if items[index].progress != reading.fraction { items[index].progress = reading.fraction }
    let remaining = tracker.isRunning ? reading.remaining.map { $0.rounded() } : nil
    if items[index].remaining != remaining { items[index].remaining = remaining }
    if tracker.isRunning, progressTimer == nil {
      progressTimer = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(500))
          guard let self else { return }
          let running = self.progress.filter { $0.value.isRunning }.map(\.key)
          for id in running { self.refreshProgress(id) }
          if running.isEmpty {
            self.progressTimer = nil
            return
          }
        }
      }
    }
  }

  static func formatSpeed(_ bytesPerSecond: Double) -> String {
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
