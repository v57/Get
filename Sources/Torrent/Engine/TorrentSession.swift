import CryptoKit
import GetKit
import Foundation
import os

// MARK: - Public API

/// User-facing settings for a torrent session. Defaults implement the Get
/// profile: sequential download, MSE-encrypted peers only, zero upload,
/// files saved into `~/Downloads`.
public struct TorrentSettings: Sendable, Equatable {
  public var saveDirectory: URL
  public var sequential: Bool = true
  public var encryptedPeersOnly: Bool = true
  public var allowUpload: Bool = false
  public var maxPeers: Int = 80
  /// Starting blocks in flight per peer before its speed is known.
  /// 16 KiB blocks × 64 = 1 MiB outstanding — enough for a slow start
  /// without binding a fast peer.
  public var pipelinePerPeer: Int = 64
  /// Hard ceiling on blocks in flight per peer (Transmission uses ~250).
  /// The per-peer queue is sized adaptively from the peer's measured
  /// download rate (see `PeerRateTracker`), clamped to this.
  public var maxPipelinePerPeer: Int = 250
  public var blockSize: Int = 16 * 1024
  /// The local port advertised to trackers. Get is zero-upload and never
  /// accepts inbound connections, so peers won't reach it — but trackers
  /// validate that `port` is a real port, so it must be non-zero.
  public var listenPort: UInt16 = 6881
  /// Whether to run a BEP 5 DHT node to discover peers beyond trackers.
  /// Off by default (keeps headless tests hermetic); the app enables it.
  public var useDHT: Bool = false
  /// Advertise the local peer id / port via PEX when a peer supports it.
  public var usePEX: Bool = false
  /// Accept inbound peer connections (bind a listener on `listenPort` and
  /// answer the MSE responder handshake). Off by default (keeps headless
  /// tests hermetic); the app enables it so other clients can connect to
  /// us as a peer.
  public var useInbound: Bool = false

  public init() {
    saveDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Downloads")
  }
}

/// Tracks one peer's measured download rate (bytes/sec, EMA over 500ms
/// windows) and derives how many blocks to keep in flight for it.
///
/// A flat per-peer pipeline caps throughput: in-flight bytes / RTT is the
/// max rate that peer can deliver, so a 64-block (1 MiB) queue tops out at
/// ~10 MB/s on a 100 ms-RTT peer. Real clients (libtorrent) instead size the
/// queue to ~2-3 s of the peer's *measured* rate — a fast peer gets a deep
/// queue (up to the clamp) and can saturate the link alone, while a slow
/// peer doesn't pile up requests it can't serve.
struct PeerRateTracker: Sendable {
  /// EMA window length; injectable so tests can close windows without
  /// sleeping (default 500ms).
  var window: Duration = .milliseconds(500)
  /// Injectable time source (nanoseconds); defaults to the monotonic clock.
  private let nowNanos: @Sendable () -> Int64
  private var bytesSinceWindow: Int64 = 0
  private var lastWindowStart: Int64
  private var emaBytesPerSecond: Double = 0

  init(
    nowNanos: @escaping @Sendable () -> Int64 = {
      // Monotonic nanoseconds since boot (DispatchTime.uptimeNanoseconds).
      Int64(DispatchTime.now().uptimeNanoseconds)
    }
  ) {
    self.nowNanos = nowNanos
    self.lastWindowStart = nowNanos()
  }

  /// Feed bytes received from the peer. Recomputes the EMA every `window`.
  mutating func record(bytes added: Int64) {
    bytesSinceWindow += added
    let now = nowNanos()
    let elapsedNanos = now - lastWindowStart
    // window in nanoseconds: Duration is attoseconds, so /1e9.
    let windowNanos = window.components.attoseconds / 1_000_000_000
    guard elapsedNanos >= windowNanos else { return }
    let seconds = Double(elapsedNanos) / 1e9
    guard seconds > 0 else { return }
    let instant = Double(bytesSinceWindow) / seconds
    emaBytesPerSecond = emaBytesPerSecond == 0 ? instant : emaBytesPerSecond * 0.7 + instant * 0.3
    bytesSinceWindow = 0
    lastWindowStart = now
  }

