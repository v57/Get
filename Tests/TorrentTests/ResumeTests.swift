import Darwin
import Foundation
import Testing

@testable import Torrent

// The fake seeder writes over raw POSIX sockets; when a session cancels while
// the seeder is mid-write, the kernel raises SIGPIPE, which by default kills
// the whole test process (a write to a closed socket). Ignoring SIGPIPE turns
// that into EPIPE, which the fake seeder handles as a normal client
// disconnect and exits its connection handler cleanly. Touched at the start
// of the session-level test (static lets are lazy).
private enum SocketSignalSetup { static let installed: Void = { signal(SIGPIPE, SIG_IGN) }() }

// MARK: - Helpers

/// Deterministic content stream (same pattern as SessionIntegrationTests).
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

/// Remove any persisted resume state for this infohash (test hygiene).
private func removeResumeState(infoHash: Data) {
  try? FileManager.default.removeItem(at: ResumeState.fileURL(infoHash: infoHash))
}

// MARK: - ResumeState persistence

@Test func testResumeStateSaveLoadRoundtrip() throws {
  let infoHash = Data((0..<20).map { UInt8($0) })
  defer { removeResumeState(infoHash: infoHash) }
  let state = ResumeState(
    pieceLength: 16 * 1024, totalSize: 1_048_576, verified: [0, 1, 2, 63, 64, 65])
  state.save(infoHash: infoHash)
  #expect(ResumeState.load(infoHash: infoHash) == state)
}

@Test func testResumeStateFileURLIsStableAndHexNamed() {
  let hash = Data([0xAB, 0xCD, 0xEF] + [UInt8](repeating: 0, count: 17))
  let url = ResumeState.fileURL(infoHash: hash)
  let expectedName = hash.map { String(format: "%02x", $0) }.joined() + ".state"
  #expect(
    url.lastPathComponent == expectedName, "state file is not hex-named: \(url.lastPathComponent)")
  #expect(
    url.deletingLastPathComponent().lastPathComponent == "Get",
    "state file is not under Application Support/Get")
  #expect(ResumeState.fileURL(infoHash: hash) == url, "file URL is not stable")
  let other = Data([0xAB, 0xCD, 0xEF] + [UInt8](repeating: 1, count: 17))
  #expect(ResumeState.fileURL(infoHash: other) != url, "different infohashes share a state file")
}

@Test func testResumeStateFileURLAcceptsHex() {
  let hex = (0..<20).map { String(format: "%02x", $0) }.joined()
  let fromData = ResumeState.fileURL(infoHash: Data((0..<20).map { UInt8($0) }))
  #expect(
    ResumeState.fileURL(infoHashHex: hex) == fromData,
    "hex and Data forms disagree on the state file URL")
}

@Test func testResumeStateMissingFileLoadsNil() {
  let infoHash = Data((0..<20).map { UInt8(0xFE - $0) })
  removeResumeState(infoHash: infoHash)
  #expect(ResumeState.load(infoHash: infoHash) == nil)
}

@Test func testResumeStateCorruptFileLoadsNil() throws {
  let infoHash = Data((0..<20).map { UInt8(0x11 + $0) })
  defer { removeResumeState(infoHash: infoHash) }
  let url = ResumeState.fileURL(infoHash: infoHash)
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data("{ this is not valid json ]".utf8).write(to: url)
  #expect(ResumeState.load(infoHash: infoHash) == nil)
}

// MARK: - Session-level resume

