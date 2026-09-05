import Foundation
import Testing

@testable import Torrent

// MARK: - Helpers

/// A deterministic content stream (avoids compressible all-zero data).
private func makeContent(_ size: Int) -> Data {
  Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
}

/// Compact 6-byte peer entry for 127.0.0.1:port.
private func compactPeer(port: UInt16) -> Data {
  Data([127, 0, 0, 1, UInt8(port >> 8), UInt8(port & 0xFF)])
}

/// Unique temp directory for one test.
private func makeTempDir(_ label: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "\(label)-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func removeTempDir(_ url: URL) { try? FileManager.default.removeItem(at: url) }

/// Consume events until `target` state appears (or the stream ends), bounded
/// by `timeout`. Returns true on match.
private func waitForState(
  _ target: TorrentState, in events: AsyncStream<TorrentEvent>, timeout: Duration = .seconds(15)
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  for await event in events {
    if case .state(let s) = event, s == target { return true }
    if clock.now > deadline { return false }
  }
  return false
}

// MARK: - Tests

@Test func testSequentialDownloadNoUpload() async throws {
  let content = makeContent(1024 * 1024)  // 1 MiB, 16 KiB pieces
  let seederPeerID = Array("-FAKE_SEEDER-0000000".utf8)  // exactly 20 bytes
  let seeder = try FakeSeeder(
    content: content, pieceLength: 16 * 1024, infoHash: [UInt8](repeating: 0xAB, count: 20),
    peerID: seederPeerID)
  defer { seeder.stop() }
  let tracker = try FakeTracker(peers: compactPeer(port: seeder.port), interval: 60)
  let bundle = try SyntheticTorrent.make(
    data: content, pieceLength: 16 * 1024, name: "movie.bin", announce: tracker.url.absoluteString)
  seeder.infoHash = [UInt8](bundle.torrent.infoHash)

  let dir = try makeTempDir("seq")
  defer { removeTempDir(dir) }
  var settings = TorrentSettings()
  settings.saveDirectory = dir

  let session = TorrentSession(torrent: bundle.torrent, settings: settings)
  let events = await session.events
  try await session.start()

  let completed = await waitForState(.completed, in: events, timeout: .seconds(15))
  #expect(completed, "download did not complete in time")

  // Single-file placement: base/name with byte-identical content.
  let saved = dir.appendingPathComponent("movie.bin").standardizedFileURL
  let savedData = try Data(contentsOf: saved)
  #expect(savedData == content)

  // The seeder observed us: interested, requests in strictly ascending
  // piece order, and never any piece/have (no uploads).
  let result = try await seeder.waitForResult(timeout: .seconds(5))
  let messages = result.receivedMessages
  #expect(
    messages.contains {
      if case .interested = $0 { return true }
      return false
    }, "client never sent interested")
  #expect(
    !messages.contains {
      if case .piece = $0 { return true }
      return false
    }, "client uploaded piece data")
  #expect(
    !messages.contains {
      if case .have = $0 { return true }
      return false
    }, "client sent have")

  var lastPiece = -1
  for message in messages {
    if case .request(let index, _, _) = message {
      #expect(index >= lastPiece, "requests not sequential: piece \(index) after \(lastPiece)")
      lastPiece = index
    }
  }
  #expect(lastPiece == bundle.torrent.pieceHashes.count - 1, "did not request the final piece")
}