  /// Blocks to keep in flight: ~2 s of buffered data at the measured rate,
  /// clamped to `min` (until the rate is known) and `max` (sanity ceiling).
  func pipelineDepth(blockSize: Int, min: Int, max: Int) -> Int {
    let target = Int(emaBytesPerSecond * 2.0 / Double(blockSize))
    return Swift.min(Swift.max(target, min), max)
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
  /// Peers currently connected that hold every piece (seeders). Derived
  /// from each peer's announced bitfield.
  public var seedersConnected: Int
  /// Seeders/leechers reported by the tracker at the last successful
  /// announce, when the tracker provides them.
  public var trackerSeeders: Int?
  public var trackerLeechers: Int?
  public var downloadSpeed: Double
  public var progress: Double
  /// Verified bytes per file, in torrent file order (exact attribution
  /// including pieces that straddle file boundaries).
  public var fileVerifiedBytes: [Int64]
  /// Contiguous verified prefix bytes per file, in torrent file order —
  /// how much of each file is playable from its start (the sequential
  /// download head, which stops at the first gap).
  public var fileSequentialBytes: [Int64]

  public init(
    verifiedBytes: Int64 = 0, totalBytes: Int64 = 0, peersConnected: Int = 0, peersSeen: Int = 0,
    seedersConnected: Int = 0, trackerSeeders: Int? = nil, trackerLeechers: Int? = nil,
    downloadSpeed: Double = 0, progress: Double = 0, fileVerifiedBytes: [Int64] = [],
    fileSequentialBytes: [Int64] = []
  ) {
    self.verifiedBytes = verifiedBytes
    self.totalBytes = totalBytes
    self.peersConnected = peersConnected
    self.peersSeen = peersSeen
    self.seedersConnected = seedersConnected
    self.trackerSeeders = trackerSeeders
    self.trackerLeechers = trackerLeechers
    self.downloadSpeed = downloadSpeed
    self.progress = progress
    self.fileVerifiedBytes = fileVerifiedBytes
    self.fileSequentialBytes = fileSequentialBytes
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
  public static let log = Logger(subsystem: "dev.v57.get", category: "engine")

  /// Drop a peer that holds a requested block past this age. A peer that
  /// keeps delivering OTHER blocks but silently withholds one request
  /// freezes the sequential download (the cursor can't advance past an
  /// unassembled piece), and the 90 s read timeout never fires because the
  /// peer is still sending. Freeing its blocks lets them be re-requested
  /// elsewhere.
  private static let blockStallTimeout: TimeInterval = 60
  // A peer with an empty pipeline and nothing requestable must not spin a
  // 500ms timer forever (see blockStallTimeout above for why peers stall) —
  // back off to a multi-second idle poll so a momentary swarm gap or a
  // choked/blank peer doesn't burn a core. While paused we keep a fast poll
  // so an unpause or priority change is noticed promptly.
  private static let idlePollFast: Duration = .milliseconds(500)
  private static let idlePollBackoff: Duration = .milliseconds(2500)

  private let torrent: TorrentFile
  private let settings: TorrentSettings
  private let ourPeerID: Data

  private let continuation: AsyncStream<TorrentEvent>.Continuation
  public let events: AsyncStream<TorrentEvent>

  private var picker: PiecePicker
  private var layout: FileLayout
  private var disk: DiskWriter
  /// Piece → file index, computed once from the layout.
  private let pieceFile: [Int]
  /// File index → position in natural name order (`naturalFileOrder`), the
  /// order files are downloaded in after priorities.
  private let filePosition: [Int]
  /// File index → download priority (1...4). Unprioritized files are
  /// fetched after every prioritized one.
  private var filePriorities: [Int: Int] = [:]
  /// Files whose pieces must not be fetched (until resumed).
  private var pausedFiles: Set<Int> = []
  /// Files the user removed from the download: their pieces are excluded from
  /// the fetch order, their on-disk data is deleted, and they do not count
  /// toward completion. Restoring a file re-includes it and re-downloads it.
  private var removedFiles: Set<Int> = []

  private var state: TorrentState = .stopped
  private var paused = false
  private var stats = TorrentStats()
  private var verifiedPieces: Set<Int> = []
  private var pieceBuffers: [Int: [Int: Data]] = [:]
  private var pieceAttempts: [Int: Int] = [:]

  private var peers: [PeerID: PeerConnection] = [:]
  private var peerTasks: [PeerID: Task<Void, Never>] = [:]
  private var spawnedPeers: Set<PeerID> = []
  /// Per-peer adaptive pipeline depth (see `PeerRateTracker`). Updated by
  /// `handlePiece` as blocks arrive; read by the peer loop to size requests.
  private var peerRates: [PeerID: PeerRateTracker] = [:]
  private var trackerTask: Task<Void, Never>?
  private var statsTask: Task<Void, Never>?
  private var dhtTask: Task<Void, Never>?
  /// A BEP 5 DHT node (created only when `settings.useDHT`) for extra peers.
  private var dht: DHTNode?
  /// Accepts inbound peer connections (created when `settings.useInbound`).
  private var acceptor: PeerAcceptor?
  private var announcedPeers: [TrackerPeer] = []
  /// Block payload bytes received from peers (duplicates and later-failed
  /// pieces included): what the network delivers, as it arrives. Speed is
  /// measured on this rather than on verified bytes, which only grow a whole
  /// piece at a time and made the speed jump between 0 and the full rate.
  private var receivedBytes: Int64 = 0
  private var speedMeter = SpeedMeter()
  /// Seed/leech counts from the last successful announce (tracker-reported).
  private var trackerSeeders: Int?
  private var trackerLeechers: Int?
  /// Diagnostics: frontier-progress tracking for the `DIAG` + `NO-PROGRESS`
  /// log lines (a 60s+ frontier stall is what a stuck download looks like).
  /// Reset whenever a piece verifies; `diagStallSince` marks when progress
  /// first stopped so a log line can say how long it has sat.
  private var diagProgressLastCount = -1
  private var diagStallSince: Date?
  private var diagTicks = 0
  /// False until this session has connected to the swarm (announced + started
  /// discovery loops). A download restored already-paused skips the swarm at
  /// start() and stays false until resume() connects it.
  private var swarmConnected = false

  public init(torrent: TorrentFile, settings: TorrentSettings) {
    self.torrent = torrent
    self.settings = settings
    self.ourPeerID = Self.makePeerID()

    var cont: AsyncStream<TorrentEvent>.Continuation!
    self.events = AsyncStream(bufferingPolicy: .bufferingNewest(200)) { cont = $0 }
    self.continuation = cont

    let pieceCount = torrent.pieceHashes.count
    let lastPieceLength =
      pieceCount > 0
      ? Int(torrent.totalSize - Int64(pieceCount - 1) * Int64(torrent.pieceLength)) : 0
    self.picker = PiecePicker(
      pieceCount: pieceCount, pieceLength: torrent.pieceLength, lastPieceLength: lastPieceLength,
      blockSize: settings.blockSize)
    self.layout = try! FileLayout(torrent: torrent, baseDirectory: settings.saveDirectory)
    self.disk = DiskWriter(layout: layout, pieceLength: torrent.pieceLength)

    // Piece → file: each piece belongs to the file containing its first
    // byte (a straddling piece is attributed to the file it starts in).
    var pieceFile: [Int] = []
    pieceFile.reserveCapacity(pieceCount)
    for piece in 0..<pieceCount {
      let offset = Int64(piece) * Int64(torrent.pieceLength)
      pieceFile.append(layout.fileIndex(ofByteOffset: offset))
    }
    self.pieceFile = pieceFile
    var filePosition = [Int](repeating: 0, count: torrent.files.count)
    for (position, file) in torrent.naturalFileOrder.enumerated() { filePosition[file] = position }
    self.filePosition = filePosition

    self.stats = TorrentStats(
      totalBytes: torrent.totalSize,
      fileVerifiedBytes: [Int64](repeating: 0, count: layout.entries.count))
    self.dht = settings.useDHT ? (try? DHTNode()) : nil
    // The inbound acceptor is created in start() (its closure captures
    // self, which is not safe during init).
    // Files download in natural name order until priorities, paused or
    // removed files (from resume state or the user) rebuild the order.
    let fetch = Self.fetchOrder(
      pieceCount: pieceCount, pieceLength: Int64(torrent.pieceLength),
      totalSize: torrent.totalSize, fileEnds: layout.fileEnds, filePosition: filePosition,
      priorities: [:], skipped: [], verified: [])
    self.picker.setOrder(fetch.order)
    // Make the picker file-aware so a download finishes the current file
    // before fetching a later file's pieces (each file downloads sequentially
    // from its start). Single-file torrents map every piece to file 0, i.e.
    // no cross-file restriction.
    self.picker.setFiles(fetch.pieceFile)
  }

  public static func parse(url: URL) throws -> TorrentFile { try TorrentFile.parse(url: url) }

  /// The announce URLs to try, tiers flattened (primary first).
  private var announceURLs: [URL] {
    var urls: [URL] = []
    for tier in torrent.announceList {
      for url in tier { if let parsed = URL(string: url) { urls.append(parsed) } }
    }
    if let announce = torrent.announce, let parsed = URL(string: announce), !urls.contains(parsed) {
      urls.append(parsed)
    }
    return urls
  }

  // MARK: - Lifecycle

  public func start(initiallyPaused: Bool = false) async throws {
    guard state == .stopped else { return }
    // Seed resume state before prepare(): a resume is only valid when the
    // data files already exist in the save directory, and prepare() would
    // create them from scratch. Claimed-verified pieces are re-verified
    // against the disk before being trusted.
    await applyResumeState(reverify: !initiallyPaused)

    if verifiedPieces.count == picker.pieceCount {
      // Every piece already verified in a previous session: go straight
      // to completion without announcing.
      await finishDownload()
      return
    }

    try await disk.prepare()
    if initiallyPaused {
      // A download restored already-paused brings the engine up (resume state
      // loaded, files prepared) but stays idle: it must NOT re-hash the disk
      // for verified pieces, announce to trackers, bootstrap DHT, bind the
      // inbound listener, or spawn peers. The swarm is only connected from
      // resume(), which is what a paused download is waiting for.
      paused = true
      state = .paused
      emit(.state(state))
      startStatsLoop()
      return
    }
    state = .downloading
    emit(.state(state))
    startStatsLoop()

    await connectToSwarm()
  }

  /// Bind the inbound listener (if enabled), announce to the trackers, and
  /// start the DHT + tracker discovery loops. Called from a running start()
  /// and from resume() when a download was restored already-paused (which
  /// never connected at launch).
  private func connectToSwarm() async {
    // Bind the inbound listener BEFORE announcing so the advertised port is
    // the one actually listening. The acceptor is created here (its closure
    // captures self, which is unsafe during init).
    if settings.useInbound, acceptor == nil {
      acceptor = PeerAcceptor(
        infoHash: torrent.infoHash, peerID: ourPeerID, encryptedOnly: settings.encryptedPeersOnly,
        connectTimeout: .seconds(15), readTimeout: .seconds(90)
      ) { [weak self] peer in await self?.runInboundPeer(peer) }
    }
    if let acceptor {
      do {
        try await acceptor.start(port: settings.listenPort)
        self.boundListenerPort = await acceptor.port()
        Self.log.info("listening on port \(self.boundListenerPort ?? 0, privacy: .public)")
      } catch { Self.log.error("inbound listener failed: \(error, privacy: .public)") }
    }

    let peers = await announceStarted()
    announcedPeers = peers
    Self.log.info("announce returned \(peers.count, privacy: .public) peer(s)")
    spawnPeerTasks(for: peers)

    // DHT peer discovery (when enabled): bootstrap, then iteratively query
    // for peers on a timer — the swarm changes, and each pass samples new
    // nodes/peers.
    if let dht, dhtTask == nil {
      dhtTask = Task {
        await dht.bootstrap()
        while !Task.isCancelled {
          // No discovery while paused/completed — peer spawn is download-only.
          guard state == .downloading else {
            try? await Task.sleep(for: .seconds(5))
            continue
          }
          let found = await dht.getPeers(infoHash: torrent.infoHash)
          let peers = found.map { TrackerPeer(host: $0.ip, port: $0.port) }
          if !peers.isEmpty {
            Self.log.info("DHT found \(peers.count, privacy: .public) peer(s)")
            self.spawnPeerTasks(for: peers)
          }
          await dht.announcePeer(infoHash: torrent.infoHash, port: advertisedPort)
          try? await Task.sleep(for: .seconds(90))
        }
      }
    }

    if trackerTask == nil, let interval = lastAnnounceInterval {
      trackerTask = Task { await self.trackerLoop(interval: interval) }
    }
    swarmConnected = true
  }

  public func pause() async {
    guard state == .downloading else { return }
    paused = true
    state = .paused
    emit(.state(.paused))
    speedMeter.reset()
    stats.downloadSpeed = 0
    // Stop in-flight traffic decisively: ask each peer to drop the blocks we
    // queued and free the picker's pending slots so nothing more is fetched.
    // (Blocks that already reached us still complete and verify — that keeps
    // the resume state truthful.) With nothing pending, the peer loop drops
    // into its short idle poll and sits quiet until resume.
    // Snapshot the dict: each cancel awaits, and actor reentrancy can remove
    // a peer's entry mid-iteration (a disconnect is processed in an await),
    // so iterating the live dict would be "mutated while enumerated".
    let peerSnapshot = peers
    for (key, connection) in peerSnapshot {
      let pending = picker.pending[key] ?? []
      for block in pending {
        let length = min(settings.blockSize, picker.pieceSize(of: block.piece) - block.begin)
        try? await connection.send(.cancel(index: block.piece, begin: block.begin, length: length))
      }
      picker.clearPending(on: key)
    }
    // A paused download must not keep connections to the swarm: close the
    // peers (queued blocks are dropped, in-flight ones are re-requested on
    // resume). The tracker/DHT loops already idle on state == .paused.
    for (_, task) in peerTasks { task.cancel() }
    peerTasks.removeAll()
    for (_, connection) in peers { await connection.close() }
    peers.removeAll()
    saveResumeState()
  }

  public func resume() async {
    guard state == .paused else { return }
    paused = false
    state = .downloading
    emit(.state(.downloading))
    if !swarmConnected {
      // Restored already-paused: it never announced or connected at launch,
      // so bring the swarm up now (announce + discovery loops + peers).
      await connectToSwarm()
    } else {
      // Paused mid-download: pause() closed the peers; re-spawn the tracked
      // pool so it reconnects promptly rather than waiting for the next
      // discovery tick.
      spawnPeerTasks(for: announcedPeers)
    }
  }

  public func cancel() async {
    guard state != .stopped, state != .completed else { return }
    // Persist progress before tearing down so a later session can resume
    // from here without re-fetching verified pieces.
    saveResumeState()
    fireAndForgetAnnounce(event: "stopped")
    for (_, task) in peerTasks { task.cancel() }
    peerTasks.removeAll()
    for (_, connection) in peers { await connection.close() }
    peers.removeAll()
    trackerTask?.cancel()
    trackerTask = nil
    statsTask?.cancel()
    statsTask = nil
    dhtTask?.cancel()
    dhtTask = nil
    dht?.close()
    await acceptor?.stop()
    await disk.close()
    state = .stopped
    emit(.state(.stopped))
    continuation.finish()
  }

  public func currentState() -> TorrentState { state }

  /// The top-level thing this download owns on disk (the single file, or
  /// the `<name>/` directory for multi-file torrents) — the unit to move
  /// to Trash when the download is deleted.
  public func dataRootURL() -> URL { layout.rootURL }

  // MARK: - File priorities

  /// Set per-file download priorities (file index → 1...4). Pieces of
  /// priority-1 files are fetched first, then 2, 3, 4, and finally every
  /// unprioritized file — the picker's fetch order is rebuilt immediately,
  /// so changes apply to a running download too. Invalid indices and
  /// priorities outside 1...4 are ignored.
  public func setFilePriorities(_ priorities: [Int: Int]) {
    filePriorities = priorities.filter { entry in
      entry.value >= 1 && entry.value <= 4 && entry.key >= 0 && entry.key < layout.entries.count
    }
    rebuildOrder()
    saveResumeState()
  }

  /// Pause or resume one file: paused files' pieces drop out of the fetch
  /// order entirely (in-flight pieces still complete), so nothing more is
  /// downloaded for them until they're resumed. Applies to a running
  /// download immediately. Persisted so a relaunch keeps the file paused.
  public func setFilePaused(_ paused: Bool, fileIndex: Int) {
    guard fileIndex >= 0, fileIndex < layout.entries.count else { return }
    if paused { pausedFiles.insert(fileIndex) } else { pausedFiles.remove(fileIndex) }
    rebuildOrder()
    saveResumeState()
  }

  /// Rebuild the picker's fetch order from the current priorities and
  /// paused/removed files (see `fetchOrder`): verified pieces and pieces only
  /// paused/removed files need are left out. The picker's piece → file map
  /// follows the same attribution, so its "finish the current file first"
  /// preference matches the order.
  ///
  /// A piece can straddle a paused file and an active one (e.g. the active
  /// file begins mid-piece inside a paused file's last piece). That piece is
  /// still fetched, for the active file, so the active file's leading bytes
  /// download and its sequential head grows. The piece's bytes in the paused
  /// file are written too (a paused file is not removed, so DiskWriter does
  /// not skip it), a negligible side-effect of the shared boundary piece.
  private func rebuildOrder() {
    let fetch = Self.fetchOrder(
      pieceCount: picker.pieceCount, pieceLength: Int64(torrent.pieceLength),
      totalSize: torrent.totalSize, fileEnds: layout.fileEnds, filePosition: filePosition,
      priorities: filePriorities, skipped: pausedFiles.union(removedFiles),
      verified: verifiedPieces)
    picker.setOrder(fetch.order)
    picker.setFiles(fetch.pieceFile)
  }

  // MARK: - File removal

  /// Remove (`true`) or restore (`false`) one file in a running or paused
  /// download. Removing a file deletes its on-disk data, cancels its in-flight
  /// requests, and excludes its pieces from the fetch order — it no longer
  /// counts toward completion. Restoring re-includes the pieces and re-downloads
  /// the file from scratch (its data was deleted while removed).
  public func setFileRemoved(_ removed: Bool, fileIndex: Int) async {
    guard fileIndex >= 0, fileIndex < layout.entries.count else { return }
    if removed {
      await removeFile(fileIndex)
    } else {
      await restoreFile(fileIndex)
    }
  }

  /// Remove a file: un-verify the pieces it owns (their data is about to be
  /// deleted), cancel their in-flight requests, exclude them from the order,
  /// and delete the file's bytes on disk.
  private func removeFile(_ fileIndex: Int) async {
    guard !removedFiles.contains(fileIndex) else { return }
    let ownedPieces = Set((0..<picker.pieceCount).filter { pieceFile[$0] == fileIndex })
    for piece in ownedPieces { unverify(piece) }
    removedFiles.insert(fileIndex)
    rebuildOrder()
    saveResumeState()
    // Cancel in-flight blocks for the removed file's pieces so peers don't keep
    // serving them (handlePiece also drops them if one still arrives).
    let peersSnapshot = peers
    for (key, connection) in peersSnapshot {
      let dropped = picker.dropPending(forPieces: ownedPieces, on: key)
      for block in dropped {
        let length = min(settings.blockSize, picker.pieceSize(of: block.piece) - block.begin)
        try? await connection.send(.cancel(index: block.piece, begin: block.begin, length: length))
      }
    }
    await disk.setRemovedFiles(removedFiles)
    await disk.deleteFileData(fileIndex)
    refreshStats()
    emit(.stats(stats))
  }

  /// Restore a removed file: its data was deleted while removed, so every piece
  /// touching it (owned or straddling a neighbor) must re-download its bytes.
  private func restoreFile(_ fileIndex: Int) async {
    guard removedFiles.contains(fileIndex) else { return }
    let touching = piecesTouchingFile(fileIndex)
    for piece in touching { unverify(piece) }
    removedFiles.remove(fileIndex)
    await disk.setRemovedFiles(removedFiles)
    rebuildOrder()
    saveResumeState()
    refreshStats()
    emit(.stats(stats))
  }

  /// Undo a verified piece (its file was removed/restored and its data is not
  /// trusted): drop it from the verified set + picker completion so it fetches
  /// again, and undo the byte accounting.
  private func unverify(_ piece: Int) {
    guard piece >= 0, piece < picker.pieceCount else { return }
    if verifiedPieces.remove(piece) != nil {
      stats.verifiedBytes -= Int64(picker.pieceSize(of: piece))
    }
    picker.unverify(piece)
    pieceBuffers[piece] = nil
    pieceAttempts[piece] = nil
  }

  /// The set of pieces whose byte range intersects `file` — the pieces that
  /// must re-download when a removed file is restored.
  private func piecesTouchingFile(_ file: Int) -> Set<Int> {
    Self.piecesTouchingFile(
      fileEnds: layout.fileEnds, pieceLength: torrent.pieceLength, totalSize: torrent.totalSize,
      file: file)
  }

  /// Pure form of `piecesTouchingFile` — testable without a live session.
  static func piecesTouchingFile(
    fileEnds: [Int64], pieceLength: Int, totalSize: Int64, file: Int
  ) -> Set<Int> {
    guard file >= 0, file < fileEnds.count else { return [] }
    let fileStart = file == 0 ? 0 : fileEnds[file - 1]
    let fileEnd = fileEnds[file]
    var pieces: Set<Int> = []
    // A piece that starts just before the file may extend into it, so begin
    // the scan one piece early.
    var piece = max(0, Int(fileStart / Int64(pieceLength)) - 1)
    let pieceCount = Int((totalSize + Int64(pieceLength) - 1) / Int64(pieceLength))
    while piece < pieceCount, Int64(piece) * Int64(pieceLength) < fileEnd {
      let pStart = Int64(piece) * Int64(pieceLength)
      let pEnd = min(pStart + Int64(pieceLength), totalSize)
      if pEnd > fileStart && pStart < fileEnd { pieces.insert(piece) }
      piece += 1
    }
    return pieces
  }

  /// The download is complete when every piece NOT owned by a removed file is
  /// verified. Paused files still count as required (they're just not being
  /// fetched right now), so pausing a file never "completes" the download —
  /// only removing one does.
  private var isDownloadComplete: Bool {
    for piece in 0..<picker.pieceCount where !removedFiles.contains(pieceFile[piece]) {
      if !verifiedPieces.contains(piece) { return false }
    }
    return true
  }

  /// Download progress excluding removed files: verified bytes in non-removed
  /// files over the total bytes of non-removed files, so a removed file does
  /// not drag the bar down (or push it above 1).
  private func effectiveProgress() -> Double {
    let fileVerified = stats.fileVerifiedBytes
    var verified: Int64 = 0
    var total: Int64 = 0
    for file in 0..<layout.entries.count where !removedFiles.contains(file) {
      verified += fileVerified.indices.contains(file) ? fileVerified[file] : 0
      total += layout.entries[file].length
    }
    return total > 0 ? Double(verified) / Double(total) : 1
  }

  /// Recompute the per-file and overall progress fields after the removed-file
  /// set changes (remove or restore), so an immediate `.stats` emit reflects
  /// the new state instead of the previous tick's stale numbers.
  private func refreshStats() {
    stats.fileVerifiedBytes = computeFileProgress()
    stats.fileSequentialBytes = computeSequentialFileProgress()
    stats.progress = effectiveProgress()
  }

  // MARK: - Trackers

  private var lastAnnounceInterval: Int?

  /// The port to advertise to trackers/DHT: the bound listener port when
  /// inbound is enabled (so peers can reach us), otherwise the configured
  /// `listenPort` (outbound-only still needs a non-zero value).
  private var advertisedPort: UInt16 {
    // The acceptor is an actor; reading its port needs an await, but this
    // is called from non-async contexts. Cache the bound port here.
    boundListenerPort ?? settings.listenPort
  }

  private var boundListenerPort: UInt16?

  private func announceParams(event: String?) -> TrackerAnnounceParams {
    TrackerAnnounceParams(
      infoHash: torrent.infoHash, peerID: ourPeerID, port: advertisedPort, uploaded: 0,
      downloaded: stats.verifiedBytes, left: max(0, torrent.totalSize - stats.verifiedBytes),
      event: event, numwant: 50)
  }

  /// Announce `started` across all tracker URLs (HTTP then UDP), returning
  /// the union of announced peers.
  private func announceStarted() async -> [TrackerPeer] {
    var peers: [TrackerPeer] = []
    var interval: Int?
    for url in announceURLs {
      let params = announceParams(event: "started")
      do {
        let response = try await HTTPTracker.announce(
          url: url, params: params, timeout: .seconds(15))
        Self.log.info(
          "announce OK from \(url.host ?? "", privacy: .public): \(response.peers.count, privacy: .public) peers, \(response.seeders ?? -1, privacy: .public) seeds, \(response.leechers ?? -1, privacy: .public) leechers"
        )
        peers.append(contentsOf: response.peers)
        if interval == nil { interval = response.interval }
        if response.seeders != nil || response.leechers != nil {
          trackerSeeders = response.seeders ?? 0
          trackerLeechers = response.leechers ?? 0
        }
      } catch {
        if let udp = try? await UDPTracker.announce(url: url, params: params, timeout: .seconds(15))
        {
          peers.append(contentsOf: udp.peers)
        }
      }
    }
    lastAnnounceInterval = interval
    return peers
  }

  private func trackerLoop(interval: Int) async {
    // Re-announce at most every 60s regardless of the tracker's suggested
    // interval (which can be 1800s = 30 min) — frequent announces sample
    // different peers from the swarm, and the tracker only returns a few
    // per response. This is how real clients accumulate a peer pool.
    let tick = max(1, min(interval, 60))
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(tick))
      if Task.isCancelled { return }
      guard state == .downloading else { continue }
      let params = announceParams(event: nil)
      var fresh: [TrackerPeer] = []
      for url in announceURLs {
        if let response = try? await HTTPTracker.announce(
          url: url, params: params, timeout: .seconds(15))
        {
          fresh.append(contentsOf: response.peers)
        } else if let response = try? await UDPTracker.announce(
          url: url, params: params, timeout: .seconds(15))
        {
          fresh.append(contentsOf: response.peers)
        }
      }
      announcedPeers = fresh
      Self.log.info("re-announce returned \(fresh.count, privacy: .public) peer(s)")
      spawnPeerTasks(for: fresh)
    }
  }

