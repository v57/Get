import Testing
import Foundation
@testable import Torrent

// MARK: - Peer list decoding

@Test func testPeerListDecodeIPv4() {
    let compact = Data([
        192, 0, 2, 1, 0x1A, 0xE1,        // 192.0.2.1:6881
        203, 0, 113, 7, 0xC8, 0xED,      // 203.0.113.7:51413
    ])
    #expect(PeerList.decode(compact: compact) == [
        TrackerPeer(host: "192.0.2.1", port: 6881),
        TrackerPeer(host: "203.0.113.7", port: 51437),   // bytes 0xC8 0xED
    ])
}

@Test func testPeerListDecodeIPv4IgnoresTrailingBytes() {
    let compact = Data([192, 0, 2, 1, 0x1A, 0xE1, 0x01])  // 7 bytes: trailing byte ignored
    #expect(PeerList.decode(compact: compact) == [TrackerPeer(host: "192.0.2.1", port: 6881)])
}

@Test func testPeerListDecodeV6() {
    // 2001:db8::1:6881 — 16-byte address + 2-byte big-endian port
    let address: [UInt8] = [0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
    let compact = Data(address + [0x1A, 0xE1])
    #expect(PeerList.decodeV6(compact: compact) == [TrackerPeer(host: "2001:db8::1", port: 6881)])
}

@Test func testPeerListDecodeV6AllZeros() {
    let compact = Data([UInt8](repeating: 0, count: 16) + [0x00, 0x50])
    #expect(PeerList.decodeV6(compact: compact) == [TrackerPeer(host: "::", port: 80)])
}

// MARK: - Query building

@Test func testAnnounceBuildsQuery() throws {
    let url = URL(string: "http://tracker.example/announce?pk=secret123")!
    let infoHash = Data([0x00, 0x61, 0xFF, 0x2D, 0x2E, 0x5F, 0x7E, 0x41] + [UInt8](repeating: 0x00, count: 12))
    let peerID = Data([0x00, 0x01, 0x02] + [UInt8](repeating: 0xAB, count: 17))
    let params = TrackerAnnounceParams(
        infoHash: infoHash, peerID: peerID, port: 6881,
        uploaded: 0, downloaded: 1234, left: 5678,
        event: "started", numwant: 25
    )
    let query = HTTPTracker.buildQuery(params: params)
    #expect(query == "info_hash=%00a%FF-._~A" + String(repeating: "%00", count: 12)
        + "&peer_id=%00%01%02" + String(repeating: "%AB", count: 17)
        + "&port=6881&uploaded=0&downloaded=1234&left=5678&compact=1&numwant=25&event=started")

    // The announce URL keeps the tracker's own query params (private-tracker passkeys).
    let built = try HTTPTracker.buildRequestURL(url: url, params: params)
    #expect(built.absoluteString.hasPrefix("http://tracker.example/announce?pk=secret123&info_hash=%00a%FF-._~A"))
}

@Test func testAnnounceBuildsQueryWithoutEvent() throws {
    let url = URL(string: "http://tracker.example/announce")!
    let params = TrackerAnnounceParams(
        infoHash: Data(repeating: 0, count: 20),
        peerID: Data(repeating: 0, count: 20),
        port: 6881, left: 0
    )
    let query = HTTPTracker.buildQuery(params: params)
    #expect(!query.contains("event="))
}

// MARK: - Announce against FakeTracker

@Test func testAnnounceReturnsPeers() async throws {
    let compact = Data([
        192, 0, 2, 1, 0x1A, 0xE1,
        203, 0, 113, 7, 0xC8, 0xED,
    ])
    let tracker = try FakeTracker(peers: compact, interval: 60, seeders: 3, leechers: 5)
    let params = TrackerAnnounceParams(
        infoHash: Data(repeating: 0x11, count: 20),
        peerID: Data(repeating: 0x22, count: 20),
        port: 6881, left: 0, event: "started"
    )
    let response = try await HTTPTracker.announce(url: tracker.url, params: params, timeout: .seconds(5))
    #expect(response.interval == 60)
    #expect(response.peers == [
        TrackerPeer(host: "192.0.2.1", port: 6881),
        TrackerPeer(host: "203.0.113.7", port: 51437),   // bytes 0xC8 0xED
    ])
    #expect(response.seeders == 3)
    #expect(response.leechers == 5)

    let announce = try #require(tracker.lastAnnounce)
    #expect(announce.path == "/announce")
    #expect(announce.query["port"] == "6881")
    #expect(announce.query["uploaded"] == "0")
    #expect(announce.query["downloaded"] == "0")
    #expect(announce.query["left"] == "0")
    #expect(announce.query["compact"] == "1")
    #expect(announce.query["numwant"] == "50")
    #expect(announce.query["event"] == "started")
}