@Test func testResumedSessionSkipsVerifiedPieces() async throws {
  // 2 MiB @ 16 KiB pieces = 128 pieces; the seeder throttles every block so
  // the cancel lands deterministically around the halfway point.
  let content = makeContent(2 * 1024 * 1024)
  let pieceLength = 16 * 1024
  let seeder = try FakeSeeder(
    content: content, pieceLength: pieceLength, infoHash: [UInt8](repeating: 0xAB, count: 20),
    peerID: Array("-FAKE_SEEDER-0000000".utf8), serveDelay: .milliseconds(4))
  defer { seeder.stop() }
  let tracker = try FakeTracker(peers: compactPeer(port: seeder.port), interval: 60)
  let bundle = try SyntheticTorrent.make(
    data: content, pieceLength: pieceLength, name: "resume.bin",
    announce: tracker.url.absoluteString)
  seeder.infoHash = [UInt8](bundle.torrent.infoHash)
  defer { removeResumeState(infoHash: bundle.torrent.infoHash) }

  let dir = try makeTempDir("resume")
  defer { removeTempDir(dir) }
  var settings = TorrentSettings()
  settings.saveDirectory = dir
  settings.pipelinePerPeer = 1

  // Hermetic: a crashed previous run may have left a state file behind.
  removeResumeState(infoHash: bundle.torrent.infoHash)
  _ = SocketSignalSetup.installed

  // Session 1: download to ~50%, then cancel. Pipeline 1 keeps at most one
  // request in flight, so the cancel lands with the seeder idle (blocked in
  // read) rather than mid-write.
  let first = TorrentSession(torrent: bundle.torrent, settings: settings)
  let firstEvents = await first.events
  try await first.start()

  let target = bundle.torrent.pieceHashes.count / 2
  var firstVerified: [Int] = []
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(15))
  for await event in firstEvents {
    if case .pieceVerified(let index) = event {
      firstVerified.append(index)
      if firstVerified.count >= target { break }
    }
    if clock.now > deadline { break }
  }
  #expect(firstVerified.count >= target, "session 1 did not reach ~50% before the deadline")
  #expect(firstVerified == Array(0..<target), "session 1 was not sequential: \(firstVerified)")

  await first.cancel()
  #expect(await first.currentState() == .stopped)

  // Cancelling must have persisted the verified set.
  guard let saved = ResumeState.load(infoHash: bundle.torrent.infoHash) else {
    Issue.record("no resume state persisted after cancel")
    return
  }
  #expect(saved.verified.count >= target, "saved resume state lost verified pieces")
  #expect(saved.verified == saved.verified.sorted(), "saved verified list is not sorted")
  #expect(saved.pieceLength == pieceLength)
  #expect(saved.totalSize == Int64(content.count))

  // Session 2: same torrent, same save directory — must skip straight to
  // the first unverified piece and complete.
  let second = TorrentSession(torrent: bundle.torrent, settings: settings)
  let secondEvents = await second.events
  try await second.start()

  var resumedPieces: [Int] = []
  var completed = false
  let deadline2 = clock.now.advanced(by: .seconds(15))
  for await event in secondEvents {
    if case .pieceVerified(let index) = event { resumedPieces.append(index) }
    if case .state(let s) = event, s == .completed {
      completed = true
      break
    }
    if clock.now > deadline2 { break }
  }

  #expect(completed, "resumed download did not complete")
  let resumePoint = resumedPieces.first ?? -1
  #expect(
    resumePoint >= target,
    "resumed session re-fetched verified pieces (first event \(resumePoint), expected >= \(target))"
  )
  #expect(
    resumedPieces == Array(resumePoint..<bundle.torrent.pieceHashes.count),
    "resumed pieceVerified events are not contiguous from the resume point: \(resumedPieces)")
  #expect(try Data(contentsOf: dir.appendingPathComponent("resume.bin")) == content)
}

/// A resume state that claims pieces verified whose data is NOT actually on
/// disk (the stale-claim corruption: a piece recorded as verified before its
/// bytes were written, or a file region overwritten since) must not be
/// trusted. The session re-verifies and falls back to fetching from piece 0.
@Test func staleResumeClaimsAreNotTrusted() async throws {
  let content = makeContent(256 * 1024)  // 16 pieces @ 16 KiB
  let pieceLength = 16 * 1024
  let seeder = try FakeSeeder(
    content: content, pieceLength: pieceLength, infoHash: [UInt8](repeating: 0xCD, count: 20),
    peerID: Array("-FAKE_SEEDER-0000000".utf8))
  defer { seeder.stop() }
  let tracker = try FakeTracker(peers: compactPeer(port: seeder.port), interval: 60)
  let bundle = try SyntheticTorrent.make(
    data: content, pieceLength: pieceLength, name: "stale.bin", announce: tracker.url.absoluteString
  )
  seeder.infoHash = [UInt8](bundle.torrent.infoHash)
  let dir = try makeTempDir("stale")
  defer { removeTempDir(dir) }
  defer { removeResumeState(infoHash: bundle.torrent.infoHash) }
  _ = SocketSignalSetup.installed

  // The data file exists at the exact torrent length (so resumeDataFilesPresent
  // passes) but its content is all zeros — the file was preallocated and the
  // claimed pieces were never actually written (or were truncated since).
  var settings = TorrentSettings()
  settings.saveDirectory = dir
  let url = dir.appendingPathComponent("stale.bin")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
  guard fd >= 0 else {
    Issue.record("cannot create stale data file")
    return
  }
  ftruncate(fd, off_t(content.count))
  Darwin.close(fd)

  // Corrupt state: claims pieces 0..<12 verified, but the disk has zeros.
  let bogus = ResumeState(
    pieceLength: pieceLength, totalSize: Int64(content.count), verified: Array(0..<12))
  bogus.save(infoHash: bundle.torrent.infoHash)

  let session = TorrentSession(torrent: bundle.torrent, settings: settings)
  let events = await session.events
  try await session.start()

  var verified: [Int] = []
  var completed = false
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(15))
  for await event in events {
    if case .pieceVerified(let index) = event { verified.append(index) }
    if case .state(let s) = event, s == .completed {
      completed = true
      break
    }
    if clock.now > deadline { break }
  }

  #expect(completed, "download did not complete")
  // The stale claims must NOT be trusted: the session re-fetches everything
  // from piece 0 (any claimed-but-zero piece would be re-fetched).
  #expect(
    verified == Array(0..<bundle.torrent.pieceHashes.count),
    "session trusted stale resume claims and skipped pieces: \\(verified)")
  #expect(try Data(contentsOf: url) == content)
}