  private func fireAndForgetAnnounce(event: String?) {
    guard let url = announceURLs.first else { return }
    let params = announceParams(event: event)
    Task { try? await HTTPTracker.announce(url: url, params: params, timeout: .seconds(10)) }
  }

  /// Force an immediate re-announce (bypassing the tracker loop's interval).
  /// Useful for tests that need to inject new peers immediately.
  public func reannounce() async {
    let params = announceParams(event: nil)
    var fresh: [TrackerPeer] = []
    for url in announceURLs {
      if let response = try? await HTTPTracker.announce(
        url: url, params: params, timeout: .seconds(15))
      {
        fresh.append(contentsOf: response.peers)
      } else if let response = try? await UDPTracker.announce(
        url: url, params: params, timeout: .seconds(15))
      {
        fresh.append(contentsOf: response.peers)
      }
    }
    announcedPeers = fresh
    Self.log.info("reannounce returned \(fresh.count, privacy: .public) peer(s)")
    spawnPeerTasks(for: fresh)
  }

  // MARK: - Peers

  private func spawnPeerTasks(for announced: [TrackerPeer]) {
    // Only hand out peers while the download is actually running: a peer
    // spawned while paused/completed would just connect and sit idle. A
    // paused session re-spawns the pool on resume().
    guard state == .downloading else { return }
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
    let connection = PeerConnection(
      host: host, port: port, infoHash: torrent.infoHash, peerID: ourPeerID,
      encryptedOnly: settings.encryptedPeersOnly, connectTimeout: .seconds(15),
      readTimeout: .seconds(90))
    peers[key] = connection
    Self.log.info("connecting to \(host, privacy: .public):\(port)")
    do {
      try await connection.start()
      await peerLoop(connection: connection, key: key, label: "\(host):\(port)", established: true)
    } catch {
      // The loop's defer never ran — this peer never reached peerLoop,
      // so nothing has cleaned up after it yet. Report the failure.
      emit(.peer(.dropped("\(host):\(port) — \(error)")))
    }
    // Cleanup MUST happen on every exit path. It used to live only in
    // peerLoop's defer — a failed connect/handshake leaked the peer's
    // slots permanently, and once maxPeers distinct endpoints had failed
    // the session stopped spawning peers forever ("Downloading", 0 peers).
    peers[key] = nil
    peerTasks[key] = nil
  }