@Test func testEncryptedOnlyDropsPlaintextPeers() async throws {
  let content = makeContent(512 * 1024)
  let seeder = try FakeSeeder(
    content: content, pieceLength: 16 * 1024, infoHash: [UInt8](repeating: 0xAB, count: 20),
    peerID: Array("-FAKE_SEEDER-0000000".utf8))
  defer { seeder.stop() }
  let plaintext = try FakeSeeder(
    content: content, pieceLength: 16 * 1024, infoHash: [UInt8](repeating: 0xAB, count: 20),
    peerID: Array("-FAKE_PLAINTEXT-0000".utf8), mode: .plaintext)
  defer { plaintext.stop() }
  // The tracker returns both: the MSE seeder and a plaintext-only peer.
  let tracker = try FakeTracker(
    peers: compactPeer(port: seeder.port) + compactPeer(port: plaintext.port), interval: 60)
  let bundle = try SyntheticTorrent.make(
    data: content, pieceLength: 16 * 1024, name: "movie.bin", announce: tracker.url.absoluteString)
  seeder.infoHash = [UInt8](bundle.torrent.infoHash)

  let dir = try makeTempDir("enc")
  defer { removeTempDir(dir) }
  var settings = TorrentSettings()
  settings.saveDirectory = dir

  let session = TorrentSession(torrent: bundle.torrent, settings: settings)
  let events = await session.events
  try await session.start()

  var sawDrop = false
  var completed = false
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(15))
  for await event in events {
    if case .peer(.dropped) = event { sawDrop = true }
    if case .state(let s) = event, s == .completed { completed = true }
    if completed && sawDrop { break }
    if clock.now > deadline { break }
  }

  #expect(sawDrop, "plaintext peer was not dropped")
  #expect(completed, "download did not complete via the encrypted seeder")
  #expect(try Data(contentsOf: dir.appendingPathComponent("movie.bin")) == content)
}

@Test func testMultiFilePlacement() async throws {
  let fileA = makeContent(300_000)
  let fileB = makeContent(100_000)
  let content = fileA + fileB
  let files: [(path: [String], data: Data)] = [(["episodes", "a.bin"], fileA), (["b.bin"], fileB)]
  let seeder = try FakeSeeder(
    content: content, pieceLength: 16 * 1024, infoHash: [UInt8](repeating: 0xAB, count: 20),
    peerID: Array("-FAKE_SEEDER-0000000".utf8))
  defer { seeder.stop() }
  let tracker = try FakeTracker(peers: compactPeer(port: seeder.port), interval: 60)
  let bundle = try SyntheticTorrent.make(
    data: Data(), pieceLength: 16 * 1024, name: "show", files: files,
    announce: tracker.url.absoluteString)
  seeder.infoHash = [UInt8](bundle.torrent.infoHash)

  let dir = try makeTempDir("multi")
  defer { removeTempDir(dir) }
  var settings = TorrentSettings()
  settings.saveDirectory = dir

  let session = TorrentSession(torrent: bundle.torrent, settings: settings)
  try await session.start()
  let completed = await waitForState(.completed, in: await session.events, timeout: .seconds(15))
  #expect(completed)

  #expect(try Data(contentsOf: dir.appendingPathComponent("show/episodes/a.bin")) == fileA)
  #expect(try Data(contentsOf: dir.appendingPathComponent("show/b.bin")) == fileB)
}

