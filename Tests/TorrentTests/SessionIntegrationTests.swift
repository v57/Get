import Testing
import Foundation
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
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func removeTempDir(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// Consume events until `target` state appears (or the stream ends), bounded
/// by `timeout`. Returns true on match.
private func waitForState(_ target: TorrentState,
                          in events: AsyncStream<TorrentEvent>,
                          timeout: Duration = .seconds(15)) async -> Bool {
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
    let seederPeerID = Array("-FAKE_SEEDER-0000000".utf8)   // exactly 20 bytes
    let seeder = try FakeSeeder(content: content, pieceLength: 16 * 1024,
                                infoHash: [UInt8](repeating: 0xAB, count: 20),
                                peerID: seederPeerID)
    defer { seeder.stop() }
    let tracker = try FakeTracker(peers: compactPeer(port: seeder.port), interval: 60)
    let bundle = try SyntheticTorrent.make(data: content, pieceLength: 16 * 1024, name: "movie.bin",
                                           announce: tracker.url.absoluteString)
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
    #expect(messages.contains { if case .interested = $0 { return true }; return false },
            "client never sent interested")
    #expect(!messages.contains { if case .piece = $0 { return true }; return false },
            "client uploaded piece data")
    #expect(!messages.contains { if case .have = $0 { return true }; return false },
            "client sent have")

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
    let seeder = try FakeSeeder(content: content, pieceLength: 16 * 1024,
                                infoHash: [UInt8](repeating: 0xAB, count: 20),
                                peerID: Array("-FAKE_SEEDER-0000000".utf8))
    defer { seeder.stop() }
    let plaintext = try FakeSeeder(content: content, pieceLength: 16 * 1024,
                                   infoHash: [UInt8](repeating: 0xAB, count: 20),
                                   peerID: Array("-FAKE_PLAINTEXT-0000".utf8),
                                   mode: .plaintext)
    defer { plaintext.stop() }
    // The tracker returns both: the MSE seeder and a plaintext-only peer.
    let tracker = try FakeTracker(peers: compactPeer(port: seeder.port) + compactPeer(port: plaintext.port),
                                  interval: 60)
    let bundle = try SyntheticTorrent.make(data: content, pieceLength: 16 * 1024, name: "movie.bin",
                                           announce: tracker.url.absoluteString)
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
    let files: [(path: [String], data: Data)] = [
        (["episodes", "a.bin"], fileA),
        (["b.bin"], fileB),
    ]
    let seeder = try FakeSeeder(content: content, pieceLength: 16 * 1024,
                                infoHash: [UInt8](repeating: 0xAB, count: 20),
                                peerID: Array("-FAKE_SEEDER-0000000".utf8))
    defer { seeder.stop() }
    let tracker = try FakeTracker(peers: compactPeer(port: seeder.port), interval: 60)
    let bundle = try SyntheticTorrent.make(data: Data(), pieceLength: 16 * 1024,
                                           name: "show", files: files,
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
    let files: [(path: [String], data: Data)] = [
        (["a.bin"], fileA),
        (["b.bin"], fileB),
    ]
    let seeder = try FakeSeeder(content: content, pieceLength: 16 * 1024,
                                infoHash: [UInt8](repeating: 0xAB, count: 20),
                                peerID: Array("-FAKE_SEEDER-0000000".utf8))
    defer { seeder.stop() }
    let tracker = try FakeTracker(peers: compactPeer(port: seeder.port), interval: 60)
    let bundle = try SyntheticTorrent.make(data: Data(), pieceLength: 16 * 1024,
                                           name: "prio", files: files,
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
    let requested = try await seeder.waitForResult(timeout: .seconds(5)).receivedMessages
        .compactMap { message -> Int? in
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
    let files: [(path: [String], data: Data)] = [
        (["a.bin"], fileA),
        (["b.bin"], fileB),
    ]
    let seeder = try FakeSeeder(content: content, pieceLength: 16 * 1024,
                                infoHash: [UInt8](repeating: 0xAB, count: 20),
                                peerID: Array("-FAKE_SEEDER-0000000".utf8))
    defer { seeder.stop() }
    let tracker = try FakeTracker(peers: compactPeer(port: seeder.port), interval: 60)
    let bundle = try SyntheticTorrent.make(data: Data(), pieceLength: 16 * 1024,
                                           name: "prog", files: files,
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
            if stats.fileVerifiedBytes.count == 2 {
                finalFileProgress = stats.fileVerifiedBytes
            }
        }
        if case .state(let s) = event, s == .completed { completed = true; break }
        if clock.now > deadline { break }
    }
    #expect(completed, "download did not complete in time")
    #expect(finalFileProgress == [100_000, 100_000],
            "per-file progress is wrong: \(finalFileProgress)")
}

