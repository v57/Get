import Foundation
import Testing

@testable import Torrent

/// A finished download keeps showing its last `.stats` (the stats loop stops),
/// so that event must carry full per-file progress and no speed.
@Test func finishedDownloadReportsFullSequentialProgressAndNoSpeed() async throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
    "finish-stats-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }

  // Random content so the infohash (and its global resume state) is unique.
  let a = Data((0..<40_000).map { _ in UInt8.random(in: 0...255) })
  let b = Data((0..<25_000).map { _ in UInt8.random(in: 0...255) })
  let made = try SyntheticTorrent.make(
    data: Data(), name: "finish", files: [(["a.bin"], a), (["b.bin"], b)])
  let torrent = made.torrent
  defer { try? FileManager.default.removeItem(at: ResumeState.fileURL(infoHash: torrent.infoHash)) }

  // Every file already on disk and every piece recorded as verified: start()
  // re-verifies them and finishes without touching the network.
  let root = dir.appendingPathComponent("finish", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  try a.write(to: root.appendingPathComponent("a.bin"))
  try b.write(to: root.appendingPathComponent("b.bin"))
  ResumeState(
    pieceLength: torrent.pieceLength, totalSize: torrent.totalSize,
    verified: Array(0..<torrent.pieceHashes.count)
  ).save(infoHash: torrent.infoHash)

  var settings = TorrentSettings()
  settings.saveDirectory = dir
  let session = TorrentSession(torrent: torrent, settings: settings)
  let events = await session.events
  try await session.start()

  var lastStats: TorrentStats?
  var completed = false
  for await event in events {
    switch event {
    case .stats(let stats): lastStats = stats
    case .state(.completed): completed = true
    default: break
    }
  }
  #expect(completed)
  let stats = try #require(lastStats)
  #expect(stats.progress == 1)
  #expect(stats.downloadSpeed == 0)
  #expect(stats.fileVerifiedBytes == [Int64(a.count), Int64(b.count)])
  #expect(stats.fileSequentialBytes == [Int64(a.count), Int64(b.count)])
}