@Test func testFilePrioritiesReorderDownload() async throws {
  // File A = pieces 0-1 (2 × 16 KiB), File B = pieces 2-4 (3 × 16 KiB).
  // Prioritizing B must fetch 2,3,4 before 0,1.
  let fileA = makeContent(32 * 1024)
  let fileB = makeContent(48 * 1024)
  let content = fileA + fileB
  let files: [(path: [String], data: Data)] = [(["a.bin"], fileA), (["b.bin"], fileB)]
  let seeder = try FakeSeeder(
    content: content, pieceLength: 16 * 1024, infoHash: [UInt8](repeating: 0xAB, count: 20),
    peerID: Array("-FAKE_SEEDER-0000000".utf8))
  defer { seeder.stop() }
  let tracker = try FakeTracker(peers: compactPeer(port: seeder.port), interval: 60)
  let bundle = try SyntheticTorrent.make(
    data: Data(), pieceLength: 16 * 1024, name: "prio", files: files,
    announce: tracker.url.absoluteString)
  seeder.infoHash = [UInt8](bundle.torrent.infoHash)

  let dir = try makeTempDir("prio")
  defer { removeTempDir(dir) }
  var settings = TorrentSettings()
  settings.saveDirectory = dir

  let session = TorrentSession(torrent: bundle.torrent, settings: settings)
  // File index 1 (b.bin) → priority 1: fetched before the unprioritized a.bin.
  await session.setFilePriorities([1: 1])

  try await session.start()
  let completed = await waitForState(.completed, in: await session.events, timeout: .seconds(15))
  #expect(completed)

  // Byte-identical placement for both files.
  #expect(try Data(contentsOf: dir.appendingPathComponent("prio/a.bin")) == fileA)
  #expect(try Data(contentsOf: dir.appendingPathComponent("prio/b.bin")) == fileB)

  // The seeder saw the prioritized file's pieces requested first, in
  // ascending order, then the rest.
  let requested = try await seeder.waitForResult(timeout: .seconds(5)).receivedMessages.compactMap {
    message -> Int? in
    if case .request(let index, _, _) = message { return index }
    return nil
  }
  #expect(requested.prefix(3) == [2, 3, 4], "prioritized file was not fetched first: \(requested)")
}

@Test func testPerFileProgressInStats() async throws {
  // 100_000 + 100_000 bytes at 16 KiB pieces: piece 6 straddles the file
  // boundary (file A ends at 100_000, which is 6*16_384 + 1_696). Per-file
  // progress must attribute the straddling piece exactly.
  let fileA = makeContent(100_000)
  let fileB = makeContent(100_000)
  let content = fileA + fileB
  let files: [(path: [String], data: Data)] = [(["a.bin"], fileA), (["b.bin"], fileB)]
  let seeder = try FakeSeeder(
    content: content, pieceLength: 16 * 1024, infoHash: [UInt8](repeating: 0xAB, count: 20),
    peerID: Array("-FAKE_SEEDER-0000000".utf8))
  defer { seeder.stop() }
  let tracker = try FakeTracker(peers: compactPeer(port: seeder.port), interval: 60)
  let bundle = try SyntheticTorrent.make(
    data: Data(), pieceLength: 16 * 1024, name: "prog", files: files,
    announce: tracker.url.absoluteString)
  seeder.infoHash = [UInt8](bundle.torrent.infoHash)

  let dir = try makeTempDir("prog")
  defer { removeTempDir(dir) }
  var settings = TorrentSettings()
  settings.saveDirectory = dir

  let session = TorrentSession(torrent: bundle.torrent, settings: settings)
  let events = await session.events
  try await session.start()

  var finalFileProgress: [Int64] = []
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(15))
  var completed = false
  for await event in events {
    if case .stats(let stats) = event {
      if stats.fileVerifiedBytes.count == 2 { finalFileProgress = stats.fileVerifiedBytes }
    }
    if case .state(let s) = event, s == .completed {
      completed = true
      break
    }
    if clock.now > deadline { break }
  }
  #expect(completed, "download did not complete in time")
  #expect(
    finalFileProgress == [100_000, 100_000], "per-file progress is wrong: \(finalFileProgress)")
}

// MARK: - Sequential (contiguous-from-start) per-file progress

/// The sequential head of each file: contiguous verified prefix bytes from
/// the file's start, stopping at the first unverified piece in that file.
@Test func sequentialFileProgressStopsAtFirstGapPerFile() {
  // Two files, 16 KiB pieces. File A = 5 pieces (81,920 B), File B =
  // 6 pieces (98,304 B). Verified: A fully (pieces 0..<5), B only pieces
  // 5..<8 — a gap at piece 8 stops B's head at 3 pieces.
  let fileEnds: [Int64] = [81_920, 180_224]
  let verified: Set<Int> = Set(0..<8)  // 0..4 = A, 5..7 = B
  let head = TorrentSession.sequentialFileProgress(
    pieceCount: 11, pieceLength: 16 * 1024, totalSize: 180_224, fileEnds: fileEnds,
    verified: verified)
  // A: pieces 0-4 fully verified → all 81,920 B count.
  // B: pieces 5,6,7 verified = 49,152 B; piece 8 missing stops the head.
  #expect(head == [81_920, 49_152], "sequential heads wrong: \(head)")
}