  /// An inbound connection that already completed the MSE responder
  /// handshake (via `PeerAcceptor`). Runs the same download loop.
  private func runInboundPeer(_ connection: PeerConnection) async {
    let key = PeerID(raw: Data(UUID().uuidString.utf8))
    peers[key] = connection
    let remoteID = await connection.remotePeerIDHex()
    Self.log.info("inbound peer connected: \(remoteID, privacy: .public)")
    await peerLoop(connection: connection, key: key, label: "inbound", established: true)
  }

  /// The shared per-peer wire loop: keep the pipeline full, read messages,
  /// and handle them. Runs until the task is cancelled or the download
  /// completes.
  private func peerLoop(connection: PeerConnection, key: PeerID, label: String, established: Bool)
    async
  {
    var choked = true
    var sentOurBitfield = false
    var loggedNoUpload = false
    // When each in-flight block was requested, so a peer that silently
    // withholds one block can be dropped (see blockStallTimeout).
    var requestAges: [PiecePicker.BlockKey: Date] = [:]

    defer {
      picker.disconnect(key)
      // A peer that reached the wire loop is re-eligible for the pool once
      // it goes away. Otherwise spawnedPeers grows forever and discovery
      // starves: the tracker/DHT feed a finite address set, and once every
      // address is "seen" nothing can reconnect after the active peers
      // churn out — the download stalls mid-file until an app restart.
      spawnedPeers.remove(key)
      peers[key] = nil
      peerTasks[key] = nil
      peerRates[key] = nil
      stats.peersConnected = max(0, stats.peersConnected - 1)
      Task { await connection.close() }
    }

    do {
      stats.peersConnected += 1
      stats.peersSeen += 1
      emit(.peer(.connected(label)))
      try await connection.send(.interested)
      // Advertise BEP 10 extensions (ut_pex) so peers can exchange peers.
      try await connection.send(.extended(id: 0, payload: PEX.handshake()))
      var peerPEXID: UInt8?
      // Adaptive per-peer pipeline: sized to ~2 s of the peer's measured
      // rate so a single fast peer can saturate the link (a fixed small
      // queue caps at in-flight/RTT), while slow peers don't pile up
      // requests. `min` keeps the pipe primed until the rate is known.
      var rateTracker = peerRates[key] ?? PeerRateTracker()
      peerRates[key] = rateTracker

      while !Task.isCancelled {
        // While paused we're not requesting, so drop request-age
        // bookkeeping; otherwise resume would see stale ages and drop the
        // peer before it can serve anything.
        if paused {
          requestAges.removeAll()
        } else {
          // Only blocks still in flight on this peer should age toward the
          // stall timeout. Once a block arrives (or is freed), its request
          // age is stale — a received block must NOT trip the drop check 60s
          // later, or every healthy peer is force-disconnected ~60s after its
          // first request and the swarm churns (reconnect → serve → drop),
          // starving the frontier piece. Prune ages for blocks no longer
          // pending before checking for a genuine stall.
          requestAges = requestAges.filter { picker.pending[key, default: []].contains($0.key) }
          if let stale = requestAges.first(where: {
            Date().timeIntervalSince($0.value) > Self.blockStallTimeout
          }) {
            // A requested block that hasn't arrived in a long time: the peer
            // may be alive but silently withholding it (the read idle timeout
            // never fires because the peer keeps sending other blocks). Drop
            // the peer so its whole pipeline is freed for re-request.
            Self.log.info(
              "\(label, privacy: .public) block \(stale.key.piece):\(stale.key.begin) stalled past \(Self.blockStallTimeout, privacy: .public)s — dropping peer"
            )
            break
          }
        }
        // Re-sync the rate tracker with what handlePiece recorded
        // (it lives on the actor; this loop's local copy goes stale).
        rateTracker = peerRates[key] ?? rateTracker
        peerRates[key] = rateTracker
        // Keep the pipeline full while unchoked (and not paused).
        if !paused, !choked {
          let depth = rateTracker.pipelineDepth(
            blockSize: settings.blockSize, min: settings.pipelinePerPeer,
            max: settings.maxPipelinePerPeer)
          while !paused,
            let block = picker.request(for: key, pipeline: depth)
          {
            requestAges[PiecePicker.BlockKey(piece: block.piece, begin: block.begin)] = Date()
            try await connection.send(
              .request(index: block.piece, begin: block.begin, length: block.length))
          }
        }
        if case .completed = state { break }

        // When this peer has nothing in flight and nothing left to
        // request (paused, or all remaining pieces belong to paused
        // files), don't block on receive forever — poll so resume/priority
        // changes are picked up. A momentarily-empty swarm (a peer with no
        // requestable piece) must NOT spin a 500ms timer forever: back off
        // to a multi-second idle poll. receiveMessageOrIdle returns as soon
        // as any message arrives, so a responsive peer is never delayed —
        // only a genuinely silent peer waits the full interval. A fast poll
        // is kept while paused so an unpause/priority change is noticed
        // promptly.
        let idle = picker.pending[key, default: []].isEmpty
        let message: WireMessage?
        if idle {
          let idleTimeout: Duration = paused ? Self.idlePollFast : Self.idlePollBackoff
          message = try await connection.receiveMessageOrIdle(timeout: idleTimeout)
        } else {
          message = try await connection.receiveMessage()
        }
        guard let message else { continue }  // idle poll timed out; re-check

        switch message {
        case .choke:
          choked = true
          Self.log.info("\(label, privacy: .public) choked (idle=\(idle, privacy: .public))")
        case .unchoke:
          choked = false
          Self.log.info("\(label, privacy: .public) unchoked")
        case .bitfield(let bits):
          let availability = piecesFromBitfield(bits)
          picker.setAvailable(availability, on: key)
          Self.log.info(
            "\(label, privacy: .public) bitfield: \(availability.count, privacy: .public)/\(self.picker.pieceCount, privacy: .public) pieces, covers-frontier=\(availability.contains(self.picker.cursor), privacy: .public)"
          )
          if !sentOurBitfield {
            try await connection.send(
              .bitfield(Data(repeating: 0, count: (picker.pieceCount + 7) / 8)))
            sentOurBitfield = true
          }
        case .have(let piece):
          var available = picker.peerHas[key] ?? []
          available.insert(piece)
          picker.setAvailable(available, on: key)
        case .piece(let index, let begin, let data):
          await handlePiece(index: index, begin: begin, data: data, key: key)
        case .extended(let id, let payload):
          if id == 0 {
            // Peer's extended handshake: read its ut_pex sub-id and
            // share our known peers back.
            if let utpex = PEX.parseHandshake(payload) {
              peerPEXID = utpex
              let added = announcedPeers.map { ($0.host, $0.port) }
              if !added.isEmpty {
                try await connection.send(
                  .extended(id: PEX.pexExtendedID, payload: PEX.pexBody(added: added)))
              }
            }
          } else if id == peerPEXID {
            // Peer exchange: discover new peers from the swarm.
            let discovered = PEX.parsePEX(payload).map { TrackerPeer(host: $0.0, port: $0.1) }
            spawnPeerTasks(for: discovered)
          }
        case .request, .cancel, .interested, .notInterested, .keepAlive:
          // No-upload enforcement: never respond to request/piece.
          if !loggedNoUpload, case .request = message { loggedNoUpload = true }
          _ = peerPEXID
        }
        if case .completed = state { break }
      }
    } catch let error as PeerConnectionError {
      if case .peerDoesNotSupportEncryption = error {
        emit(.peer(.dropped("\(label) — plaintext peer rejected")))
      } else if established {
        emit(.peer(.disconnected("\(label) — \(error)")))
      } else {
        emit(.peer(.dropped("\(label) — \(error)")))
      }
    } catch {
      // Any failure before the connection was established (including a
      // cancellation racing the connect) means the peer never became
      // usable — report it as dropped, not disconnected.
      if established {
        emit(.peer(.disconnected("\(label) — \(error)")))
      } else {
        emit(.peer(.dropped("\(label) — \(error)")))
      }
      Self.log.info(
        "\(label, privacy: .public) wire error: \(String(describing: error), privacy: .public)")
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
    // Feed the peer's rate tracker so its pipeline depth adapts to its
    // measured speed (deep queue for fast peers, shallow for slow).
    peerRates[key, default: PeerRateTracker()].record(bytes: Int64(data.count))
    receivedBytes += Int64(data.count)
    let pieceSize = picker.pieceSize(of: index)
    let expectedLength = min(settings.blockSize, pieceSize - begin)
    guard begin < pieceSize, data.count == expectedLength else {
      // Malformed/duplicate block: free the pipeline slot (complete does
      // that), but DO NOT leave it marked received. It was never stored in
      // pieceBuffers, so marking it received would make assembly bail on the
      // missing bytes forever while request() never re-requests it (it is
      // in the received set) — a permanent piece freeze, cured only by a
      // relaunch. Release the received mark so the block is re-requestable.
      let blockKey = PiecePicker.BlockKey(piece: index, begin: begin)
      picker.complete(blockKey, on: key)
      picker.releaseReceivedBlock(blockKey)
      return
    }

    let blockKey = PiecePicker.BlockKey(piece: index, begin: begin)
    // A piece owned entirely by a removed file is dropped — the file was
    // deleted, so never buffer/verify/write those bytes. (In-flight blocks may
    // still arrive after the file was removed; freeing the peer's slot is
    // enough. Pieces that straddle a removed file are owned by a kept file and
    // still assemble/verify — DiskWriter.write skips the removed file's span.)
    if removedFiles.contains(pieceFile[index]) {
      picker.complete(blockKey, on: key)
      return
    }
    // ENDGAME / redundant fetch: the same block may be requested from more
    // than one peer. Only the FIRST arrival is stored and hashed; any later
    // duplicate (already buffered for this piece+begin) is idempotent — free
    // this peer's pipeline slot (complete) but do NOT re-store or re-hash,
    // so the piece assembles, verifies, and writes exactly once (no double
    // disk write / pieceVerified emit). Duplicates only occur during the
    // endgame window, while the piece is still assembling.
    if pieceBuffers[index]?[begin] != nil {
      picker.complete(blockKey, on: key)
      return
    }
    pieceBuffers[index, default: [:]][begin] = data
    picker.complete(blockKey, on: key)

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
      // Clear the buffer AND the picker's received-block bookkeeping so
      // this piece is re-fetched from scratch.
      pieceBuffers[index] = nil
      picker.resetReceived(index)
      return
    }

    do { try await disk.write(piece: index, data: assembled) } catch {
      state = .failed("disk write failed for piece \(index): \(error)")
      emit(.state(state))
      continuation.finish()
      return
    }

    // Only AFTER the bytes are on disk does the piece count as verified:
    // recording it earlier would let a crash between the two leave a
    // resume state claiming a verified piece whose data was never written
    // (the stale-claim bug). Persist here so the snapshot never claims
    // un-written pieces.
    verifiedPieces.insert(index)
    picker.advancePast(index)
    stats.verifiedBytes += Int64(pieceSize)
    emit(.pieceVerified(index))

    // Persist resume state every 16 verified pieces (and on pause/cancel)
    // so an interrupted download can resume from here.
    if verifiedPieces.count % 16 == 0 { saveResumeState() }

    if isDownloadComplete { await finishDownload() }
  }