@Test func testAnnouncePercentEncodesInfoHash() async throws {
    let tracker = try FakeTracker(peers: Data([192, 0, 2, 1, 0x1A, 0xE1]), interval: 60)
    let infoHash = Data([0x00, 0xFF, 0x80, 0x41, 0x2D, 0x2E, 0x5F, 0x7E, 0x61] + [UInt8](repeating: 0x00, count: 11))
    let peerID = Data([0x00, 0x01, 0x02] + [UInt8](repeating: 0xAB, count: 17))
    let params = TrackerAnnounceParams(
        infoHash: infoHash, peerID: peerID, port: 6881, left: 1000, event: "started"
    )
    _ = try await HTTPTracker.announce(url: tracker.url, params: params, timeout: .seconds(5))
    let announce = try #require(tracker.lastAnnounce)
    // Every byte except unreserved [A-Za-z0-9-._~] is %XX-encoded.
    #expect(announce.rawQuery.contains("info_hash=%00%FF%80A-._~a" + String(repeating: "%00", count: 11)))
    #expect(announce.rawQuery.contains("peer_id=%00%01%02" + String(repeating: "%AB", count: 17)))
}

@Test func testAnnouncePreservesExistingQuery() async throws {
    let tracker = try FakeTracker(peers: Data([192, 0, 2, 1, 0x1A, 0xE1]), interval: 60)
    let url = URL(string: tracker.url.absoluteString + "?pk=56cbbad8")!
    let params = TrackerAnnounceParams(
        infoHash: Data(repeating: 0, count: 20),
        peerID: Data(repeating: 0, count: 20),
        port: 6881, left: 0
    )
    _ = try await HTTPTracker.announce(url: url, params: params, timeout: .seconds(5))
    let announce = try #require(tracker.lastAnnounce)
    #expect(announce.rawQuery.hasPrefix("pk=56cbbad8&"))
    #expect(announce.query["pk"] == "56cbbad8")
}

@Test func testAnnouncePeers6() async throws {
    let address: [UInt8] = [0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
    let tracker = try FakeTracker(peers6: Data(address + [0x1A, 0xE1]), interval: 30)
    let params = TrackerAnnounceParams(
        infoHash: Data(repeating: 0, count: 20),
        peerID: Data(repeating: 0, count: 20),
        port: 6881, left: 0
    )
    let response = try await HTTPTracker.announce(url: tracker.url, params: params, timeout: .seconds(5))
    #expect(response.interval == 30)
    #expect(response.peers == [TrackerPeer(host: "2001:db8::1", port: 6881)])
}

@Test func testFailureReason() async throws {
    let tracker = try FakeTracker(failureReason: "bad id")
    let params = TrackerAnnounceParams(
        infoHash: Data(repeating: 0, count: 20),
        peerID: Data(repeating: 0, count: 20),
        port: 6881, left: 0
    )
    await #expect(throws: HTTPTrackerError.trackerError("bad id")) {
        try await HTTPTracker.announce(url: tracker.url, params: params, timeout: .seconds(5))
    }
}

@Test func testMalformedBodyThrows() async throws {
    let tracker = try FakeTracker(rawBody: Data("this is not bencode".utf8))
    let params = TrackerAnnounceParams(
        infoHash: Data(repeating: 0, count: 20),
        peerID: Data(repeating: 0, count: 20),
        port: 6881, left: 0
    )
    await #expect(throws: HTTPTrackerError.badResponse) {
        try await HTTPTracker.announce(url: tracker.url, params: params, timeout: .seconds(5))
    }
}

@Test func testMalformedBencodedBodyThrows() async throws {
    // Valid bencode but not a dict — no interval/peers.
    let tracker = try FakeTracker(rawBody: Bencode.encode(.int(42)))
    let params = TrackerAnnounceParams(
        infoHash: Data(repeating: 0, count: 20),
        peerID: Data(repeating: 0, count: 20),
        port: 6881, left: 0
    )
    await #expect(throws: HTTPTrackerError.badResponse) {
        try await HTTPTracker.announce(url: tracker.url, params: params, timeout: .seconds(5))
    }
}
