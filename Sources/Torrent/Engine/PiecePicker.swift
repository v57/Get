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
    // Soft sequential: scan from the cursor. A peer WITH the frontier piece
    // serves it first (it is the earliest piece in the scan); a peer that
    // lacks it fetches the next available piece rather than idling. The
    // strict gate that stalled every peer when the frontier was momentarily
    // unheld is gone — a gap in the strict order must never stop the swarm.
    var pos = cursorPos
    while pos < order.count {
      let piece = order[pos]
      if completed.contains(piece) { pos += 1; continue }
      if peerHas[peer]?.contains(piece) == true {
        let blocks = blockCount(of: piece)
        var inflight = Set<BlockKey>()
        for set in pending.values { inflight.formUnion(set.filter { $0.piece == piece }) }
        let alreadyReceived = received[piece] ?? []
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

  /// Number of blocks in `piece`.
  public func blockCount(of piece: Int) -> Int {
    (pieceSize(of: piece) + blockSize - 1) / blockSize
  }

  /// Byte length of `piece` (the last piece may be shorter).
  public func pieceSize(of piece: Int) -> Int {
    piece == pieceCount - 1 ? lastPieceLength : pieceLength
  }
}
