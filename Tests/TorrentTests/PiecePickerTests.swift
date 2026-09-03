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
  var picker = makePicker(pieceLength: 16 * 1024 * 4)  // 10 pieces, 4 blocks each
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
  picker.advancePast(2)  // cursor == 3
  picker.setAvailable(Set(4..<10), on: peerA)  // nobody has piece 3
  picker.setAvailable(Set(5..<10), on: peerB)

  // Strict sequential: no peer may skip ahead of an unavailable cursor piece.
  #expect(picker.request(for: peerA, pipeline: 4) == nil)
  #expect(picker.request(for: peerB, pipeline: 4) == nil)
  #expect(picker.cursor == 3)

  // Once a peer announces piece 3, requests resume exactly at the cursor.
  picker.setAvailable([3], on: peerA)
  #expect(
    picker.request(for: peerA, pipeline: 4)
      == PiecePicker.Block(piece: 3, begin: 0, length: 16 * 1024))
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
  #expect(
    picker.request(for: peerA, pipeline: 16)
      == PiecePicker.Block(piece: 0, begin: 0, length: 16_384))
  #expect(
    picker.request(for: peerA, pipeline: 16)
      == PiecePicker.Block(piece: 0, begin: 16_384, length: 16_384))
  #expect(
    picker.request(for: peerA, pipeline: 16)
      == PiecePicker.Block(piece: 0, begin: 32_768, length: 7_232))

  // Piece 1 (the last piece) is 20_000 bytes: 16384 + 3616.
  #expect(picker.pieceSize(of: 1) == 20_000)
  #expect(picker.blockCount(of: 1) == 2)
  #expect(
    picker.request(for: peerA, pipeline: 16)
      == PiecePicker.Block(piece: 1, begin: 0, length: 16_384))
  #expect(
    picker.request(for: peerA, pipeline: 16)
      == PiecePicker.Block(piece: 1, begin: 16_384, length: 3_616))
}

// MARK: - No double assignment

@Test func noDoubleAssignmentAcrossPeers() {
  var picker = makePicker(pieceCount: 2, pieceLength: 16 * 1024 * 2)
  picker.setAllAvailable(on: peerA)
  picker.setAllAvailable(on: peerB)

  // A block in flight on A is never handed to B.
  #expect(
    picker.request(for: peerA, pipeline: 4)
      == PiecePicker.Block(piece: 0, begin: 0, length: 16 * 1024))
  #expect(
    picker.request(for: peerB, pipeline: 4)
      == PiecePicker.Block(piece: 0, begin: 16 * 1024, length: 16 * 1024))
  #expect(
    picker.request(for: peerA, pipeline: 4)
      == PiecePicker.Block(piece: 1, begin: 0, length: 16 * 1024))
  #expect(
    picker.request(for: peerB, pipeline: 4)
      == PiecePicker.Block(piece: 1, begin: 16 * 1024, length: 16 * 1024))
}

// MARK: - Disconnect

@Test func disconnectFreesPendingBlocks() {
  var picker = makePicker(pieceCount: 2)
  picker.setAllAvailable(on: peerA)
  picker.setAllAvailable(on: peerB)

  #expect(
    picker.request(for: peerA, pipeline: 4)
      == PiecePicker.Block(piece: 0, begin: 0, length: 16 * 1024))
  picker.disconnect(peerA)
  #expect(picker.pending[peerA] == nil)

  // A's in-flight block is assignable again.
  #expect(
    picker.request(for: peerB, pipeline: 4)
      == PiecePicker.Block(piece: 0, begin: 0, length: 16 * 1024))
}

// MARK: - Cursor advancement

@Test func advancePastMovesCursor() {
  var picker = makePicker()
  #expect(picker.cursor == 0)
  picker.advancePast(2)
  #expect(picker.cursor == 3)

  picker.setAllAvailable(on: peerA)
  // The next request resumes at the new cursor, not at 0.
  #expect(
    picker.request(for: peerA, pipeline: 4)
      == PiecePicker.Block(piece: 3, begin: 0, length: 16 * 1024))
}

