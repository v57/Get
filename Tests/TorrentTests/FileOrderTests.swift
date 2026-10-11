import Foundation
import Testing

@testable import Torrent

@Test func naturalOrderComparesNumbersByValueAndIgnoresCase() {
  let paths = [["b.txt"], ["a 10.mkv"], ["a 2.mkv"], ["A 1.mkv"]]
  #expect(TorrentFile.naturalOrder(of: paths) == [3, 2, 1, 0])
}

@Test func naturalOrderComparesPathsComponentByComponent() {
  let paths = [["Season 10", "E1"], ["Season 2", "E10"], ["Season 2", "E9"], ["Season 2"]]
  #expect(TorrentFile.naturalOrder(of: paths) == [3, 2, 1, 0])
}

@Test func naturalOrderKeepsEqualPathsStable() {
  #expect(TorrentFile.naturalOrder(of: [["x"], ["x"], ["X"]]) == [0, 1, 2])
}

// Torrent order "Ep 10" (30 B), "Ep 2" (25 B), "Ep 1" (20 B), 10-byte pieces:
// p0-p2 are Ep 10, p3-p4 Ep 2, p5 straddles Ep 2 and Ep 1, p6-p7 Ep 1.
private let fileEnds: [Int64] = [30, 55, 75]
private let filePosition = [2, 1, 0]  // natural order: Ep 1, Ep 2, Ep 10

private func order(
  priorities: [Int: Int] = [:], skipped: Set<Int> = [], verified: Set<Int> = []
) -> (order: [Int], pieceFile: [Int]) {
  TorrentSession.fetchOrder(
    pieceCount: 8, pieceLength: 10, totalSize: 75, fileEnds: fileEnds,
    filePosition: filePosition, priorities: priorities, skipped: skipped, verified: verified)
}

@Test func fetchOrderFollowsNaturalFileOrder() {
  let result = order()
  #expect(result.order == [5, 6, 7, 3, 4, 0, 1, 2])
  // The straddling piece is fetched for Ep 1, which comes first and needs it
  // for its head.
  #expect(result.pieceFile == [0, 0, 0, 1, 1, 2, 2, 2])
}

@Test func fetchOrderPutsPrioritizedFilesFirst() {
  #expect(order(priorities: [0: 1]).order == [0, 1, 2, 5, 6, 7, 3, 4])
  #expect(order(priorities: [0: 2, 1: 1]).order == [3, 4, 5, 0, 1, 2, 6, 7])
}

@Test func fetchOrderSkipsPausedFilesButKeepsSharedPieces() {
  let result = order(skipped: [2])
  // Ep 1 is paused: the straddling piece is still fetched, for Ep 2's tail.
  #expect(result.order == [3, 4, 5, 0, 1, 2])
  #expect(result.pieceFile == [0, 0, 0, 1, 1, 1, -1, -1])
}

@Test func fetchOrderLeavesOutVerifiedPieces() {
  #expect(order(verified: [5, 0]).order == [6, 7, 3, 4, 1, 2])
}

@Test func fetchOrderIgnoresEmptyFiles() {
  // An empty file between two 10-byte files never claims the piece at its offset.
  let result = TorrentSession.fetchOrder(
    pieceCount: 2, pieceLength: 10, totalSize: 20, fileEnds: [10, 10, 20],
    filePosition: [1, 0, 2], priorities: [:], skipped: [], verified: [])
  #expect(result.pieceFile == [0, 2])
}