@Test func sequentialFileProgressHeadsAreIndependentPerFile() {
  // File A has a gap at piece 2; File B (later) is fully verified. B's
  // head must NOT be killed by A's gap.
  // File A = 4 pieces (65,536 B), File B = 4 pieces (65,536 B).
  let fileEnds: [Int64] = [65_536, 131_072]
  let verified: Set<Int> = [0, 1, 3, 4, 5, 6, 7]  // gap at piece 2 (in A)
  let head = TorrentSession.sequentialFileProgress(
    pieceCount: 8, pieceLength: 16 * 1024, totalSize: 131_072, fileEnds: fileEnds,
    verified: verified)
  // A: pieces 0,1 = 32,768 B, then gap at 2 → head = 32,768 B.
  // B: starts at piece 4, all verified → head = 65,536 B.
  #expect(head == [32_768, 65_536], "per-file heads must be independent: \(head)")
}

@Test func sequentialFileProgressHandlesStraddlingLastPiece() {
  // One file of 40 KB with 16 KiB pieces: pieces 0 (16 K), 1 (16 K),
  // 2 (8 K — straddles nothing here, it's the last short piece). Verified
  // all → head = full 40 KB.
  let head = TorrentSession.sequentialFileProgress(
    pieceCount: 3, pieceLength: 16 * 1024, totalSize: 40_000, fileEnds: [40_000],
    verified: [0, 1, 2])
  #expect(head == [40_000], "straddling last piece should count fully: \(head)")

  // Gap at the last piece → head stops before it.
  let partial = TorrentSession.sequentialFileProgress(
    pieceCount: 3, pieceLength: 16 * 1024, totalSize: 40_000, fileEnds: [40_000], verified: [0, 1])
  #expect(partial == [32 * 1024], "head should stop at the gap: \(partial)")
}

@Test func sequentialFileProgressEmptyVerifiedIsAllZero() {
  let head = TorrentSession.sequentialFileProgress(
    pieceCount: 4, pieceLength: 16 * 1024, totalSize: 64 * 1024, fileEnds: [64 * 1024], verified: []
  )
  #expect(head == [0])
}

@Test func testFilePauseDefersItsPieces() async throws {
  // File A = pieces 0-2, File B = pieces 3-5. Pausing B must keep its
  // pieces out of the fetch order until it's resumed.
  let fileA = makeContent(48 * 1024)
  let fileB = makeContent(48 * 1024)
  let content = fileA + fileB
  let files: [(path: [String], data: Data)] = [(["a.bin"], fileA), (["b.bin"], fileB)]
  let seeder = try FakeSeeder(
    content: content, pieceLength: 16 * 1024, infoHash: [UInt8](repeating: 0xAB, count: 20),
    peerID: Array("-FAKE_SEEDER-0000000".utf8))
  defer { seeder.stop() }
  let tracker = try FakeTracker(peers: compactPeer(port: seeder.port), interval: 60)
  let bundle = try SyntheticTorrent.make(
    data: Data(), pieceLength: 16 * 1024, name: "pause", files: files,
    announce: tracker.url.absoluteString)
  seeder.infoHash = [UInt8](bundle.torrent.infoHash)

  let dir = try makeTempDir("pause")
  defer { removeTempDir(dir) }
  var settings = TorrentSettings()
  settings.saveDirectory = dir

  let session = TorrentSession(torrent: bundle.torrent, settings: settings)
  let events = await session.events
  // Pause b.bin (file index 1) before starting.
  await session.setFilePaused(true, fileIndex: 1)
  try await session.start()

  // While B is paused, only A's pieces may be requested.
  var verified = 0
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(10))
  for await event in events {
    if case .pieceVerified = event {
      verified += 1
      if verified >= 3 { break }  // all of A is done
    }
    if clock.now > deadline { break }
  }
  #expect(verified == 3, "file A did not complete while B was paused: \(verified)")
  let whilePaused = seeder.requestedPieces
  #expect(!whilePaused.contains(3), "paused file's pieces were requested: \(whilePaused)")
  #expect(
    !whilePaused.contains(4) && !whilePaused.contains(5),
    "paused file's pieces were requested: \(whilePaused)")

  // Resume B and let the download finish.
  await session.setFilePaused(false, fileIndex: 1)
  let completed = await waitForState(.completed, in: events, timeout: .seconds(15))
  #expect(completed, "download did not complete after resume")

  #expect(try Data(contentsOf: dir.appendingPathComponent("pause/a.bin")) == fileA)
  #expect(try Data(contentsOf: dir.appendingPathComponent("pause/b.bin")) == fileB)
}

