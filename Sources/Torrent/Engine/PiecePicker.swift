import Foundation

/// Identity of a connected peer (host:port bytes). Used as the key for
/// per-peer availability and in-flight block tracking.
public struct PeerID: Sendable, Equatable, Hashable {
  public let raw: Data
  public init(raw: Data) { self.raw = raw }
}

/// Soft-sequential piece picker.
///
/// Blocks are handed out in fetch order (by default ascending piece order
/// starting at the cursor), each peer is limited to `pipeline` outstanding
/// blocks, and a block is never assigned to two peers at once (blocks in
/// flight anywhere are excluded). A peer is assigned its earliest available
/// piece at or after the cursor: when the cursor piece is held by some peer,
/// that peer serves it first (it is the earliest in the scan), but a peer
/// that lacks it may fetch a later piece rather than idling. `setOrder`
/// replaces the fetch sequence (e.g. a file-priority ordering); pieces not
/// in the order are never requested.
public struct PiecePicker: Sendable {
  public let pieceCount: Int
  public let pieceLength: Int
  public let lastPieceLength: Int
  public var blockSize: Int = 16 * 1024

  /// Number of still-missing blocks at which a piece enters endgame mode
  /// (redundant last-block fetching). Matches the ~6-block threshold used by
  /// libtorrent / Transmission. See `isEndgame(_:)`.
  public var endgameThreshold: Int = 6

  /// Fetch order: the piece sequence handed out by `request`, front to
  /// back. Defaults to ascending `0..<pieceCount`; `setOrder` replaces it
  /// with any deduplicated subset of valid piece indices (typically a
  /// file-priority ordering that omits already-verified pieces).
  public private(set) var order: [Int]

  /// Position in `order` of the lowest unverified piece (never decreases).
  public private(set) var cursorPos = 0

  /// The frontier piece: `order[cursorPos]`, or `pieceCount` when every
  /// piece in the fetch order is verified.
  public var cursor: Int { cursorPos < order.count ? order[cursorPos] : pieceCount }

  /// Pieces each peer has announced via bitfield/have messages.
  public private(set) var peerHas: [PeerID: Set<Int>] = [:]

  /// Blocks currently in flight, per peer.
  public private(set) var pending: [PeerID: Set<BlockKey>] = [:]

  /// Blocks already received (buffered awaiting piece verification), keyed
  /// by piece. The picker must NOT re-request these: a block that completed
  /// is freed from `pending`, and scanning from block 0 would otherwise
  /// re-request it forever instead of advancing to the next missing block.
  /// Cleared when the piece verifies (cursor advances) or fails (re-fetch).
  public private(set) var received: [Int: Set<BlockKey>] = [:]

  /// Pieces that have fully verified (SHA-1 matched and written). The picker
  /// must skip these when scanning — a piece can verify out of fetch order
  /// when a peer lacks the frontier but has later pieces. The frontier is
  /// always the lowest non-completed piece in fetch order, so it is always
  /// the real next-needed piece, never past a gap.
  public private(set) var completed: Set<Int> = []

  /// Piece → file index, set by the session from the file layout. When empty
  /// (unset, or single-file torrents set it to a single-file mapping) every
  /// piece is treated as belonging to file 0, so the picker imposes no
  /// cross-file restriction and behaves exactly as before. When set for a
  /// multi-file torrent, `request` prefers the frontier's file so a download
  /// finishes the current file before fetching a later file's pieces — the
  /// reason a paused file's successor downloads sequentially from its start.
  public private(set) var pieceFile: [Int] = []

  public struct BlockKey: Hashable, Sendable {
    public let piece: Int
    public let begin: Int
    public init(piece: Int, begin: Int) {
      self.piece = piece
      self.begin = begin
    }
  }

  public struct Block: Equatable, Sendable {
    public let piece: Int
    public let begin: Int
    public let length: Int
    public init(piece: Int, begin: Int, length: Int) {
      self.piece = piece
      self.begin = begin
      self.length = length
    }
  }

  public init(pieceCount: Int, pieceLength: Int, lastPieceLength: Int, blockSize: Int = 16 * 1024) {
    self.pieceCount = pieceCount
    self.pieceLength = pieceLength
    self.lastPieceLength = lastPieceLength
    self.blockSize = blockSize
    self.order = Array(0..<pieceCount)
  }

  /// Replace the fetch sequence with `newOrder` — distinct valid piece
  /// indices in the order they should be requested (verified pieces should
  /// be omitted). The frontier resets to the first piece of the new order.
  /// An invalid order (out-of-range or duplicated indices) is ignored.
  public mutating func setOrder(_ newOrder: [Int]) {
    guard newOrder.allSatisfy({ $0 >= 0 && $0 < pieceCount }), Set(newOrder).count == newOrder.count
    else { return }
    order = newOrder
    cursorPos = 0
    completed = []
  }

  /// Record the piece → file mapping so `request` can prefer the frontier's
  /// file and keep a download file-sequential. A no-op when `pieceFile` is
  /// empty (the single-file / unset case, where no cross-file restriction
  /// applies).
  public mutating func setFiles(_ pieceFile: [Int]) { self.pieceFile = pieceFile }

