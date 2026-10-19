// Darwin sockets: the fake peers and trackers (and the suites over them) build on Apple platforms.
#if canImport(Darwin)
import Foundation
import Testing

@testable import Torrent

/// Decode a hex string into bytes.
private func hex(_ s: String) -> [UInt8] {
  var bytes: [UInt8] = []
  bytes.reserveCapacity(s.count / 2)
  var i = s.startIndex
  while i < s.endIndex {
    let pair = String(s[i...s.index(after: i)])
    bytes.append(UInt8(pair, radix: 16)!)
    i = s.index(i, offsetBy: 2)
  }
  return bytes
}

private let infoHash = Data(hex("9fbb17d030f7f5c51310fa49319eb28a30eb3329"))
private let clientPeerID = Data(hex("2d474554303030302d4d53453030303030303031"))
private let fakePeerID = hex("2d46414b455f504545522d303030303030303031")

// MARK: - PeerConnection vs FakeWirePeer

/// Full MSE + wire exchange over real TCP: connect, handshake, bitfield /
/// unchoke greeting, request / piece roundtrip. The piece bytes arriving
/// intact prove the two RC4 streams stay aligned over the socket.
@Test func testConnectAndExchange() async throws {
  let fake = try FakeWirePeer(infoHash: Array(infoHash), peerID: fakePeerID)
  defer { fake.stop() }
  let connection = PeerConnection(
    host: "127.0.0.1", port: fake.port, infoHash: infoHash, peerID: clientPeerID,
    connectTimeout: .seconds(10), readTimeout: .seconds(10))
  try await connection.start()

  // Greeting from the fake: all-zero bitfield, then unchoke.
  let bitfield = try await connection.receiveMessage()
  #expect(bitfield == .bitfield(Data([0x00])))
  let unchoke = try await connection.receiveMessage()
  #expect(unchoke == .unchoke)

  // Request one 16 KiB block and check the served bytes are intact.
  try await connection.send(.request(index: 0, begin: 0, length: fake.pieceLength))
  let piece = try await connection.receiveMessage()
  #expect(piece == .piece(index: 0, begin: 0, data: Data(fake.pieceData.prefix(fake.pieceLength))))

  #expect(await connection.peerID == Data(fakePeerID))

  try await connection.close()

  // Drain the fake. Safe to await now: the exchange is complete and our
  // side is closed, so the fake's blocked frame read hits EOF and exits.
  let result = try await fake.waitForResult()
  #expect(result.receivedMessages.contains(.request(index: 0, begin: 0, length: fake.pieceLength)))
}

/// The remote peer id is extracted from bytes 48..<68 of the decrypted
/// 68-byte handshake.
@Test func testPeerIDExtracted() async throws {
  let fake = try FakeWirePeer(infoHash: Array(infoHash), peerID: fakePeerID)
  defer { fake.stop() }
  let connection = PeerConnection(
    host: "127.0.0.1", port: fake.port, infoHash: infoHash, peerID: clientPeerID,
    connectTimeout: .seconds(10), readTimeout: .seconds(10))
  try await connection.start()
  #expect(await connection.peerID == Data(fakePeerID))
  #expect(await connection.peerID.count == 20)

  try await connection.close()
  _ = try await fake.waitForResult()
}

/// A peer that answers the DH exchange with a plaintext BT handshake is
/// dropped: an MSE-only client never falls back.
@Test func testPlaintextPeerRejected() async throws {
  let fake = try FakeWirePeer(infoHash: Array(infoHash), peerID: fakePeerID, mode: .plaintext)
  defer { fake.stop() }
  let connection = PeerConnection(
    host: "127.0.0.1", port: fake.port, infoHash: infoHash, peerID: clientPeerID,
    connectTimeout: .seconds(10), readTimeout: .seconds(10))
  await #expect(throws: PeerConnectionError.peerDoesNotSupportEncryption) {
    try await connection.start()
  }
  // The fake's handler already finished (plaintext answer + return), so
  // awaiting it cannot deadlock.
  _ = try await fake.waitForResult()
}

/// A huge length prefix is rejected from the 4-byte prefix alone — the
/// client must never try to read a 10 MiB payload.
@Test func testFrameOverLongRejected() async throws {
  let fake = try FakeWirePeer(infoHash: Array(infoHash), peerID: fakePeerID, oversizedFrame: true)
  defer { fake.stop() }
  let connection = PeerConnection(
    host: "127.0.0.1", port: fake.port, infoHash: infoHash, peerID: clientPeerID,
    connectTimeout: .seconds(10), readTimeout: .seconds(10))
  try await connection.start()
  await #expect(throws: WireCodecError.payloadTooLarge(FakeWirePeer.oversizedFrameLength)) {
    try await connection.receiveMessage()
  }
  try await connection.close()
  _ = try await fake.waitForResult()
}
#endif