  // MARK: - Resume

  /// The torrent's data files already exist in the save directory — the
  /// precondition for trusting persisted resume state. Multi-file downloads
  /// don't preallocate, so a partial download's files are shorter than their
  /// full length; requiring at least one file to be present (rather than every
  /// file at its exact length) lets resume/re-verify work with partial files.
  /// Re-verification re-hashes every claimed piece on disk, so a piece whose
  /// bytes aren't actually present is dropped and re-fetched.
  private var resumeDataFilesPresent: Bool {
    layout.entries.contains { FileManager.default.fileExists(atPath: $0.url.path) }
  }

  /// Seed the verified-piece set and picker cursor from persisted resume
  /// state. Every piece the state claims as verified is RE-VERIFIED against
  /// the data on disk (SHA-1 vs the torrent's piece hashes) before being
  /// trusted; a stale or corrupt claim — e.g. a piece recorded as verified
  /// before its bytes were actually written, or a piece whose file region
  /// was overwritten/truncated since — is dropped and re-fetched. A state
  /// file is ignored entirely when it doesn't match this torrent (piece
  /// length or total size) or when the data files aren't present in the
  /// save directory. Best effort — a missing, corrupt, or unusable state
  /// simply means the download starts from scratch.
  private func applyResumeState(reverify: Bool = true) async {
    guard resumeDataFilesPresent else { return }
    guard let resume = ResumeState.load(infoHash: torrent.infoHash) else { return }
    guard resume.pieceLength == torrent.pieceLength, resume.totalSize == torrent.totalSize else {
      return
    }
    var adopted = 0
    for index in resume.verified.sorted() {
      guard index >= 0, index < picker.pieceCount, !verifiedPieces.contains(index) else { continue }
      if reverify {
        guard let hash = try? await disk.hash(piece: index), hash == torrent.pieceHashes[index]
        else {
          Self.log.info(
            "resume state claimed piece \(index, privacy: .public) verified but it does not hash — re-fetching"
          )
          continue
        }
      }
      verifiedPieces.insert(index)
      stats.verifiedBytes += Int64(picker.pieceSize(of: index))
      adopted += 1
    }
    if adopted != resume.verified.count {
      Self.log.info(
        "resume state: adopted \(adopted, privacy: .public) of \(resume.verified.count, privacy: .public) claimed verified pieces"
      )
    }
    // Restore the per-file policy (paused / removed / priorities) so a
    // relaunch keeps the file layout the user configured: a paused file stays
    // out of the fetch order, a removed file stays excluded and not counted
    // toward completion, and priorities reorder fetching. The removed-file
    // set is pushed to the disk before prepare() so a removed file is never
    // created/resurrected. These are the same fields the session mutates
    // during a run (setFilePaused/setFileRemoved/setFilePriorities), so a
    // live session and a restored one stay consistent.
    pausedFiles = Set(resume.pausedFiles)
    removedFiles = Set(resume.removedFiles)
    filePriorities = resume.priorities
    await disk.setRemovedFiles(removedFiles)
    // The order must exclude the resumed verified pieces — the frontier
    // becomes the first unverified piece in the (priority) order.
    rebuildOrder()
  }

