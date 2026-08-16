import CryptoKit
import Foundation

// MARK: - Public API

/// User-facing settings for a torrent session. Defaults implement the Get
/// profile: sequential download, MSE-encrypted peers only, zero upload,
/// files saved into `~/Downloads`.
public struct TorrentSettings: Sendable, Equatable {
    public var saveDirectory: URL
    public var sequential: Bool = true
    public var encryptedPeersOnly: Bool = true
    public var allowUpload: Bool = false
    public var maxPeers: Int = 30
    public var pipelinePerPeer: Int = 4
    public var blockSize: Int = 16 * 1024

    public init() {
        saveDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
    }
}

public enum TorrentState: Sendable, Equatable {
    case stopped
    case checking
    case downloading
    case paused
    case completed
    case failed(String)
}

public struct TorrentStats: Sendable, Equatable {
    public var verifiedBytes: Int64
    public var totalBytes: Int64
    public var peersConnected: Int
    public var peersSeen: Int
    public var downloadSpeed: Double
    public var progress: Double

    public init(verifiedBytes: Int64 = 0, totalBytes: Int64 = 0,
                peersConnected: Int = 0, peersSeen: Int = 0,
                downloadSpeed: Double = 0, progress: Double = 0) {
        self.verifiedBytes = verifiedBytes
        self.totalBytes = totalBytes
        self.peersConnected = peersConnected
        self.peersSeen = peersSeen
        self.downloadSpeed = downloadSpeed
        self.progress = progress
    }
}

public enum TorrentEvent: Sendable {
    case state(TorrentState)
    case stats(TorrentStats)
    case pieceVerified(Int)
    case peer(PeerEvent)
    case error(String)
}

public enum PeerEvent: Sendable {
    case connected(String)
    case disconnected(String)
    case dropped(String)
}