  /// Replace the peer's announced availability with `pieces`.
  public mutating func setAvailable(_ pieces: Set<Int>, on peer: PeerID) { peerHas[peer] = pieces }

  /// The peer's bitfield was all-ones (or it is a full-buffer peer): it has every piece.
  public mutating func setAllAvailable(on peer: PeerID) { peerHas[peer] = Set(0..<pieceCount) }

  /// Assign the earliest block this peer can fetch: the earliest piece in
  /// fetch order (>= the cursor) that the peer has, choosing its earliest
  /// block that is not in flight anywhere. Respects the per-peer pipeline
  /// limit.
  ///
  /// Returns nil when the peer is at its pipeline limit or has nothing
  /// requestable at or after the cursor. The scan never skips a completed
  /// piece, and the earliest piece the peer has (>= cursor) is served first
  /// — soft sequential, so a momentarily-unheld frontier does not stall the
  /// whole swarm.
  public mutating func request(for peer: PeerID, pipeline: Int) -> Block? {
    guard pending[peer, default: []].count < pipeline else { return nil }
    guard cursorPos < order.count else { return nil }
    // Prefer the frontier's file: a download should finish the current file
    // before it fetches a later file's pieces, so each file downloads
    // sequentially from its start. Otherwise a peer that has the next file
    // but lacks the frontier's remaining pieces grabs that next file's pieces
    // ahead of time, scattering it — so when the user pauses the current file
    // and moves on, the next file is a patchwork rather than a run. File
    // awareness is off when `pieceFile` is empty (single-file/unset).
    if let frontierFile = frontierFileIndex, let block = earliestBlock(for: peer, inFile: frontierFile)
    {
      return block
    }
    // Soft-sequential fallback: the peer has nothing requestable in the
    // frontier's file (its remaining pieces are held by other peers, or the
    // frontier is momentarily unheld). Fetch the earliest available piece
    // anywhere at/after the cursor so a gap never stalls the swarm at 0 KB/s
    // (the strict gate that started this — reintroducing it is not an option).
    return earliestBlock(for: peer, inFile: nil)
  }

  /// The piece → file index of the frontier (or nil when the picker is not
  /// file-aware, i.e. `pieceFile` is empty).
  private var frontierFileIndex: Int? {
    guard !pieceFile.isEmpty, cursorPos < order.count else { return nil }
    let piece = order[cursorPos]
    return piece < pieceFile.count ? pieceFile[piece] : nil
  }

  /// Scan from the cursor for the earliest block this peer can fetch. When
  /// `file` is non-nil only pieces belonging to that file are considered
  /// (used to keep a download within the frontier's file); when nil every
  /// piece at/after the cursor qualifies. Respects the per-peer pipeline
  /// limit already checked by `request(for:pipeline:)`.
  private mutating func earliestBlock(for peer: PeerID, inFile file: Int?) -> Block? {
    var pos = cursorPos
    while pos < order.count {
      let piece = order[pos]
      if completed.contains(piece) { pos += 1; continue }
      if let file, piece < pieceFile.count, pieceFile[piece] != file { pos += 1; continue }
      if peerHas[peer]?.contains(piece) == true {
        let blocks = blockCount(of: piece)
        let alreadyReceived = received[piece] ?? []
        if isEndgame(piece) {
          // ENDGAME: the piece is nearly complete — request its remaining
          // blocks from this peer even when another peer already has them in
          // flight, so a slow or dropped peer cannot strand the last few
          // blocks. Only blocks already received, or already in flight on
          // THIS peer, are excluded; blocks in flight on other peers are
          // deliberately duplicated (redundancy is the point).
          let ownPending = pending[peer] ?? []
          for b in 0..<blocks {
            let key = BlockKey(piece: piece, begin: b * blockSize)
            if !alreadyReceived.contains(key), !ownPending.contains(key) {
              pending[peer, default: []].insert(key)
              return Block(
                piece: piece, begin: key.begin,
                length: min(blockSize, pieceSize(of: piece) - key.begin))
            }
          }
        } else {
          // NORMAL: a block is never assigned to two peers at once — exclude
          // any block in flight anywhere and any block already received.
          var inflight = Set<BlockKey>()
          for set in pending.values { inflight.formUnion(set.filter { $0.piece == piece }) }
          for b in 0..<blocks {
            let key = BlockKey(piece: piece, begin: b * blockSize)
            if !inflight.contains(key), !alreadyReceived.contains(key) {
              pending[peer, default: []].insert(key)
              return Block(
                piece: piece, begin: key.begin,
                length: min(blockSize, pieceSize(of: piece) - key.begin))
            }
          }
        }
      }
      pos += 1
    }
    return nil
  }

  /// A block was received from `peer`: release its pipeline slot and mark
  /// the block as received so it is not re-requested while the piece is
  /// still being assembled. When the piece verifies, `advancePast` clears
  /// the received set; on a hash mismatch the caller must call
  /// `resetReceived(piece:)` so the piece is fetched again from scratch.
  public mutating func complete(_ key: BlockKey, on peer: PeerID) {
    pending[peer]?.remove(key)
    received[key.piece, default: []].insert(key)
  }

