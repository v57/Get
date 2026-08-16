import Foundation
import Testing
@testable import Torrent

// MARK: - Helpers

private let peerA = PeerID(raw: Data([1]))
private let peerB = PeerID(raw: Data([2]))

private func makePicker(pieceCount: Int = 10, pieceLength: Int = 16 * 1024) -> PiecePicker {
    PiecePicker(pieceCount: pieceCount, pieceLength: pieceLength, lastPieceLength: pieceLength)
}

// MARK: - Strict sequential ordering

@Test func strictSequentialOrderAcrossTwoPeers() {
    var picker = makePicker(pieceLength: 16 * 1024 * 4)   // 10 pieces, 4 blocks each
    picker.setAllAvailable(on: peerA)
    picker.setAllAvailable(on: peerB)

    // Pipeline large enough to drain the whole torrent (pipeline limiting is
    // exercised separately); blocks alternate between the peers but pieces
    // must come out in strictly ascending order.
    var assigned: [Int] = []
    var gave = true
    while gave {
        gave = false
        for peer in [peerA, peerB] {
            if let block = picker.request(for: peer, pipeline: 40) {
                assigned.append(block.piece)
                gave = true
            }
        }
    }

    // Pieces are handed out in strictly ascending order, no skips, no repeats
    // beyond block granularity: 0,0,0,0,1,1,1,1,… ,9,9,9,9.
    #expect(assigned == (0..<10).flatMap { piece in Array(repeating: piece, count: 4) })
    #expect(picker.cursor == 0)
}

@Test func stallsWhenCursorPieceAvailableOnNoPeer() {
    var picker = makePicker()
    picker.advancePast(2)                       // cursor == 3
    picker.setAvailable(Set(4..<10), on: peerA) // nobody has piece 3
    picker.setAvailable(Set(5..<10), on: peerB)

    // Strict sequential: no peer may skip ahead of an unavailable cursor piece.
    #expect(picker.request(for: peerA, pipeline: 4) == nil)
    #expect(picker.request(for: peerB, pipeline: 4) == nil)
    #expect(picker.cursor == 3)

    // Once a peer announces piece 3, requests resume exactly at the cursor.
    picker.setAvailable([3], on: peerA)
    #expect(picker.request(for: peerA, pipeline: 4) == PiecePicker.Block(piece: 3, begin: 0, length: 16 * 1024))
}

// MARK: - Pipeline limiting

@Test func pipelineLimitPerPeer() {
    var picker = makePicker(pieceCount: 2, pieceLength: 16 * 1024 * 4)
    picker.setAllAvailable(on: peerA)

    #expect(picker.request(for: peerA, pipeline: 0) == nil)

    let first = picker.request(for: peerA, pipeline: 2)
    let second = picker.request(for: peerA, pipeline: 2)
    #expect(first != nil)
    #expect(second != nil)
    #expect(picker.pending[peerA, default: []].count == 2)

    // At the pipeline limit: no more blocks, even though the piece has more.
    #expect(picker.request(for: peerA, pipeline: 2) == nil)
    #expect(picker.pending[peerA, default: []].count == 2)

    // Completing a block frees a pipeline slot.
    picker.complete(PiecePicker.BlockKey(piece: first!.piece, begin: first!.begin), on: peerA)
    #expect(picker.pending[peerA, default: []].count == 1)
    #expect(picker.request(for: peerA, pipeline: 2) != nil)
    #expect(picker.pending[peerA, default: []].count == 2)
}

// MARK: - Block sizing