// MARK: - Fetch order (priorities)

@Test func setOrderControlsFetchSequence() {
  var picker = makePicker(pieceCount: 8)
  picker.setOrder([5, 6, 7, 0, 1, 2, 3, 4])
  picker.setAllAvailable(on: peerA)

  // Pieces come out in the given order, not ascending.
  var assigned: [Int] = []
  while let block = picker.request(for: peerA, pipeline: 32) { assigned.append(block.piece) }
  #expect(assigned == [5, 6, 7, 0, 1, 2, 3, 4])
  #expect(picker.cursor == 5, "frontier is the first piece of the order")
}

@Test func setOrderOmitsPiecesFromFetch() {
  var picker = makePicker(pieceCount: 6)
  // Pieces 0 and 1 are already verified — exclude them from the order.
  picker.setOrder([2, 3, 4, 5])
  picker.setAllAvailable(on: peerA)

  var assigned: [Int] = []
  while let block = picker.request(for: peerA, pipeline: 32) { assigned.append(block.piece) }
  #expect(assigned == [2, 3, 4, 5])
  #expect(picker.cursor == 2)
}

@Test func advancePastFollowsOrderNotNumericOrder() {
  var picker = makePicker(pieceCount: 8)
  picker.setOrder([4, 5, 6, 7, 0, 1, 2, 3])
  picker.setAllAvailable(on: peerA)

  // After verifying piece 7 (position 3), the frontier is piece 0 — the
  // next piece in fetch order — not piece 8.
  picker.advancePast(7)
  #expect(picker.cursor == 0)
  #expect(
    picker.request(for: peerA, pipeline: 4)
      == PiecePicker.Block(piece: 0, begin: 0, length: 16 * 1024))
}

@Test func setOrderIgnoresInvalidOrders() {
  var picker = makePicker(pieceCount: 4)

  picker.setOrder([0, 1, 1, 3])  // duplicate
  #expect(picker.order == [0, 1, 2, 3])
  picker.setOrder([0, 1, 2, 9])  // out of range
  #expect(picker.order == [0, 1, 2, 3])
  picker.setOrder([0, 1, 2])  // missing pieces (subset is fine)
  #expect(picker.order == [0, 1, 2])
}

@Test func setOrderResetsFrontierToFirstUnverified() {
  var picker = makePicker(pieceCount: 6)
  picker.setAllAvailable(on: peerA)
  _ = picker.request(for: peerA, pipeline: 4)  // piece 0 in flight
  picker.advancePast(0)

  // Reordering mid-download resets the frontier to the new order's head.
  picker.setOrder([3, 4, 5, 1, 2])
  #expect(picker.cursor == 3)
}

// MARK: - Received-block tracking (multi-block piece progression)

@Test func receivedBlockIsNotReRequested() {
  var picker = makePicker(pieceCount: 1, pieceLength: 16 * 1024 * 4)  // 1 piece, 4 blocks
  picker.setAllAvailable(on: peerA)

  // Fill the pipeline: blocks 0..<4 of piece 0.
  let b0 = picker.request(for: peerA, pipeline: 4)
  let b1 = picker.request(for: peerA, pipeline: 4)
  let b2 = picker.request(for: peerA, pipeline: 4)
  let b3 = picker.request(for: peerA, pipeline: 4)
  #expect([b0, b1, b2, b3].compactMap { $0?.begin } == [0, 16_384, 32_768, 49_152])

  // Block 0 arrives: completing it frees the pipeline slot, but the picker
  // must NOT re-request block 0 (it is buffered) — it must request the
  // piece's next missing block. There are no more blocks in piece 0, so
  // request returns nil (previously it re-requested block 0 forever).
  picker.complete(PiecePicker.BlockKey(piece: 0, begin: 0), on: peerA)
  #expect(
    picker.request(for: peerA, pipeline: 4) == nil,
    "completed-but-unverified block 0 must not be re-requested")

  // The remaining blocks still complete normally.
  picker.complete(PiecePicker.BlockKey(piece: 0, begin: 16_384), on: peerA)
  picker.complete(PiecePicker.BlockKey(piece: 0, begin: 32_768), on: peerA)
  picker.complete(PiecePicker.BlockKey(piece: 0, begin: 49_152), on: peerA)

  // Verify the piece: received bookkeeping is dropped, cursor advances.
  picker.advancePast(0)
  #expect(picker.received[0] == nil)
  #expect(picker.cursor == 1)
}

