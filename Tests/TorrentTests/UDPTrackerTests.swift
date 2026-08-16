import Testing
import Foundation
@testable import Torrent

// MARK: - Compact 6-byte peer decoding

@Test func testPeerListCompact6Byte() {
    // 192.0.2.1:6881, 203.0.113.7:51437 (bytes 0xC8 0xED)
    let compact = Data([
        192, 0, 2, 1, 0x1A, 0xE1,
        203, 0, 113, 7, 0xC8, 0xED,
    ])
    #expect(PeerList.decode(compact: compact) == [
        TrackerPeer(host: "192.0.2.1", port: 6881),
        TrackerPeer(host: "203.0.113.7", port: 51437),
    ])
    // A trailing partial entry is ignored.
    #expect(PeerList.decode(compact: Data([192, 0, 2, 1, 0x1A])) == [])
}

// MARK: - UDP announce against FakeUDPTracker

@Test func testConnectThenAnnounce() async throws {
    let compact = Data([
        192, 0, 2, 1, 0x1A, 0xE1,
        203, 0, 113, 7, 0xC8, 0xED,
    ])
    let tracker = try FakeUDPTracker(peers: compact, interval: 900, leechers: 7, seeders: 2)
    let params = TrackerAnnounceParams(
        infoHash: Data(repeating: 0x11, count: 20),
        peerID: Data(repeating: 0x22, count: 20),
        port: 6881,
        uploaded: 56, downloaded: 1234, left: 7890,
        event: "started", numwant: 25
    )
    let response = try await UDPTracker.announce(
        url: tracker.url, params: params,
        timeout: .seconds(5), initialTimeout: .milliseconds(200)
    )
    #expect(response.interval == 900)
    #expect(response.peers == [
        TrackerPeer(host: "192.0.2.1", port: 6881),
        TrackerPeer(host: "203.0.113.7", port: 51437),
    ])
    #expect(response.seeders == 2)
    #expect(response.leechers == 7)

    // The announce request the tracker observed must carry every field.
    let announce = try #require(tracker.lastAnnounce)
    #expect(announce.connectionID == FakeUDPTracker.connectionID)
    #expect(announce.infoHash == Data(repeating: 0x11, count: 20))
    #expect(announce.peerID == Data(repeating: 0x22, count: 20))
    #expect(announce.downloaded == 1234)
    #expect(announce.uploaded == 56)
    #expect(announce.left == 7890)
    #expect(announce.event == 2)          // "started"
    #expect(announce.ip == 0)
    #expect(announce.numwant == 25)
    #expect(announce.port == 6881)
    #expect(tracker.connectCount == 1)
}

@Test func testTransactionMismatch() async throws {
    // The fake answers the connect request with a corrupted txid; the client
    // must reject it instead of returning garbage.
    let tracker = try FakeUDPTracker(peers: Data([192, 0, 2, 1, 0x1A, 0xE1]), interval: 60, wrongTxid: true)
    let params = TrackerAnnounceParams(
        infoHash: Data(repeating: 0, count: 20),
        peerID: Data(repeating: 0, count: 20),
        port: 6881, left: 0
    )
    await #expect(throws: HTTPTrackerError.badResponse) {
        try await UDPTracker.announce(
            url: tracker.url, params: params,
            timeout: .seconds(5), initialTimeout: .milliseconds(200)
        )
    }
}

@Test func testRetransmit() async throws {
    // The fake drops the first connect request; the client must retransmit
    // (same txid) with backoff and succeed.
    let tracker = try FakeUDPTracker(peers: Data([192, 0, 2, 1, 0x1A, 0xE1]), interval: 60, dropFirstConnect: true)
    let params = TrackerAnnounceParams(
        infoHash: Data(repeating: 0x33, count: 20),
        peerID: Data(repeating: 0x44, count: 20),
        port: 6881, left: 1000
    )
    let response = try await UDPTracker.announce(
        url: tracker.url, params: params,
        timeout: .seconds(5), initialTimeout: .milliseconds(200)
    )
    #expect(response.interval == 60)
    #expect(response.peers == [TrackerPeer(host: "192.0.2.1", port: 6881)])
    // Dropped once, then retransmitted once.
    #expect(tracker.connectCount == 2)
}

@Test func testTimeout() async throws {
    // The tracker accepts datagrams but never replies — the client must give
    // up after its retransmit budget and throw .timeout (fast: injectable
    // initial timeout, 100+200+400 ms of waiting).
    let tracker = try FakeUDPTracker(peers: Data([192, 0, 2, 1, 0x1A, 0xE1]), respond: false)
    let params = TrackerAnnounceParams(
        infoHash: Data(repeating: 0, count: 20),
        peerID: Data(repeating: 0, count: 20),
        port: 6881, left: 0
    )
    await #expect(throws: HTTPTrackerError.timeout) {
        try await UDPTracker.announce(
            url: tracker.url, params: params,
            timeout: .seconds(5), initialTimeout: .milliseconds(100)
        )
    }
}