@Test func testFilePauseDefersItsPieces() async throws {
    // File A = pieces 0-2, File B = pieces 3-5. Pausing B must keep its
    // pieces out of the fetch order until it's resumed.
    let fileA = makeContent(48 * 1024)
    let fileB = makeContent(48 * 1024)
    let content = fileA + fileB
    let files: [(path: [String], data: Data)] = [
        (["a.bin"], fileA),
        (["b.bin"], fileB),
    ]
    let seeder = try FakeSeeder(content: content, pieceLength: 16 * 1024,
                                infoHash: [UInt8](repeating: 0xAB, count: 20),
                                peerID: Array("-FAKE_SEEDER-0000000".utf8))
    defer { seeder.stop() }
    let tracker = try FakeTracker(peers: compactPeer(port: seeder.port), interval: 60)
    let bundle = try SyntheticTorrent.make(data: Data(), pieceLength: 16 * 1024,
                                           name: "pause", files: files,
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
    #expect(!whilePaused.contains(4) && !whilePaused.contains(5),
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
    let seeder = try FakeSeeder(content: content, pieceLength: 16 * 1024,
                                infoHash: [UInt8](repeating: 0xAB, count: 20),
                                peerID: Array("-FAKE_SEEDER-0000000".utf8),
                                serveDelay: .milliseconds(2))
    defer { seeder.stop() }
    let tracker = try FakeTracker(peers: compactPeer(port: seeder.port), interval: 60)
    let bundle = try SyntheticTorrent.make(data: content, pieceLength: 16 * 1024,
                                           name: "whole.bin",
                                           announce: tracker.url.absoluteString)
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
        if case .pieceVerified = event { sawPiece = true; break }
        if clock.now > deadline { break }
    }
    #expect(sawPiece, "no piece verified before pause")

    await session.pause()
    #expect(await session.currentState() == .paused)

    // In-flight requests (up to the pipeline depth) still land and complete;
    // wait for them to drain, then no NEW requests may arrive while paused.
    try await Task.sleep(for: .milliseconds(250))
    let pausedRequests = seeder.requestedPieces.count
    try await Task.sleep(for: .milliseconds(400))
    #expect(seeder.requestedPieces.count == pausedRequests,
            "requests continued while paused")

    await session.resume()
    let completed = await waitForState(.completed, in: events, timeout: .seconds(15))
    #expect(completed, "download did not complete after resume")
    #expect(try Data(contentsOf: dir.appendingPathComponent("whole.bin")) == content)
}

@Test func testStatsReportConnectedSeeders() async throws {
    // The FakeSeeder greets with an all-ones bitfield (it has every piece), so
    // once it connects the session's stats must count it as a seeder. We wait
    // for the peer-connected event, then for a stats tick while it's attached.
    let content = makeContent(512 * 1024)   // 32 pieces @ 16 KiB
    let seeder = try FakeSeeder(content: content, pieceLength: 16 * 1024,
                                infoHash: [UInt8](repeating: 0xAB, count: 20),
                                peerID: Array("-FAKE_SEEDER-0000000".utf8),
                                serveDelay: .milliseconds(40))
    defer { seeder.stop() }
    let tracker = try FakeTracker(peers: compactPeer(port: seeder.port), interval: 60)
    let bundle = try SyntheticTorrent.make(data: content, pieceLength: 16 * 1024,
                                           name: "seeds.bin",
                                           announce: tracker.url.absoluteString)
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
        if case .peer(.connected) = event { connected = true; break }
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
    let seeder = try FakeSeeder(content: content, pieceLength: 16 * 1024,
                                infoHash: [UInt8](repeating: 0xAB, count: 20),
                                peerID: Array("-FAKE_SEEDER-0000000".utf8),
                                serveDelay: .milliseconds(4))
    defer { seeder.stop() }
    let tracker = try FakeTracker(peers: compactPeer(port: seeder.port), interval: 60)
    let bundle = try SyntheticTorrent.make(data: content, pieceLength: 16 * 1024, name: "big.bin",
                                           announce: tracker.url.absoluteString)
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
        if case .pieceVerified = event { sawPiece = true; break }
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
