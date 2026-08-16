import Foundation
import Observation
import Torrent

/// Owns the torrent sessions backing the UI. Holds one `DownloadItem` per
/// active torrent, keyed by infohash hex, and fans session events into the
/// matching item on the main actor.
@MainActor
@Observable
final class DownloadStore {

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
    }

    private(set) var items: [DownloadItem] = []

    /// Set when `openTorrent` fails, for the view to surface as an alert.
    var lastError: String?

    private var sessions: [String: TorrentSession] = [:]
    private var eventTasks: [String: Task<Void, Never>] = [:]

    /// Parse a `.torrent` file and start downloading it.
    func openTorrent(url: URL) async throws {
        let torrent = try TorrentSession.parse(url: url)
        let id = torrent.infoHash.map { String(format: "%02x", $0) }.joined()

        // Already known (or still listed after cancel) — don't duplicate.
        guard !items.contains(where: { $0.id == id }) else { return }

        let session = TorrentSession(torrent: torrent, settings: TorrentSettings())
        sessions[id] = session
        items.append(DownloadItem(id: id, title: torrent.name))

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