@Test func testWholeDownloadPauseResume() async throws {
  // Pause() must stop requests; resume() must wake the idle peer loop and
  // finish the download. 1 MiB at 16 KiB pieces, with a serve delay so the
  // pause lands mid-download.
  let content = makeContent(1024 * 1024)
  let seeder = try FakeSeeder(
    content: content, pieceLength: 16 * 1024, infoHash: [UInt8](repeating: 0xAB, count: 20),
    peerID: Array("-FAKE_SEEDER-0000000".utf8), serveDelay: .milliseconds(2))
  defer { seeder.stop() }
  let tracker = try FakeTracker(peers: compactPeer(port: seeder.port), interval: 60)
  let bundle = try SyntheticTorrent.make(
    data: content, pieceLength: 16 * 1024, name: "whole.bin", announce: tracker.url.absoluteString)
  seeder.infoHash = [UInt8](bundle.torrent.infoHash)

  let dir = try makeTempDir("whole")
  defer { removeTempDir(dir) }
  var settings = TorrentSettings()
  settings.saveDirectory = dir

  let session = TorrentSession(torrent: bundle.torrent, settings: settings)
  let events = await session.events
  try await session.start()

  // Wait for the first verified piece, then pause.
  var sawPiece = false
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(10))
  for await event in events {
    if case .pieceVerified = event {
      sawPiece = true
      break
    }
    if clock.now > deadline { break }
  }
  #expect(sawPiece, "no piece verified before pause")

  await session.pause()
  #expect(await session.currentState() == .paused)

  // The client sends its whole pipeline up front (all requests go out
  // before the pause lands); FakeSeeder records them at serveDelay speed,
  // so `requestedPieces` keeps rising for a moment after pause even though
  // NO new requests are sent. Wait until the seeder has recorded every
  // pre-pause request, then assert nothing further arrives while paused.
  var pausedRequests = -1
  let settle = clock.now.advanced(by: .seconds(5))
  while clock.now < settle {
    let n = seeder.requestedPieces.count
    if n == pausedRequests { break }  // stable for one poll interval
    pausedRequests = n
    try await Task.sleep(for: .milliseconds(100))
  }
  #expect(pausedRequests > 0, "no piece was ever requested before pause")
  try await Task.sleep(for: .milliseconds(400))
  #expect(seeder.requestedPieces.count == pausedRequests, "requests continued while paused")

  await session.resume()
  let completed = await waitForState(.completed, in: events, timeout: .seconds(15))
  #expect(completed, "download did not complete after resume")
  #expect(try Data(contentsOf: dir.appendingPathComponent("whole.bin")) == content)
}