// MARK: - Peer slot exhaustion

/// Grab a currently-free TCP port and immediately release it: connecting
/// there deterministically fails with connection-refused (localhost).
private func grabDeadPort() -> UInt16 {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  precondition(fd >= 0)
  defer { Darwin.close(fd) }
  var addr = sockaddr_in()
  addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  addr.sin_family = sa_family_t(AF_INET)
  addr.sin_port = 0
  addr.sin_addr.s_addr = inet_addr("127.0.0.1")
  let bound = withUnsafePointer(to: &addr) { p in
    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
      bind(fd, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  precondition(bound == 0)
  var len = socklen_t(MemoryLayout<sockaddr_in>.size)
  var out = sockaddr_in()
  let named = withUnsafeMutablePointer(to: &out) { p in
    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in getsockname(fd, sp, &len) }
  }
  precondition(named == 0)
  return UInt16(bigEndian: out.sin_port)
}

/// A peer endpoint whose connect FAILS (refused) must free its session slot.
/// Cleanup used to live only inside peerLoop's defer — which never runs when
/// `connection.start()` throws — so every failed endpoint leaked its slot
/// permanently. A tracker that keeps sampling dead endpoints then starves the
/// session: once `maxPeers` DISTINCT bad endpoints had been seen, the real
/// seeder in a later announce batch could never be spawned ("Downloading",
/// peers 0, nothing progresses). This reproduces exactly that shape: two dead
/// endpoints fill `maxPeers`, the live seeder only appears via re-announce.
@Test func failedConnectsFreePeerSlotsForLaterAnnounces() async throws {
  let content = makeContent(256 * 1024)  // 16 pieces @ 16 KiB
  let pieceLength = 16 * 1024
  let seeder = try FakeSeeder(
    content: content, pieceLength: pieceLength, infoHash: [UInt8](repeating: 0xEF, count: 20),
    peerID: Array("-FAKE_SEEDER-0000000".utf8))
  defer { seeder.stop() }

  // Two guaranteed-dead local ports; the tracker announces them FIRST, the
  // live seeder LAST (per-announce order is preserved by the engine).
  let deadA = grabDeadPort()
  let deadB = grabDeadPort()
  var announced = compactPeer(port: deadA) + compactPeer(port: deadB)
  announced += compactPeer(port: seeder.port)

  // interval 1 → the tracker loop re-announces every second, so the live
  // peer gets its chance only after the dead ones have failed AND freed
  // their slots (the old leak made that impossible).
  let tracker = try FakeTracker(peers: announced, interval: 1)
  let bundle = try SyntheticTorrent.make(
    data: content, pieceLength: pieceLength, name: "slots.bin", announce: tracker.url.absoluteString
  )
  seeder.infoHash = [UInt8](bundle.torrent.infoHash)
  defer { removeResumeState(infoHash: bundle.torrent.infoHash) }
  _ = SocketSignalSetup.installed

  let dir = try makeTempDir("slots")
  defer { removeTempDir(dir) }
  var settings = TorrentSettings()
  settings.saveDirectory = dir
  settings.maxPeers = 2  // exactly consumed by the two dead endpoints

  let session = TorrentSession(torrent: bundle.torrent, settings: settings)
  let events = await session.events
  try await session.start()

  var completed = false
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(20))
  for await event in events {
    if case .state(let s) = event, s == .completed {
      completed = true
      break
    }
    if clock.now > deadline { break }
  }

  #expect(completed, "session stalled: failed-connect peers consumed the limited peer slots")
  #expect(try Data(contentsOf: dir.appendingPathComponent("slots.bin")) == content)
}