  /// Persist the current verified-piece set (+ per-file pause/priority/remove
  /// policy) so a later session can resume without re-fetching and without
  /// losing which files the user paused/prioritized/removed. Best effort — a
  /// failed write never fails the download.
  private func saveResumeState() {
    // Persist whenever there is anything to resume: verified pieces, or a
    // non-empty per-file policy (a file paused/removed/prioritized before any
    // piece verified must survive a relaunch too).
    let hasPolicy = !pausedFiles.isEmpty || !removedFiles.isEmpty || !filePriorities.isEmpty
    guard !verifiedPieces.isEmpty || hasPolicy else { return }
    ResumeState(
      pieceLength: torrent.pieceLength, totalSize: torrent.totalSize,
      verified: verifiedPieces.sorted(),
      pausedFiles: pausedFiles.sorted(),
      priorities: filePriorities,
      removedFiles: removedFiles.sorted()
    ).save(infoHash: torrent.infoHash)
  }

  private func finishDownload() async {
    guard state != .completed else { return }
    state = .completed
    // Final stats so the UI shows 100%, full per-file progress (verified AND
    // sequential) and no speed immediately: the stats loop stops here, so
    // whatever this emits is what the finished download keeps showing.
    refreshStats()
    stats.progress = 1
    stats.downloadSpeed = 0
    emit(.stats(stats))
    emit(.state(.completed))
    fireAndForgetAnnounce(event: "completed")
    for (_, task) in peerTasks { task.cancel() }
    peerTasks.removeAll()
    trackerTask?.cancel()
    trackerTask = nil
    statsTask?.cancel()
    statsTask = nil
    dhtTask?.cancel()
    dhtTask = nil
    dht?.close()
    await acceptor?.stop()
    await disk.close()
    continuation.finish()
  }