@Test func testStatsReportConnectedSeeders() async throws {
  // The FakeSeeder greets with an all-ones bitfield (it has every piece), so
  // once it connects the session's stats must count it as a seeder. We wait
  // for the peer-connected event, then for a stats tick while it's attached.
  let content = makeContent(512 * 1024)  // 32 pieces @ 16 KiB
  let seeder = try FakeSeeder(
    content: content, pieceLength: 16 * 1024, infoHash: [UInt8](repeating: 0xAB, count: 20),
    peerID: Array("-FAKE_SEEDER-0000000".utf8), serveDelay: .milliseconds(40))
  defer { seeder.stop() }
  let tracker = try FakeTracker(peers: compactPeer(port: seeder.port), interval: 60)
  let bundle = try SyntheticTorrent.make(
    data: content, pieceLength: 16 * 1024, name: "seeds.bin", announce: tracker.url.absoluteString)
  seeder.infoHash = [UInt8](bundle.torrent.infoHash)

  let dir = try makeTempDir("seeds")
  defer { removeTempDir(dir) }
  var settings = TorrentSettings()
  settings.saveDirectory = dir
  settings.pipelinePerPeer = 2

  let session = TorrentSession(torrent: bundle.torrent, settings: settings)
  let events = await session.events
  try await session.start()

  // Phase 1: wait until a peer is connected.
  var connected = false
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(10))
  for await event in events {
    if case .peer(.connected) = event {
      connected = true
      break
    }
    if clock.now > deadline { break }
  }
  #expect(connected, "no peer ever connected")

  // Phase 2: after connection, a stats tick must count that peer as a seeder.
  var sawSeeder = false
  let deadline2 = clock.now.advanced(by: .seconds(10))
  for await event in events {
    if case .stats(let stats) = event, stats.seedersConnected > 0 {
      sawSeeder = true
      break
    }
    if clock.now > deadline2 { break }
  }
  #expect(sawSeeder, "connected full-bitfield peer was not counted as a seeder")
}

@Test func testCancelMidDownload() async throws {
  // 2 MiB with a per-block serve delay so the download takes ~0.5s and the
  // cancel lands mid-flight.
  let content = makeContent(2 * 1024 * 1024)
  let seeder = try FakeSeeder(
    content: content, pieceLength: 16 * 1024, infoHash: [UInt8](repeating: 0xAB, count: 20),
    peerID: Array("-FAKE_SEEDER-0000000".utf8), serveDelay: .milliseconds(4))
  defer { seeder.stop() }
  let tracker = try FakeTracker(peers: compactPeer(port: seeder.port), interval: 60)
  let bundle = try SyntheticTorrent.make(
    data: content, pieceLength: 16 * 1024, name: "big.bin", announce: tracker.url.absoluteString)
  seeder.infoHash = [UInt8](bundle.torrent.infoHash)

  let dir = try makeTempDir("cancel")
  defer { removeTempDir(dir) }
  var settings = TorrentSettings()
  settings.saveDirectory = dir

  let session = TorrentSession(torrent: bundle.torrent, settings: settings)
  let events = await session.events
  try await session.start()

  // Wait until at least one piece landed, then cancel.
  var sawPiece = false
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(10))
  for await event in events {
    if case .pieceVerified = event {
      sawPiece = true
      break
    }
    if clock.now > deadline { break }
  }
  #expect(sawPiece, "no piece verified before cancel")

  await session.cancel()
  #expect(await session.currentState() == .stopped)

  // The partial file exists (preallocated to full length, sparse) but its
  // unwritten regions are zeros — not the content pattern.
  let saved = dir.appendingPathComponent("big.bin").standardizedFileURL
  #expect(FileManager.default.fileExists(atPath: saved.path))
  let savedData = try Data(contentsOf: saved)
  #expect(savedData != content, "cancel did not interrupt the download")
}

