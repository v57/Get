import Testing
import Foundation
import Darwin
@testable import Torrent

// The fake seeder writes over raw POSIX sockets; when a session cancels while
// the seeder is mid-write, the kernel raises SIGPIPE, which by default kills
// the whole test process (a write to a closed socket). Ignoring SIGPIPE turns
// that into EPIPE, which the fake seeder handles as a normal client
// disconnect and exits its connection handler cleanly. Touched at the start
// of the session-level test (static lets are lazy).
private enum SocketSignalSetup {
    static let installed: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()
}

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
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func removeTempDir(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// Remove any persisted resume state for this infohash (test hygiene).
private func removeResumeState(infoHash: Data) {
    try? FileManager.default.removeItem(at: ResumeState.fileURL(infoHash: infoHash))
}

// MARK: - ResumeState persistence

@Test func testResumeStateSaveLoadRoundtrip() throws {
    let infoHash = Data((0..<20).map { UInt8($0) })
    defer { removeResumeState(infoHash: infoHash) }
    let state = ResumeState(pieceLength: 16 * 1024, totalSize: 1_048_576, verified: [0, 1, 2, 63, 64, 65])
    state.save(infoHash: infoHash)
    #expect(ResumeState.load(infoHash: infoHash) == state)
}

@Test func testResumeStateFileURLIsStableAndHexNamed() {
    let hash = Data([0xAB, 0xCD, 0xEF] + [UInt8](repeating: 0, count: 17))
    let url = ResumeState.fileURL(infoHash: hash)
    let expectedName = hash.map { String(format: "%02x", $0) }.joined() + ".state"
    #expect(url.lastPathComponent == expectedName, "state file is not hex-named: \(url.lastPathComponent)")
    #expect(url.deletingLastPathComponent().lastPathComponent == "Get",
            "state file is not under Application Support/Get")
    #expect(ResumeState.fileURL(infoHash: hash) == url, "file URL is not stable")
    let other = Data([0xAB, 0xCD, 0xEF] + [UInt8](repeating: 1, count: 17))
    #expect(ResumeState.fileURL(infoHash: other) != url, "different infohashes share a state file")
}

@Test func testResumeStateFileURLAcceptsHex() {
    let hex = (0..<20).map { String(format: "%02x", $0) }.joined()
    let fromData = ResumeState.fileURL(infoHash: Data((0..<20).map { UInt8($0) }))
    #expect(ResumeState.fileURL(infoHashHex: hex) == fromData,
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
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{ this is not valid json ]".utf8).write(to: url)
    #expect(ResumeState.load(infoHash: infoHash) == nil)
}

// MARK: - Session-level resume

@Test func testResumedSessionSkipsVerifiedPieces() async throws {
    // 2 MiB @ 16 KiB pieces = 128 pieces; the seeder throttles every block so
    // the cancel lands deterministically around the halfway point.
    let content = makeContent(2 * 1024 * 1024)
    let pieceLength = 16 * 1024
    let seeder = try FakeSeeder(content: content, pieceLength: pieceLength,
                                infoHash: [UInt8](repeating: 0xAB, count: 20),
                                peerID: Array("-FAKE_SEEDER-0000000".utf8),
                                serveDelay: .milliseconds(4))
    defer { seeder.stop() }
    let tracker = try FakeTracker(peers: compactPeer(port: seeder.port), interval: 60)
    let bundle = try SyntheticTorrent.make(data: content, pieceLength: pieceLength,
                                           name: "resume.bin",
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
        if case .state(let s) = event, s == .completed { completed = true; break }
        if clock.now > deadline2 { break }
    }

    #expect(completed, "resumed download did not complete")
    let resumePoint = resumedPieces.first ?? -1
    #expect(resumePoint >= target,
            "resumed session re-fetched verified pieces (first event \(resumePoint), expected >= \(target))")
    #expect(resumedPieces == Array(resumePoint..<bundle.torrent.pieceHashes.count),
            "resumed pieceVerified events are not contiguous from the resume point: \(resumedPieces)")
    #expect(try Data(contentsOf: dir.appendingPathComponent("resume.bin")) == content)
}