@Test func receivedBlockProgressionAcrossPieces() {
  var picker = makePicker(pieceCount: 2, pieceLength: 16 * 1024 * 2)  // 2 pieces, 2 blocks each
  picker.setAllAvailable(on: peerA)

  // Request block 0 of piece 0; complete it; the next request must be
  // block 1 of piece 0 (not block 0 again).
  #expect(
    picker.request(for: peerA, pipeline: 4)
      == PiecePicker.Block(piece: 0, begin: 0, length: 16 * 1024))
  picker.complete(PiecePicker.BlockKey(piece: 0, begin: 0), on: peerA)
  #expect(
    picker.request(for: peerA, pipeline: 4)
      == PiecePicker.Block(piece: 0, begin: 16_384, length: 16 * 1024),
    "after completing block 0, the next request must be block 1, not block 0 again")
  picker.complete(PiecePicker.BlockKey(piece: 0, begin: 16_384), on: peerA)
  picker.advancePast(0)

  // Piece 1 starts fresh: block 0 requestable again.
  #expect(
    picker.request(for: peerA, pipeline: 4)
      == PiecePicker.Block(piece: 1, begin: 0, length: 16 * 1024))
}

@Test func resetReceivedAllowsRefetch() {
  var picker = makePicker(pieceCount: 1, pieceLength: 16 * 1024 * 2)
  picker.setAllAvailable(on: peerA)

  _ = picker.request(for: peerA, pipeline: 4)  // block 0
  picker.complete(PiecePicker.BlockKey(piece: 0, begin: 0), on: peerA)
  #expect(
    picker.request(for: peerA, pipeline: 4)
      == PiecePicker.Block(piece: 0, begin: 16_384, length: 16 * 1024))
  picker.complete(PiecePicker.BlockKey(piece: 0, begin: 16_384), on: peerA)

  // Hash mismatch: reset the piece so ALL its blocks are re-requestable.
  picker.resetReceived(0)
  #expect(picker.received[0] == nil)
  #expect(
    picker.request(for: peerA, pipeline: 4)
      == PiecePicker.Block(piece: 0, begin: 0, length: 16 * 1024))
}

// MARK: - Released-block tracking (malformed block must not freeze a piece)

@Test func releaseReceivedBlockMakesBlockReRequestable() {
  var picker = makePicker(pieceCount: 1, pieceLength: 16 * 1024 * 2)  // 1 piece, 2 blocks
  picker.setAllAvailable(on: peerA)

  // Request block 0 — it is now pending.
  _ = picker.request(for: peerA, pipeline: 4)
  let key = PiecePicker.BlockKey(piece: 0, begin: 0)

  // A malformed block arrived: complete() frees the slot but ALSO marks the
  // block "received". Release that mark — the block was never stored in
  // pieceBuffers, so treating it as received would freeze the piece forever.
  picker.complete(key, on: peerA)
  #expect(picker.received[0] == Set([key]))
  picker.releaseReceivedBlock(key)
  #expect(picker.received[0] == nil)

  // The block is requestable again — the piece can still be assembled.
  #expect(
    picker.request(for: peerA, pipeline: 4)
      == PiecePicker.Block(piece: 0, begin: 0, length: 16 * 1024))
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
  #expect(
    picker.request(for: peerA, pipeline: 4)
      == PiecePicker.Block(piece: 0, begin: 0, length: 16 * 1024))
}