/// Peer-slot leak regression: when a peer's connect/handshake fails,
/// the session MUST release its peerTasks/spawnedPeers slots. Before the
/// fix, 80 consecutive failed connects permanently blocked all future
/// peer spawning for the session ("Downloading", 0 peers forever).
@Test func testFailedPeersReleaseSlotsAndAllowNewOnes() async throws {
  // 1 MiB content, 16 KiB pieces = 64 pieces. We'll use a tracker that
  // initially returns only bad peers (wrong port → connection refused),
  // then returns a good peer on the next announce.
  let content = makeContent(1024 * 1024)
  let goodPort: UInt16 = 12345  // will bind a real seeder here later

  // Seeder on a known port (we control it).
  let seederPeerID = Array("-FAKE_SEEDER-0000000".utf8)
  let seeder = try FakeSeeder(
    content: content, pieceLength: 16 * 1024, infoHash: [UInt8](repeating: 0xAB, count: 20),
    peerID: seederPeerID, port: goodPort)
  defer { seeder.stop() }

  // Start with a tracker that returns 85 bad peers (port 1 = refused).
  // 85 > maxPeers (80), so without the fix the session would fill all
  // slots on the first announce and never spawn the good peer.
  var badPeers = Data()
  for _ in 0..<85 { badPeers += compactPeer(port: 1) }
  let tracker = try FakeTracker(peers: badPeers, interval: 60)
  let bundle = try SyntheticTorrent.make(
    data: content, pieceLength: 16 * 1024, name: "slot-leak.bin",
    announce: tracker.url.absoluteString)
  seeder.infoHash = [UInt8](bundle.torrent.infoHash)

  let dir = try makeTempDir("slot-leak")
  defer { removeTempDir(dir) }
  var settings = TorrentSettings()
  settings.saveDirectory = dir
  settings.maxPeers = 80

  let session = TorrentSession(torrent: bundle.torrent, settings: settings)
  let events = await session.events
  try await session.start()

  // Wait for the first announce to complete (all 85 bad peers will try
  // and fail — connection refused on port 1). The session should not
  // deadlock; it will cycle through them, each failing and (after the fix)
  // releasing its slot immediately.
  var sawState = false
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(10))
  for await event in events {
    if case .state(let s) = event {
      if s == .downloading {
        sawState = true
        break
      }
    }
    if clock.now > deadline { break }
  }
  #expect(sawState, "session never entered downloading state")

  // Now give the tracker the GOOD peer and force a re-announce.
  // If slots leaked, peerTasks.count == maxPeers and the new peer
  // would never be spawned. With the fix, slots freed, so it connects.
  tracker.setPeers(compactPeer(port: goodPort))
  await session.reannounce()

  // Wait for completion — the good peer must be spawned and serve all pieces.
  let completed = await waitForState(.completed, in: events, timeout: .seconds(30))
  #expect(completed, "download did not complete; likely peer slots leaked")

  let saved = dir.appendingPathComponent("slot-leak.bin").standardizedFileURL
  let savedData = try Data(contentsOf: saved)
  #expect(savedData == content)
}