  // MARK: - Stats

  private func startStatsLoop() { statsTask = Task { await self.statsLoop() } }

  private func statsLoop() async {
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(1))
      if Task.isCancelled { return }
      stats.downloadSpeed = speedMeter.record(totalBytes: receivedBytes)
      stats.fileVerifiedBytes = computeFileProgress()
      stats.fileSequentialBytes = computeSequentialFileProgress()
      stats.progress = effectiveProgress()
      // A connected peer is a seeder if its announced set is complete.
      stats.seedersConnected = picker.peerHas.values.filter { $0.count >= picker.pieceCount }.count
      stats.trackerSeeders = trackerSeeders
      stats.trackerLeechers = trackerLeechers
      emit(.stats(stats))

      // Diagnostics: surface a frontier stall ("Debian doesn't download in
      // a single run") as a readable line the user can hand back. A DIAG
      // heartbeat every 5s shows the frontier + whether any connected peer
      // has it; once progress stops for 30s+ the line is labelled
      // NO-PROGRESS with how long. Any piece verifies → timer resets.
      let verifiedCount = verifiedPieces.count
      if verifiedCount != diagProgressLastCount {
        diagProgressLastCount = verifiedCount
        diagStallSince = nil
        diagTicks = 0
      } else if state == .downloading {
        if diagStallSince == nil { diagStallSince = Date() }
        diagTicks += 1
        if diagTicks >= 5 {
          diagTicks = 0
          let stalledFor = diagStallSince.map { Int(-$0.timeIntervalSinceNow) } ?? 0
          logDiagnostics(
            reason: stalledFor >= 30
              ? "NO-PROGRESS \(stalledFor)s before this line" : nil)
        }
      }
    }
  }

  /// Emit one high-signal diagnostics line: the sequential frontier, whether
  /// any connected peer actually has it, the peer/seed counts, and speed.
  /// The frontier-has-peer flag is what tells discovery starvation (false)
  /// apart from a fetch/handshake problem (true but no progress).
  private func logDiagnostics(reason: String?) {
    let verifiedCount = verifiedPieces.count
    let total = picker.pieceCount
    let cursor = picker.cursor
    let cursorHasPeer = picker.peerHas.values.contains { $0.contains(cursor) }
    let connected = peers.count
    let seeders = picker.peerHas.values.filter { $0.count >= picker.pieceCount }.count
    let pct = total > 0 ? String(format: "%.1f", Double(verifiedCount) / Double(total) * 100) : "0"
    let speedKBs = Int(stats.downloadSpeed / 1024)
    if let reason {
      Self.log.info(
        "DIAG [\(reason, privacy: .public)] verified=\(verifiedCount, privacy: .public)/\(total, privacy: .public) (\(pct, privacy: .public)%) frontier=\(cursor, privacy: .public) peer-has-frontier=\(cursorHasPeer, privacy: .public) peers=\(connected, privacy: .public) seeders=\(seeders, privacy: .public) speedKBs=\((speedKBs), privacy: .public)"
      )
    } else {
      Self.log.info(
        "DIAG verified=\(verifiedCount, privacy: .public)/\(total, privacy: .public) (\(pct, privacy: .public)%) frontier=\(cursor, privacy: .public) peer-has-frontier=\(cursorHasPeer, privacy: .public) peers=\(connected, privacy: .public) seeders=\(seeders, privacy: .public) speedKBs=\((speedKBs), privacy: .public)"
      )
    }
  }

  /// Verified bytes per file, attributed exactly: a piece that straddles
  /// two files contributes its overlap to each.
  private func computeFileProgress() -> [Int64] {
    var perFile = [Int64](repeating: 0, count: layout.entries.count)
    for piece in verifiedPieces {
      let start = Int64(piece) * Int64(torrent.pieceLength)
      let end = min(start + Int64(torrent.pieceLength), torrent.totalSize)
      guard start < end else { continue }
      for span in layout.spans(forPieceRange: start..<end) {
        perFile[span.file] += Int64(span.length)
      }
    }
    return perFile
  }

  /// Contiguous verified prefix bytes per file — how much of each file is
  /// downloaded from its start, stopping at the first gap in THAT file.
  /// Because the picker fetches sequentially (in fetch order), this is the
  /// playable head: a media file can stream from byte 0 up to this point.
  /// Each file's head is computed independently (file priorities mean a
  /// later file's prefix can be complete while an earlier file has gaps).
  /// A piece counts only when fully verified — a straddling piece's bytes
  /// in this file count if the whole piece verified.
  private func computeSequentialFileProgress() -> [Int64] {
    Self.sequentialFileProgress(
      pieceCount: picker.pieceCount, pieceLength: Int64(torrent.pieceLength),
      totalSize: torrent.totalSize, fileEnds: layout.fileEnds, verified: verifiedPieces)
  }

  /// Pure form of `computeSequentialFileProgress` — testable without a
  /// session. For each file, walk pieces from the file's first byte and
  /// accumulate overlap bytes while the intersecting pieces are verified;
  /// stop at the first unverified piece.
  static func sequentialFileProgress(
    pieceCount: Int, pieceLength: Int64, totalSize: Int64, fileEnds: [Int64], verified: Set<Int>
  ) -> [Int64] {
    var head = [Int64](repeating: 0, count: fileEnds.count)
    guard !verified.isEmpty else { return head }
    for file in 0..<fileEnds.count {
      let fileStart = file == 0 ? 0 : fileEnds[file - 1]
      let fileEnd = fileEnds[file]
      var bytes: Int64 = 0
      var piece = Int(fileStart / pieceLength)
      while Int64(piece) * pieceLength < fileEnd {
        guard verified.contains(piece) else { break }
        let pStart = Int64(piece) * pieceLength
        let pEnd = min(pStart + pieceLength, totalSize)
        let overlapStart = max(pStart, fileStart)
        let overlapEnd = min(pEnd, fileEnd)
        if overlapStart < overlapEnd { bytes += overlapEnd - overlapStart }
        piece += 1
      }
      head[file] = bytes
    }
    return head
  }

  // MARK: - Helpers

  private func emit(_ event: TorrentEvent) { continuation.yield(event) }

  /// A 20-byte client peer id: `-GE0001-` + 12 random alphanumerics.
  private static func makePeerID() -> Data {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".utf8)
    var bytes = Array("-GE0001-".utf8)
    for _ in 0..<12 { bytes.append(alphabet[Int.random(in: 0..<alphabet.count)]) }
    return Data(bytes)
  }
}
