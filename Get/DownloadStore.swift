import Foundation
import Observation
import os
import Torrent

/// Owns the torrent sessions backing the UI. Holds one `DownloadItem` per
/// active torrent, keyed by infohash hex, and fans session events into the
/// matching item on the main actor.
@MainActor
@Observable
final class DownloadStore {
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
        /// Download priority: 0 = none (after all prioritized files),
        /// 1...4 = fetched in priority order.
        var priority: Int = 0
        /// True while this file's pieces are not being fetched.
        var isPaused: Bool = false

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
        var error: String?
        /// The torrent's files (empty for non-torrent downloads).
        var files: [DownloadFileItem] = []
    }

    private(set) var items: [DownloadItem] = []

    /// Set when `openTorrent` fails, for the view to surface as an alert.
    var lastError: String?

    private var sessions: [String: TorrentSession] = [:]
    private var eventTasks: [String: Task<Void, Never>] = [:]

    /// Where copies of active `.torrent` files live so downloads can be
    /// resumed on relaunch: `~/Library/Application Support/Get/Torrents/`.
    private static var torrentsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first!
            .appendingPathComponent("Get/Torrents", isDirectory: true)
    }

    init() {
        // Reopen every torrent that was active in a previous run. Sessions
        // pick up the persisted resume state automatically (verified pieces
        // are skipped), so interrupted downloads continue on relaunch.
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.torrentsDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension.lowercased() == "torrent" {
            // Errors (corrupt copy, missing data) must not spam the launch;
            // a failed restore is just a skipped download.
            Task { try? await openTorrent(url: url) }
        }
        if !files.isEmpty {
            Self.log.info("Resuming \(files.count) saved download(s)")
        }
    }

    /// Open a `.torrent` file from any source (file importer, drag & drop,
    /// "Open With…"). Starts the download; failures surface as `lastError`.
    func open(url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            try await openTorrent(url: url)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Parse a `.torrent` file and start downloading it.
    func openTorrent(url: URL) async throws {
        let torrent = try TorrentSession.parse(url: url)
        let id = torrent.infoHash.map { String(format: "%02x", $0) }.joined()

        // Already known (or still listed after cancel) — don't duplicate.
        guard !items.contains(where: { $0.id == id }) else { return }

        // Keep a copy so the download can be resumed on relaunch.
        persistTorrentCopy(from: url, id: id)

        let session = TorrentSession(torrent: torrent, settings: TorrentSettings())
        sessions[id] = session
        let files = torrent.files.enumerated().map { index, file in
            DownloadFileItem(index: index,
                             path: file.path.joined(separator: "/"),
                             length: file.length)
        }
        items.append(DownloadItem(id: id, title: torrent.name, files: files))

        let task = Task { [weak self] in
            defer { self?.eventTasks[id] = nil }
            for await event in await session.events {
                self?.apply(event, to: id)
            }
        }
        eventTasks[id] = task

        do {
            try await session.start()
        } catch {
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

        // Move the download's files to the Trash (best effort — a download
        // that never wrote anything has nothing to trash).
        let root = await session.dataRootURL()
        try? FileManager.default.trashItem(at: root, resultingItemURL: nil)

        items.removeAll { $0.id == itemID }
        removeTorrentCopy(id: itemID)
        try? FileManager.default.removeItem(at: ResumeState.fileURL(infoHashHex: itemID))
    }

    /// Pause the whole download (stops requesting; in-flight blocks finish).
    func pause(itemID: String) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].state == .downloading else { return }
        items[index].state = .paused
        Task { await sessions[itemID]?.pause() }
    }

    /// Resume a paused download.
    func resume(itemID: String) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].state == .paused else { return }
        items[index].state = .downloading
        Task { await sessions[itemID]?.resume() }
    }

    /// Toggle pause/resume for a whole download (for sidebar buttons).
    func togglePause(itemID: String) {
        if let index = items.firstIndex(where: { $0.id == itemID }),
           items[index].state == .paused {
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
              items[index].files.indices.contains(fileIndex) else { return }
        items[index].files[fileIndex].priority = priority
        pushPriorities(itemID: itemID)
    }

    /// Clear every priority for a torrent (entering priority mode).
    func clearAllPriorities(itemID: String) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        for fileIndex in items[index].files.indices {
            items[index].files[fileIndex].priority = 0
        }
        pushPriorities(itemID: itemID)
    }

    private func pushPriorities(itemID: String) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        let table = Dictionary(uniqueKeysWithValues:
            items[index].files.compactMap { file in
                file.priority > 0 ? (file.index, file.priority) : nil
            })
        Task { await sessions[itemID]?.setFilePriorities(table) }
    }

    // MARK: - Per-file pause

    /// Pause or resume one file: its pieces drop out of the fetch order
    /// until resumed.
    func setFilePaused(_ paused: Bool, fileIndex: Int, itemID: String) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].files.indices.contains(fileIndex) else { return }
        items[index].files[fileIndex].isPaused = paused
        Task { await sessions[itemID]?.setFilePaused(paused, fileIndex: fileIndex) }
    }

    /// Toggle one file's paused state (for row buttons).
    func toggleFilePaused(fileIndex: Int, itemID: String) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].files.indices.contains(fileIndex) else { return }
        setFilePaused(!items[index].files[fileIndex].isPaused,
                      fileIndex: fileIndex, itemID: itemID)
    }

    // MARK: - Persistence (resume on relaunch)

    /// Copy a `.torrent` file into the app's library so the download can be
    /// resumed after a relaunch. Best effort — a failed copy just means no
    /// auto-resume for this torrent.
    private func persistTorrentCopy(from url: URL, id: String) {
        do {
            let data = try Data(contentsOf: url)
            try FileManager.default.createDirectory(at: Self.torrentsDirectory,
                                                    withIntermediateDirectories: true)
            try data.write(to: Self.torrentsDirectory
                .appendingPathComponent("\(id).torrent"), options: .atomic)
        } catch {
            // Best effort: skip auto-resume for this torrent.
        }
    }

    private func removeTorrentCopy(id: String) {
        try? FileManager.default.removeItem(
            at: Self.torrentsDirectory.appendingPathComponent("\(id).torrent"))
    }

    // MARK: - Events

    private func apply(_ event: TorrentEvent, to id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch event {
        case .state(let state):
            items[index].state = state
            if case .failed(let message) = state {
                items[index].error = message
            }
        case .stats(let stats):
            items[index].progress = stats.progress
            items[index].speed = Self.formatSpeed(stats.downloadSpeed)
            items[index].peers = stats.peersConnected
            if stats.fileVerifiedBytes.count == items[index].files.count {
                for fileIndex in items[index].files.indices {
                    items[index].files[fileIndex].verifiedBytes = stats.fileVerifiedBytes[fileIndex]
                }
            }
        case .error(let message):
            items[index].error = message
        case .pieceVerified, .peer:
            break
        }
    }

    private static func formatSpeed(_ bytesPerSecond: Double) -> String {
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