/// A removed file quit the download: it is not created on disk, its pieces are
/// never requested, and the download completes without it (all non-removed
/// files done). Removing before start() is deterministic — no race with an
/// in-flight write — and exercises the prepare-must-not-resurrect path.
@Test func testRemovedFileCompletesDownloadWithoutIt() async throws {
  let fileA = makeContent(48 * 1024)  // pieces 0-2
  let fileB = makeContent(48 * 1024)  // pieces 3-5
  let content = fileA + fileB
  let files: [(path: [String], data: Data)] = [(["a.bin"], fileA), (["b.bin"], fileB)]
  let seeder = try FakeSeeder(
    content: content, pieceLength: 16 * 1024, infoHash: [UInt8](repeating: 0xAB, count: 20),
    peerID: Array("-FAKE_SEEDER-0000000".utf8), serveDelay: .milliseconds(3))
  defer { seeder.stop() }
  let tracker = try FakeTracker(peers: compactPeer(port: seeder.port), interval: 60)
  let bundle = try SyntheticTorrent.make(
    data: Data(), pieceLength: 16 * 1024, name: "rem", files: files,
    announce: tracker.url.absoluteString)
  seeder.infoHash = [UInt8](bundle.torrent.infoHash)

  let dir = try makeTempDir("rem")
  defer { removeTempDir(dir) }
  var settings = TorrentSettings()
  settings.saveDirectory = dir

  let session = TorrentSession(torrent: bundle.torrent, settings: settings)
  let events = await session.events
  // Remove b.bin (file index 1) BEFORE the download starts: its file must not
  // be resurrected by prepare() and its pieces must never leave the order.
  await session.setFileRemoved(true, fileIndex: 1)
  try await session.start()

  let completed = await waitForState(.completed, in: events, timeout: .seconds(15))
  #expect(completed, "download did not complete with the file removed")

  // a.bin is present and byte-identical; b.bin was never created.
  #expect(try Data(contentsOf: dir.appendingPathComponent("rem/a.bin")) == fileA)
  #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("rem/b.bin").path))

  // The seeder never saw a request for the removed file's pieces.
  let requested = try await seeder.waitForResult(timeout: .seconds(5)).receivedMessages.compactMap {
    message -> Int? in
    if case .request(let index, _, _) = message { return index }
    return nil
  }
  #expect(!requested.contains(3) && !requested.contains(4) && !requested.contains(5))
  #expect(requested.sorted() == [0, 1, 2])
}

/// A removed file can be restored ("unpaused") to continue downloading: after
/// remove → restore its pieces re-enter the fetch order and both files land.
/// Done before start() so it is deterministic — no race with completion.
@Test func testRestoredFileDownloadsAfterRemoval() async throws {
  let fileA = makeContent(48 * 1024)  // pieces 0-2
  let fileB = makeContent(48 * 1024)  // pieces 3-5
  let content = fileA + fileB
  let files: [(path: [String], data: Data)] = [(["a.bin"], fileA), (["b.bin"], fileB)]
  let seeder = try FakeSeeder(
    content: content, pieceLength: 16 * 1024, infoHash: [UInt8](repeating: 0xAB, count: 20),
    peerID: Array("-FAKE_SEEDER-0000000".utf8), serveDelay: .milliseconds(3))
  defer { seeder.stop() }
  let tracker = try FakeTracker(peers: compactPeer(port: seeder.port), interval: 60)
  let bundle = try SyntheticTorrent.make(
    data: Data(), pieceLength: 16 * 1024, name: "rest", files: files,
    announce: tracker.url.absoluteString)
  seeder.infoHash = [UInt8](bundle.torrent.infoHash)

  let dir = try makeTempDir("rest")
  defer { removeTempDir(dir) }
  var settings = TorrentSettings()
  settings.saveDirectory = dir

  let session = TorrentSession(torrent: bundle.torrent, settings: settings)
  let events = await session.events
  // Remove b.bin, then restore it — both before start, so no race.
  await session.setFileRemoved(true, fileIndex: 1)
  await session.setFileRemoved(false, fileIndex: 1)
  try await session.start()

  let completed = await waitForState(.completed, in: events, timeout: .seconds(15))
  #expect(completed, "download did not complete after restoring the file")

  // Both files are present and byte-identical — b.bin was re-downloaded.
  #expect(try Data(contentsOf: dir.appendingPathComponent("rest/a.bin")) == fileA)
  #expect(try Data(contentsOf: dir.appendingPathComponent("rest/b.bin")) == fileB)

  // Every piece of both files was requested.
  let requested = try await seeder.waitForResult(timeout: .seconds(5)).receivedMessages.compactMap {
    message -> Int? in
    if case .request(let index, _, _) = message { return index }
    return nil
  }
  #expect(requested.sorted() == [0, 1, 2, 3, 4, 5])
}
