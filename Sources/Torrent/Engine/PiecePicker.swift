import Foundation

/// Identity of a connected peer (host:port bytes). Used as the key for
/// per-peer availability and in-flight block tracking.
public struct PeerID: Sendable, Equatable, Hashable {
    public let raw: Data
    public init(raw: Data) { self.raw = raw }
}

/// Strictly sequential piece picker.
///
/// Blocks are handed out in ascending piece order starting at `cursor`, each
/// peer is limited to `pipeline` outstanding blocks, and a block is never
/// assigned to two peers at once (blocks in flight anywhere are excluded).
/// If the cursor piece is available on no peer at all, no peer may skip ahead
/// of it — `request` returns nil for everyone until availability appears.
public struct PiecePicker: Sendable {
    public let pieceCount: Int
    public let pieceLength: Int
    public let lastPieceLength: Int
    public var blockSize: Int = 16 * 1024

    /// Lowest unverified piece (never decreases).
    public var cursor = 0

    /// Pieces each peer has announced via bitfield/have messages.
    public private(set) var peerHas: [PeerID: Set<Int>] = [:]

    /// Blocks currently in flight, per peer.
    public private(set) var pending: [PeerID: Set<BlockKey>] = [:]

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
    }

    /// Replace the peer's announced availability with `pieces`.
    public mutating func setAvailable(_ pieces: Set<Int>, on peer: PeerID) {
        peerHas[peer] = pieces
    }

    /// The peer's bitfield was all-ones (or it is a full-buffer peer): it has every piece.
    public mutating func setAllAvailable(on peer: PeerID) {
        peerHas[peer] = Set(0..<pieceCount)
    }

    /// Assign the earliest block this peer can fetch: the earliest piece >= cursor
    /// that the peer has, choosing its earliest block that is not in flight
    /// anywhere. Respects the per-peer pipeline limit.
    ///
    /// Returns nil when the peer is at its pipeline limit, has nothing to fetch,
    /// or the cursor piece is available on no peer at all (strict sequential:
    /// nobody skips ahead of an unavailable piece).
    public mutating func request(for peer: PeerID, pipeline: Int) -> Block? {
        guard pending[peer, default: []].count < pipeline else { return nil }
        // Strict sequential semantics: if the cursor piece exists on no peer,
        // no peer may skip past it.
        guard peerHas.values.contains(where: { $0.contains(cursor) }) else { return nil }
        var piece = cursor
        while piece < pieceCount {
            if peerHas[peer]?.contains(piece) == true {
                let blocks = blockCount(of: piece)
                var inflight = Set<BlockKey>()
                for set in pending.values {
                    inflight.formUnion(set.filter { $0.piece == piece })
                }
                for b in 0..<blocks {
                    let key = BlockKey(piece: piece, begin: b * blockSize)
                    if !inflight.contains(key) {
                        pending[peer, default: []].insert(key)
                        return Block(piece: piece, begin: key.begin,
                                     length: min(blockSize, pieceSize(of: piece) - key.begin))
                    }
                }
            }
            piece += 1
        }
        return nil
    }

    /// A block was received from `peer`: release its pipeline slot.
    public mutating func complete(_ key: BlockKey, on peer: PeerID) {
        pending[peer]?.remove(key)
    }

    /// A peer went away: free its in-flight blocks so others can fetch them,
    /// and drop its (now stale) availability.
    public mutating func disconnect(_ peer: PeerID) {
        pending[peer] = nil
        peerHas[peer] = nil
    }

    /// A piece was verified: the cursor moves past it (never backwards).
    public mutating func advancePast(_ piece: Int) {
        cursor = max(cursor, piece + 1)
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