/// One torrent download: tracker announces, peer management, sequential
/// piece fetching, SHA-1 verification, and disk writes. UI observes via
/// `events` (`AsyncStream<TorrentEvent>`).
public actor TorrentSession {
    private let torrent: TorrentFile
    private let settings: TorrentSettings
    private let ourPeerID: Data

    private let continuation: AsyncStream<TorrentEvent>.Continuation
    public let events: AsyncStream<TorrentEvent>

    private var picker: PiecePicker
    private var layout: FileLayout
    private var disk: DiskWriter

    private var state: TorrentState = .stopped
    private var paused = false
    private var stats = TorrentStats()
    private var verifiedPieces: Set<Int> = []
    private var pieceBuffers: [Int: [Int: Data]] = [:]
    private var pieceAttempts: [Int: Int] = [:]

    private var peers: [PeerID: PeerConnection] = [:]
    private var peerTasks: [PeerID: Task<Void, Never>] = [:]
    private var spawnedPeers: Set<PeerID> = []
    private var trackerTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var announcedPeers: [TrackerPeer] = []
    private var bytesAtLastTick: Int64 = 0

    public init(torrent: TorrentFile, settings: TorrentSettings) {
        self.torrent = torrent
        self.settings = settings
        self.ourPeerID = Self.makePeerID()

        var cont: AsyncStream<TorrentEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(200)) { cont = $0 }
        self.continuation = cont

        let pieceCount = torrent.pieceHashes.count
        let lastPieceLength = pieceCount > 0
            ? Int(torrent.totalSize - Int64(pieceCount - 1) * Int64(torrent.pieceLength))
            : 0
        self.picker = PiecePicker(pieceCount: pieceCount,
                                  pieceLength: torrent.pieceLength,
                                  lastPieceLength: lastPieceLength,
                                  blockSize: settings.blockSize)
        self.layout = try! FileLayout(torrent: torrent, baseDirectory: settings.saveDirectory)
        self.disk = DiskWriter(layout: layout, pieceLength: torrent.pieceLength)
        self.stats = TorrentStats(totalBytes: torrent.totalSize)
    }

    public static func parse(url: URL) throws -> TorrentFile {
        try TorrentFile.parse(url: url)
    }

    /// The announce URLs to try, tiers flattened (primary first).
    private var announceURLs: [URL] {
        var urls: [URL] = []
        for tier in torrent.announceList {
            for url in tier {
                if let parsed = URL(string: url) { urls.append(parsed) }
            }
        }
        if let announce = torrent.announce, let parsed = URL(string: announce), !urls.contains(parsed) {
            urls.append(parsed)
        }
        return urls
    }

    // MARK: - Lifecycle

    public func start() async throws {
        guard state == .stopped else { return }
        try await disk.prepare()
        state = .downloading
        emit(.state(.downloading))
        startStatsLoop()

        let peers = await announceStarted()
        announcedPeers = peers
        spawnPeerTasks(for: peers)

        if let interval = lastAnnounceInterval {
            trackerTask = Task { await self.trackerLoop(interval: interval) }
        }
    }

    public func pause() async {
        guard state == .downloading else { return }
        paused = true
        state = .paused
        emit(.state(.paused))
    }

    public func resume() async {
        guard state == .paused else { return }
        paused = false
        state = .downloading
        emit(.state(.downloading))
    }

    public func cancel() async {
        guard state != .stopped, state != .completed else { return }
        fireAndForgetAnnounce(event: "stopped")
        for (_, task) in peerTasks { task.cancel() }
        peerTasks.removeAll()
        for (_, connection) in peers { await connection.close() }
        peers.removeAll()
        trackerTask?.cancel()
        trackerTask = nil
        statsTask?.cancel()
        statsTask = nil
        await disk.close()
        state = .stopped
        emit(.state(.stopped))
        continuation.finish()
    }

    public func currentState() -> TorrentState { state }

    // MARK: - Trackers

    private var lastAnnounceInterval: Int?

    private func announceParams(event: String?) -> TrackerAnnounceParams {
        TrackerAnnounceParams(
            infoHash: torrent.infoHash,
            peerID: ourPeerID,
            port: 0,
            uploaded: 0,
            downloaded: stats.verifiedBytes,
            left: max(0, torrent.totalSize - stats.verifiedBytes),
            event: event,
            numwant: 50
        )
    }

    /// Announce `started` across all tracker URLs (HTTP then UDP), returning
    /// the union of announced peers.
    private func announceStarted() async -> [TrackerPeer] {
        var peers: [TrackerPeer] = []
        var interval: Int?
        for url in announceURLs {
            let params = announceParams(event: "started")
            if let response = try? await HTTPTracker.announce(url: url, params: params, timeout: .seconds(15)) {
                peers.append(contentsOf: response.peers)
                if interval == nil { interval = response.interval }
            } else if let response = try? await UDPTracker.announce(url: url, params: params, timeout: .seconds(15)) {
                peers.append(contentsOf: response.peers)
                if interval == nil { interval = response.interval }
            }
        }
        lastAnnounceInterval = interval
        return peers
    }

    private func trackerLoop(interval: Int) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(max(1, interval)))
            if Task.isCancelled { return }
            guard state == .downloading else { continue }
            let params = announceParams(event: nil)
            var fresh: [TrackerPeer] = []
            for url in announceURLs {
                if let response = try? await HTTPTracker.announce(url: url, params: params, timeout: .seconds(15)) {
                    fresh.append(contentsOf: response.peers)
                } else if let response = try? await UDPTracker.announce(url: url, params: params, timeout: .seconds(15)) {
                    fresh.append(contentsOf: response.peers)
                }
            }
            announcedPeers = fresh
            spawnPeerTasks(for: fresh)
        }
    }

    private func fireAndForgetAnnounce(event: String?) {
        guard let url = announceURLs.first else { return }
        let params = announceParams(event: event)
        Task { try? await HTTPTracker.announce(url: url, params: params, timeout: .seconds(10)) }
    }

    // MARK: - Peers

    private func spawnPeerTasks(for announced: [TrackerPeer]) {
        for peer in announced where peerTasks.count < settings.maxPeers {
            let key = Self.peerKey(host: peer.host, port: peer.port)
            guard peerTasks[key] == nil, !spawnedPeers.contains(key) else { continue }
            spawnedPeers.insert(key)
            let host = peer.host
            let port = peer.port
            let task = Task { await self.runPeer(host: host, port: port, key: key) }
            peerTasks[key] = task
        }
    }

    private static func peerKey(host: String, port: UInt16) -> PeerID {
        PeerID(raw: Data(("\(host):\(port)").utf8))
    }

    /// The per-peer download loop, running on the session actor.
    private func runPeer(host: String, port: UInt16, key: PeerID) async {
        let connection = PeerConnection(host: host, port: port,
                                        infoHash: torrent.infoHash,
                                        peerID: ourPeerID,
                                        encryptedOnly: settings.encryptedPeersOnly,
                                        connectTimeout: .seconds(15),
                                        readTimeout: .seconds(90))
        peers[key] = connection
        var choked = true
        var sentOurBitfield = false
        var loggedNoUpload = false
        var established = false

        defer {
            picker.disconnect(key)
            peers[key] = nil
            peerTasks[key] = nil
            stats.peersConnected = max(0, stats.peersConnected - 1)
            Task { await connection.close() }
        }

        do {
            try await connection.start()
            established = true
            stats.peersConnected += 1
            stats.peersSeen += 1
            emit(.peer(.connected("\(host):\(port)")))
            try await connection.send(.interested)

            while !Task.isCancelled {
                // Keep the pipeline full while unchoked (and not paused).
                if !paused, !choked {
                    while let block = picker.request(for: key, pipeline: settings.pipelinePerPeer) {
                        try await connection.send(.request(index: block.piece,
                                                           begin: block.begin,
                                                           length: block.length))
                    }
                }
                if case .completed = state { break }

                let message = try await connection.receiveMessage()
                switch message {
                case .choke:
                    choked = true
                case .unchoke:
                    choked = false
                case .bitfield(let bits):
                    picker.setAvailable(piecesFromBitfield(bits), on: key)
                    if !sentOurBitfield {
                        try await connection.send(.bitfield(Data(repeating: 0,
                                                                count: (picker.pieceCount + 7) / 8)))
                        sentOurBitfield = true
                    }
                case .have(let piece):
                    var available = picker.peerHas[key] ?? []
                    available.insert(piece)
                    picker.setAvailable(available, on: key)
                case .piece(let index, let begin, let data):
                    await handlePiece(index: index, begin: begin, data: data, key: key)
                case .request, .cancel, .interested, .notInterested, .keepAlive:
                    // No-upload enforcement: never respond to request/piece.
                    if !loggedNoUpload, case .request = message {
                        loggedNoUpload = true
                    }
                }
                if case .completed = state { break }
            }
        } catch let error as PeerConnectionError {
            if case .peerDoesNotSupportEncryption = error {
                emit(.peer(.dropped("\(host):\(port) — plaintext peer rejected")))
            } else if established {
                emit(.peer(.disconnected("\(host):\(port) — \(error)")))
            } else {
                emit(.peer(.dropped("\(host):\(port) — \(error)")))
            }
        } catch {
            // Any failure before the connection was established (including a
            // cancellation racing the connect) means the peer never became
            // usable — report it as dropped, not disconnected.
            if established {
                emit(.peer(.disconnected("\(host):\(port) — \(error)")))
            } else {
                emit(.peer(.dropped("\(host):\(port) — \(error)")))
            }
        }
    }

    /// Decode a peer bitfield into the set of pieces it has (trailing bits
    /// beyond the piece count are masked off).
    private func piecesFromBitfield(_ data: Data) -> Set<Int> {
        var pieces: Set<Int> = []
        for (byteIndex, byte) in data.enumerated() {
            for bit in 0..<8 {
                let piece = byteIndex * 8 + bit
                guard piece < picker.pieceCount else { return pieces }
                if byte & (1 << (7 - bit)) != 0 { pieces.insert(piece) }
            }
        }
        return pieces
    }

    // MARK: - Pieces

    private func handlePiece(index: Int, begin: Int, data: Data, key: PeerID) async {
        guard index >= 0, index < picker.pieceCount, begin >= 0 else { return }
        let pieceSize = picker.pieceSize(of: index)
        let expectedLength = min(settings.blockSize, pieceSize - begin)
        guard begin < pieceSize, data.count == expectedLength else {
            // Malformed block: drop it (the picker slot frees and the block
            // gets re-requested).
            picker.complete(PiecePicker.BlockKey(piece: index, begin: begin), on: key)
            return
        }

        pieceBuffers[index, default: [:]][begin] = data
        picker.complete(PiecePicker.BlockKey(piece: index, begin: begin), on: key)

        let blocks = picker.blockCount(of: index)
        guard pieceBuffers[index]?.count == blocks else { return }

        // Assemble, hash, verify, write.
        var assembled = Data()
        assembled.reserveCapacity(pieceSize)
        for b in 0..<blocks {
            let beginOffset = b * settings.blockSize
            guard let blockData = pieceBuffers[index]?[beginOffset] else { return }
            assembled.append(blockData)
        }
        pieceBuffers[index] = nil

        let hash = Data(Insecure.SHA1.hash(data: assembled))
        guard hash == torrent.pieceHashes[index] else {
            pieceAttempts[index, default: 0] += 1
            if pieceAttempts[index]! >= 3 {
                state = .failed("piece \(index) hash mismatch after 3 attempts")
                emit(.state(state))
                continuation.finish()
                return
            }
            // Clear the buffer and let the picker re-request this piece.
            return
        }

        do {
            try await disk.write(piece: index, data: assembled)
        } catch {
            state = .failed("disk write failed for piece \(index): \(error)")
            emit(.state(state))
            continuation.finish()
            return
        }

        verifiedPieces.insert(index)
        picker.advancePast(index)
        stats.verifiedBytes += Int64(pieceSize)
        emit(.pieceVerified(index))

        if verifiedPieces.count == picker.pieceCount {
            await finishDownload()
        }
    }

    private func finishDownload() async {
        guard state != .completed else { return }
        state = .completed
        emit(.state(.completed))
        fireAndForgetAnnounce(event: "completed")
        for (_, task) in peerTasks { task.cancel() }
        peerTasks.removeAll()
        trackerTask?.cancel()
        trackerTask = nil
        statsTask?.cancel()
        statsTask = nil
        await disk.close()
        continuation.finish()
    }

    // MARK: - Stats

    private func startStatsLoop() {
        statsTask = Task { await self.statsLoop() }
    }

    private func statsLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            let now = stats.verifiedBytes
            let delta = now - bytesAtLastTick
            bytesAtLastTick = now
            stats.downloadSpeed = Double(delta)
            stats.progress = stats.totalBytes > 0
                ? Double(stats.verifiedBytes) / Double(stats.totalBytes)
                : 1
            emit(.stats(stats))
        }
    }

    // MARK: - Helpers

    private func emit(_ event: TorrentEvent) {
        continuation.yield(event)
    }

    /// A 20-byte client peer id: `-GE0001-` + 12 random alphanumerics.
    private static func makePeerID() -> Data {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".utf8)
        var bytes = Array("-GE0001-".utf8)
        for _ in 0..<12 {
            bytes.append(alphabet[Int.random(in: 0..<alphabet.count)])
        }
        return Data(bytes)
    }
}