  /// Drop the received-block bookkeeping for a piece (hash mismatch, peer
  /// disconnect) so its blocks are re-requestable.
  public mutating func resetReceived(_ piece: Int) { received[piece] = nil }

  /// Drop the received mark for ONE block so it becomes re-requestable.
  ///
  /// `complete(_:on:)` is the only way to free a pipeline slot, but it also
  /// marks the block "received". A malformed block (wrong length, never
  /// stored into the piece buffer) must free its slot WITHOUT being treated
  /// as received — otherwise assembly bails on the missing bytes forever
  /// while `request` never re-requests the block (it is in the received
  /// set), permanently freezing the piece until a relaunch clears memory.
  /// Call `complete` to free the slot, then `releaseReceivedBlock` to undo
  /// the received mark.
  public mutating func releaseReceivedBlock(_ key: BlockKey) {
    received[key.piece]?.remove(key)
    if received[key.piece]?.isEmpty == true { received[key.piece] = nil }
  }

  /// A peer went away: free its in-flight blocks so others can fetch them,
  /// and drop its (now stale) availability.
  public mutating func disconnect(_ peer: PeerID) {
    pending[peer] = nil
    peerHas[peer] = nil
  }

  /// Remove all in-flight pending blocks for a peer (e.g. on pause) so the
  /// download stops fetching them; on resume they can be re-requested.
  /// Received (buffered) blocks are kept so already-downloaded data is not
  /// re-fetched.
  public mutating func clearPending(on peer: PeerID) {
    pending[peer] = nil
  }

  /// Drop the in-flight blocks belonging to `pieces` on `peer`, keeping every
  /// other block. Used when a file is removed so its in-flight blocks are
  /// cancelled (and can be re-requested if the file is restored). Returns the
  /// dropped blocks so the caller can send `.cancel` for each.
  public mutating func dropPending(forPieces pieces: Set<Int>, on peer: PeerID) -> [BlockKey] {
    guard var set = pending[peer] else { return [] }
    let dropped = set.filter { pieces.contains($0.piece) }
    set.subtract(dropped)
    pending[peer] = set.isEmpty ? nil : set
    return Array(dropped)
  }

  /// A piece was verified: the cursor moves past it in fetch order (never
  /// backwards), and its received-block bookkeeping is dropped (the piece
  /// is done). Pieces not in the fetch order are ignored.
  public mutating func advancePast(_ piece: Int) {
    completed.insert(piece)
    received[piece] = nil
    // The frontier is the lowest non-completed piece in fetch order. NEVER
    // jump past an unverified one: a piece that verified ahead of the cursor
    // is a skip-over, and must not strand the pieces still in front of it
    // (that deadlocks the strict gate once the fetch order exhausts).
    while cursorPos < order.count, completed.contains(order[cursorPos]) {
      cursorPos += 1
    }
  }

  /// Undo a verified piece: drop it from the completed set and its received
  /// bookkeeping, and rewind the frontier to the lowest non-completed piece
  /// in fetch order so it is fetched again.
  ///
  /// Used when a piece's file is removed (its data is deleted) or restored, so
  /// the piece is re-downloaded rather than trusted from a now-absent file.
  public mutating func unverify(_ piece: Int) {
    completed.remove(piece)
    received[piece] = nil
    // The frontier is the lowest non-completed piece in fetch order — un-
    // completing a piece below the cursor rewinds it so that piece is fetched.
    if let first = order.firstIndex(where: { !completed.contains($0) }) {
      cursorPos = first
    } else {
      cursorPos = order.count
    }
  }

  /// Number of blocks in `piece`.
  public func blockCount(of piece: Int) -> Int {
    (pieceSize(of: piece) + blockSize - 1) / blockSize
  }

  /// Number of still-missing blocks in `piece` (blocks not yet received).
  public func missingBlockCount(of piece: Int) -> Int {
    blockCount(of: piece) - (received[piece]?.count ?? 0)
  }

  /// A piece is in endgame when it is genuinely near complete: it has more
  /// blocks than `endgameThreshold` in total AND only `endgameThreshold` or
  /// fewer blocks still missing.
  ///
  /// The `blockCount > endgameThreshold` guard keeps a piece too small to
  /// benefit from redundancy (e.g. a 2-block piece, or the tiny fixtures in
  /// the unit tests) in the normal one-peer-per-block path — a piece with
  /// nothing, or almost nothing, received is not "near complete", it is just
  /// starting. Endgame state is DERIVED from `received`, so `resetReceived`
  /// clears it naturally: a hash-mismatched piece re-fetches from scratch
  /// instead of staying in endgame.
  public func isEndgame(_ piece: Int) -> Bool {
    blockCount(of: piece) > endgameThreshold && missingBlockCount(of: piece) <= endgameThreshold
  }

  /// Byte length of `piece` (the last piece may be shorter).
  public func pieceSize(of piece: Int) -> Int {
    piece == pieceCount - 1 ? lastPieceLength : pieceLength
  }
}
