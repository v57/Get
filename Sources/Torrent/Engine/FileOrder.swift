import Foundation

extension TorrentFile {
  /// File indices in natural name order: paths compared component by
  /// component the way Finder sorts them, so numbers compare by value
  /// ("Episode 2" before "Episode 10") whatever order the `.torrent` lists
  /// the files in. This is the order files are shown and downloaded in.
  public var naturalFileOrder: [Int] { Self.naturalOrder(of: files.map(\.path)) }

  /// Indices of `paths` sorted naturally (see `naturalFileOrder`); equal
  /// paths keep their original order.
  public static func naturalOrder(of paths: [[String]]) -> [Int] {
    paths.indices.sorted { a, b in
      let pa = paths[a]
      let pb = paths[b]
      for (ca, cb) in zip(pa, pb) {
        switch ca.localizedStandardCompare(cb) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: continue
        }
      }
      if pa.count != pb.count { return pa.count < pb.count }
      return a < b
    }
  }
}

extension TorrentSession {
  /// The fetch order and the file each piece is fetched for.
  ///
  /// A piece is fetched for the earliest file that needs it: among the files
  /// it overlaps that are not `skipped` (paused or removed) and not empty, the
  /// one with the lowest (priority rank, natural position). Priority 1...4
  /// ranks first, unprioritized files rank after all of them. Unverified
  /// pieces are then sorted by (rank, position, piece index) so files
  /// download one after another in that order, each from its start. Taking
  /// the earliest overlapping file matters once files are reordered: a file's
  /// first and last pieces usually straddle its neighbours, and attributing
  /// them to the neighbour (which may come much later) would leave the file
  /// without its head or tail until then.
  ///
  /// `pieceFile[piece]` is -1 for a piece no fetchable file needs; it is not
  /// in `order`. Pure, so `init` can call it and tests can check it.
  static func fetchOrder(
    pieceCount: Int, pieceLength: Int64, totalSize: Int64, fileEnds: [Int64],
    filePosition: [Int], priorities: [Int: Int], skipped: Set<Int>, verified: Set<Int>
  ) -> (order: [Int], pieceFile: [Int]) {
    func rank(_ file: Int) -> Int {
      if let p = priorities[file], p >= 1, p <= 4 { return p }
      return 5
    }
    var pieceFile = [Int](repeating: -1, count: pieceCount)
    var keys = [(rank: Int, position: Int)](repeating: (Int.max, Int.max), count: pieceCount)
    var file = 0
    for piece in 0..<pieceCount {
      let start = Int64(piece) * pieceLength
      let end = min(start + pieceLength, totalSize)
      // Files are contiguous in the content stream: skip the ones that end
      // at or before this piece, then walk the ones it overlaps.
      while file < fileEnds.count, fileEnds[file] <= start { file += 1 }
      var f = file
      while f < fileEnds.count {
        let fileStart = f == 0 ? 0 : fileEnds[f - 1]
        if fileStart >= end { break }
        if fileEnds[f] > fileStart, !skipped.contains(f) {
          let key = (rank: rank(f), position: filePosition[f])
          if key < keys[piece] {
            keys[piece] = key
            pieceFile[piece] = f
          }
        }
        f += 1
      }
    }
    let order = (0..<pieceCount).filter { pieceFile[$0] >= 0 && !verified.contains($0) }.sorted {
      a, b in
      if keys[a] != keys[b] { return keys[a] < keys[b] }
      return a < b
    }
    return (order, pieceFile)
  }
}
