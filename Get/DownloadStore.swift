import Foundation
import Observation
import Torrent

/// Owns the torrent sessions backing the UI. Holds one `DownloadItem` per
/// active torrent, keyed by infohash hex, and fans session events into the
/// matching item on the main actor.
@MainActor
@Observable
final class DownloadStore {

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

    /// Stop a download and clean up its session.
    func cancel(itemID: String) {
        eventTasks[itemID]?.cancel()
        eventTasks[itemID] = nil

        guard let session = sessions.removeValue(forKey: itemID) else { return }
        Task { await session.cancel() }

        if let index = items.firstIndex(where: { $0.id == itemID }) {
            items[index].state = .stopped
            items[index].speed = ""
            items[index].peers = 0
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