@Test func lastBlockOfPieceIsShorter() {
    var picker = PiecePicker(pieceCount: 2, pieceLength: 40_000, lastPieceLength: 20_000)
    picker.setAllAvailable(on: peerA)

    // Piece 0 is 40_000 bytes: 16384 + 16384 + 7232.
    #expect(picker.pieceSize(of: 0) == 40_000)
    #expect(picker.blockCount(of: 0) == 3)
    #expect(picker.request(for: peerA, pipeline: 16) == PiecePicker.Block(piece: 0, begin: 0, length: 16_384))
    #expect(picker.request(for: peerA, pipeline: 16) == PiecePicker.Block(piece: 0, begin: 16_384, length: 16_384))
    #expect(picker.request(for: peerA, pipeline: 16) == PiecePicker.Block(piece: 0, begin: 32_768, length: 7_232))

    // Piece 1 (the last piece) is 20_000 bytes: 16384 + 3616.
    #expect(picker.pieceSize(of: 1) == 20_000)
    #expect(picker.blockCount(of: 1) == 2)
    #expect(picker.request(for: peerA, pipeline: 16) == PiecePicker.Block(piece: 1, begin: 0, length: 16_384))
    #expect(picker.request(for: peerA, pipeline: 16) == PiecePicker.Block(piece: 1, begin: 16_384, length: 3_616))
}

// MARK: - No double assignment

@Test func noDoubleAssignmentAcrossPeers() {
    var picker = makePicker(pieceCount: 2, pieceLength: 16 * 1024 * 2)
    picker.setAllAvailable(on: peerA)
    picker.setAllAvailable(on: peerB)

    // A block in flight on A is never handed to B.
    #expect(picker.request(for: peerA, pipeline: 4) == PiecePicker.Block(piece: 0, begin: 0, length: 16 * 1024))
    #expect(picker.request(for: peerB, pipeline: 4) == PiecePicker.Block(piece: 0, begin: 16 * 1024, length: 16 * 1024))
    #expect(picker.request(for: peerA, pipeline: 4) == PiecePicker.Block(piece: 1, begin: 0, length: 16 * 1024))
    #expect(picker.request(for: peerB, pipeline: 4) == PiecePicker.Block(piece: 1, begin: 16 * 1024, length: 16 * 1024))
}

// MARK: - Disconnect

@Test func disconnectFreesPendingBlocks() {
    var picker = makePicker(pieceCount: 2)
    picker.setAllAvailable(on: peerA)
    picker.setAllAvailable(on: peerB)

    #expect(picker.request(for: peerA, pipeline: 4) == PiecePicker.Block(piece: 0, begin: 0, length: 16 * 1024))
    picker.disconnect(peerA)
    #expect(picker.pending[peerA] == nil)

    // A's in-flight block is assignable again.
    #expect(picker.request(for: peerB, pipeline: 4) == PiecePicker.Block(piece: 0, begin: 0, length: 16 * 1024))
}

// MARK: - Cursor advancement

@Test func advancePastMovesCursor() {
    var picker = makePicker()
    #expect(picker.cursor == 0)
    picker.advancePast(2)
    #expect(picker.cursor == 3)

    picker.setAllAvailable(on: peerA)
    // The next request resumes at the new cursor, not at 0.
    #expect(picker.request(for: peerA, pipeline: 4) == PiecePicker.Block(piece: 3, begin: 0, length: 16 * 1024))
}

// MARK: - Availability

@Test func setAllAvailableMakesEveryPieceRequestable() {
    var picker = makePicker(pieceCount: 3)
    picker.setAllAvailable(on: peerA)
    #expect(picker.peerHas[peerA] == Set(0..<3))

    var seen: [Int] = []
    while let block = picker.request(for: peerA, pipeline: 16) {
        seen.append(block.piece)
        picker.complete(PiecePicker.BlockKey(piece: block.piece, begin: block.begin), on: peerA)
        picker.advancePast(block.piece)
    }
    #expect(seen == [0, 1, 2])
    #expect(picker.cursor == 3)
}

@Test func emptyAvailabilityBlocksPeer() {
    var picker = makePicker(pieceCount: 2)
    picker.setAllAvailable(on: peerA)
    picker.setAllAvailable(on: peerB)

    // Replacing B's availability with the empty set blocks B from everything.
    picker.setAvailable([], on: peerB)
    #expect(picker.peerHas[peerB] == [])
    #expect(picker.request(for: peerB, pipeline: 4) == nil)
    #expect(picker.request(for: peerA, pipeline: 4) == PiecePicker.Block(piece: 0, begin: 0, length: 16 * 1024))
}
