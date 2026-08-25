import CryptoKit
import Foundation

/// Message Stream Encryption (MSE): constants, key derivation, and the
/// plaintext sync-section helpers for the obfuscated handshake.
///
/// Wire format (verified against libtorrent-rasterbar `bt_peer_connection.cpp`
/// and Transmission `handshake.cc`; this client is always the initiator):
///   1. clear:   [Ya 96-byte pubkey][PadA 0-512]
///   2. clear:   [SHA1("req1" || S) 20][SHA1("req2" || SKEY) xor SHA1("req3" || S) 20]
///   3. rc4:     [VC 8][crypto_provide 4][len(PadC) 2][PadC][len(IA) 2][IA 68]
///   4. rc4 recv:[VC 8][crypto_select 4][len(PadD) 2][PadD][handshake 68]
///
/// Keys: initiator send key = SHA1("keyA" || S || SKEY),
///       initiator recv key = SHA1("keyB" || S || SKEY)   (responder mirrors).
/// Both RC4 streams drop the first 1024 keystream bytes before use.
/// S = DH shared secret (96 bytes), SKEY = torrent infohash (20 bytes).
public enum MSE {
  /// Verification constant: 8 zero bytes. (libtorrent: `sh_vc[] = {0,0,0,0,0,0,0,0}`;
  /// Transmission comment: "VC is a String of 8 bytes set to 0x00".)
  public static let vc: [UInt8] = [UInt8](repeating: 0, count: 8)

  /// `crypto_provide` / `crypto_select` values. This client only offers RC4.
  public static let cryptoProvidePlaintext: UInt32 = 0x01
  public static let cryptoProvideRC4: UInt32 = 0x02

  /// Derive the two 20-byte RC4 keys from the DH shared secret and the
  /// torrent's infohash (the "stream key").
  ///   send = SHA1("keyA" || S || SKEY)   — what the initiator encrypts with
  ///   recv = SHA1("keyB" || S || SKEY)   — what the initiator decrypts with
  public static func deriveKeys(secret: [UInt8], streamKey: [UInt8]) -> (
    send: [UInt8], recv: [UInt8]
  ) { (sha1(Array("keyA".utf8), secret, streamKey), sha1(Array("keyB".utf8), secret, streamKey)) }

  /// SHA1("req1" || S) — the 20-byte sync hash sent in the clear so the
  /// responder can verify it derived the same DH secret.
  public static func syncHash(secret: [UInt8]) -> [UInt8] { sha1(Array("req1".utf8), secret) }

  /// SHA1("req2" || SKEY) XOR SHA1("req3" || S) — the 20-byte obfuscated
  /// infohash sent in the clear; the responder recovers SHA1("req2" || SKEY)
  /// and matches it against its torrents without exposing the infohash on
  /// the wire.
  public static func obfuscatedInfoHash(streamKey: [UInt8], secret: [UInt8]) -> [UInt8] {
    zip(sha1(Array("req2".utf8), streamKey), sha1(Array("req3".utf8), secret)).map(^)
  }

  private static func sha1(_ parts: [UInt8]...) -> [UInt8] {
    var data = Data()
    for part in parts { data.append(contentsOf: part) }
    return Array(Insecure.SHA1.hash(data: data))
  }
}

// MARK: - Initiator handshake

/// Thrown by `MSEHandshake.run` when the MSE handshake cannot complete.
public enum MSEHandshakeError: Error, Equatable, Sendable {
  /// The peer answered our DH key with a plaintext BT handshake
  /// (`0x13 "BitTorrent protocol"…`) — it does not speak MSE. Encrypted-only
  /// clients must drop the connection.
  case peerDoesNotSupportEncryption
  /// The peer's reply failed a cryptographic check (missing ENCRYPT(VC)
  /// resync pattern, invalid handshake contents, oversized padding, …).
  case handshakeFailed
  /// The peer selected an encryption method we did not offer
  /// (`crypto_select & 0x02 == 0`; we only offer RC4).
  case cryptoNotSelected
  /// The handshake did not complete within the configured timeout.
  case timedOut
}

/// A byte-stream transport for the MSE handshake (and, afterwards, the
/// RC4-encrypted wire protocol). `read` returns exactly `count` bytes.
public protocol MSEByteChannel: Sendable {
  func write(_ data: Data) async throws
  func read(_ count: Int) async throws -> Data
}

/// Optional: discard buffered incoming bytes (used by test fakes before a
/// close that would otherwise send RST with unread data).
extension MSEByteChannel { public func drain() async {} }

/// The result of a successful initiator MSE handshake: the two RC4 ciphers —
/// already past the 1024-byte keystream drop *and* the handshake exchange, so
/// their streams continue directly into the wire protocol — plus the peer's
/// decrypted 68-byte BitTorrent handshake.
public struct MSEHandshakeResult: Sendable {
  public let sendCipher: RC4
  public let recvCipher: RC4
  public let peerHandshakeBytes: Data

  public init(sendCipher: RC4, recvCipher: RC4, peerHandshakeBytes: Data) {
    self.sendCipher = sendCipher
    self.recvCipher = recvCipher
    self.peerHandshakeBytes = peerHandshakeBytes
  }
}

/// Initiator-side MSE handshake implementing the corrected wire format
/// (verified against libtorrent-rasterbar `bt_peer_connection.cpp` and
/// Transmission `handshake.cc`). This client always initiates and only offers
/// RC4 (`crypto_provide = 0x02`).
///
/// Wire flow:
///   1. send `[Ya 96][PadA 0-512]` (public key first)
///   2. receive `[Yb 96][PadB 0-512]` — a plaintext BT handshake here means
///      the peer does not support MSE and is rejected
///   3. `S = Yb^a mod p`; derive keys, build both RC4 ciphers, `drop(1024)`
///   4. send in the clear `[HASH("req1", S) 20][HASH("req2", SKEY) xor
///      HASH("req3", S) 20]`
///   5. send encrypted `[VC 8][crypto_provide 4 = 0x02][len(PadC) 2 = 0]
///      [len(IA) 2 = 68][IA 68]`
///   6. receive encrypted `[VC 8][crypto_select 4][len(PadD) 2][PadD]
///      [handshake 68]`, resyncing on `ENCRYPT(VC)` (PadB's length is unknown)
///   7. verify VC, `crypto_select & 0x02`, and the 68-byte handshake
///      (pstr + infohash); return the continuing ciphers + peer handshake.
public struct MSEHandshake: Sendable {
  public let infoHash: Data
  public let peerID: Data
  private let privateKey: [UInt8]

  /// - Parameters:
  ///   - infoHash: 20-byte torrent infohash (the MSE stream key).
  ///   - peerID: 20-byte client peer id, sent inside the obfuscated
  ///     BitTorrent handshake.
  ///   - privateKey: optional 96-byte DH private key. Defaults to a fresh
  ///     random key (`< p`, non-zero). Injectable for tests.
  public init(infoHash: Data, peerID: Data, privateKey: [UInt8]? = nil) {
    precondition(infoHash.count == 20, "infoHash must be 20 bytes")
    precondition(peerID.count == 20, "peerID must be 20 bytes")
    self.infoHash = infoHash
    self.peerID = peerID
    self.privateKey = privateKey ?? Self.generatePrivateKey()
  }

  /// The 96-byte public key for a private key: `g^a mod p` with `g = 2`.
  public static func publicKey(for privateKey: [UInt8]) -> [UInt8] {
    modPow([2], privateKey, MSEPrime.bytes)
  }

  /// Run the initiator handshake over `channel`. On success the returned
  /// ciphers are positioned exactly where the wire protocol continues
  /// (post-1024-drop and post-handshake). Throws `MSEHandshakeError.timedOut`
  /// if the handshake does not finish within `timeout`.
  public func run<Channel: MSEByteChannel>(over channel: Channel, timeout: Duration = .seconds(20))
    async throws -> MSEHandshakeResult
  {
    // The handshake runs as a child of the group so that a timeout
    // cancels it directly (an unstructured task would keep running and
    // the group would wait for it forever). The channel implementation
    // must be cancellation-cooperative (reads should throw on cancel)
    // for the timeout to interrupt a stalled peer.
    try await withThrowingTaskGroup(of: MSEHandshakeResult.self) { group in
      group.addTask { try await self.perform(over: channel) }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw MSEHandshakeError.timedOut
      }
      guard let result = try await group.next() else { throw MSEHandshakeError.timedOut }
      group.cancelAll()
      return result
    }
  }

  /// Run the RESPONDER handshake over `channel` (the role used for inbound
  /// connections: a peer initiated MSE and we reply). Mirrors the verified
  /// responder in the test fake: read [Ya 96], reply [Yb 96][PadB], derive
  /// mirrored keys, resync on `HASH("req1" || S)`, verify the obfuscated
  /// infohash, decrypt/verify the initiator's [VC][crypto_provide][PadC]
  /// [len(IA)][IA], and reply [VC][crypto_select][len(PadD)=0][IA]. On
  /// success the returned ciphers are positioned exactly where the wire
  /// protocol continues. Throws `MSEHandshakeError.timedOut` on timeout.
  public func accept<Channel: MSEByteChannel>(
    over channel: Channel, timeout: Duration = .seconds(20)
  ) async throws -> MSEHandshakeResult {
    try await withThrowingTaskGroup(of: MSEHandshakeResult.self) { group in
      group.addTask { try await self.performAccept(over: channel) }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw MSEHandshakeError.timedOut
      }
      guard let result = try await group.next() else { throw MSEHandshakeError.timedOut }
      group.cancelAll()
      return result
    }
  }

  // MARK: - Handshake steps

  /// The responder-side handshake (inbound). The initiator's steps are
  /// mirrored: we read their public key, send ours, derive the shared
  /// secret with OUR private key, resync on the sync hash, verify the
  /// obfuscated infohash, and reply with the encrypted handshake.
  private func performAccept<Channel: MSEByteChannel>(over channel: Channel) async throws
    -> MSEHandshakeResult
  {
    // 1. Read the initiator's public key (exactly 96 bytes). A plaintext
    //    BT handshake reply means the peer does not speak MSE — drop it
    //    (encrypted-only policy).
    let first20 = Array(try await channel.read(20))
    try Task.checkCancellation()
    if first20.count == 20, first20.first == 19,
      Data(first20.dropFirst()) == Data("BitTorrent protocol".utf8)
    {
      throw MSEHandshakeError.peerDoesNotSupportEncryption
    }
    let ya = first20 + Array(try await channel.read(76))
    try Task.checkCancellation()
    precondition(ya.count == 96, "MSEByteChannel.read must return exactly count bytes")

    // 2. Our key pair; reply [Yb 96][PadB 0-512].
    let yb = Self.publicKey(for: privateKey)
    let padB = Self.randomBytes(Int.random(in: 0...512))
    try await channel.write(Data(yb + padB))
    try Task.checkCancellation()

    // 3. DH secret; keys MIRRORED: our send = initiator recv, our recv =
    //    initiator send.
    let secret = modPow(ya, privateKey, MSEPrime.bytes)
    let keys = MSE.deriveKeys(secret: secret, streamKey: Array(infoHash))
    var sendCipher = RC4(key: keys.recv)
    var recvCipher = RC4(key: keys.send)
    sendCipher.drop(1024)
    recvCipher.drop(1024)

    // 4. Resync on HASH('req1', S): the incoming clear stream is
    //    [PadA][sync 20][obfuscated 20][encrypted...]; PadA's length is
    //    unknown, so find the sync hash.
    let syncHash = MSE.syncHash(secret: secret)
    var reader = BufferedReader(channel: channel)
    let padLen = try await reader.scanFor(pattern: syncHash, maxPad: 512)
    _ = try reader.consume(padLen + 20)  // PadA + the sync hash itself

    // 5. Verify the obfuscated infohash.
    let obfuscated = Array(try await reader.read(20))
    let expected = MSE.obfuscatedInfoHash(streamKey: Array(infoHash), secret: secret)
    guard obfuscated == expected else { throw MSEHandshakeError.handshakeFailed }

    // 6. Read + verify the encrypted section:
    //    [VC 8][crypto_provide 4][len(PadC) 2][PadC][len(IA) 2][IA 68].
    var header = Array(try await reader.read(14))
    recvCipher.stream(&header)
    guard Array(header.prefix(8)) == MSE.vc else { throw MSEHandshakeError.handshakeFailed }
    guard Self.be32(Array(header[8..<12])) & MSE.cryptoProvideRC4 != 0 else {
      throw MSEHandshakeError.cryptoNotSelected
    }
    let lenPadC = Int(header[12]) << 8 | Int(header[13])
    guard lenPadC <= 512 else { throw MSEHandshakeError.handshakeFailed }
    var padC = Array(try await reader.read(lenPadC))
    recvCipher.stream(&padC)
    var lenIA = Array(try await reader.read(2))
    recvCipher.stream(&lenIA)
    let iaLen = Int(lenIA[0]) << 8 | Int(lenIA[1])
    guard iaLen == 68 else { throw MSEHandshakeError.handshakeFailed }
    var ia = Array(try await reader.read(iaLen))
    recvCipher.stream(&ia)
    guard ia.count == 68, ia[0] == 19, Array(ia[1..<20]) == Array("BitTorrent protocol".utf8),
      Array(ia[28..<48]) == Array(infoHash)
    else { throw MSEHandshakeError.handshakeFailed }

    // 7. Reply: [VC 8][crypto_select 4][len(PadD) 2 = 0][IA 68], encrypted
    //    with our send stream. (The initiator resyncs on ENCRYPT(VC).)
    var reply =
      MSE.vc + Self.be32Bytes(MSE.cryptoProvideRC4) + [0, 0]
      + Self.btHandshake(infoHash: infoHash, peerID: peerID)
    sendCipher.stream(&reply)
    try await channel.write(Data(reply))
    try Task.checkCancellation()

    return MSEHandshakeResult(
      sendCipher: sendCipher, recvCipher: recvCipher, peerHandshakeBytes: Data(ia))
  }

  private func perform<Channel: MSEByteChannel>(over channel: Channel) async throws
    -> MSEHandshakeResult
  {
    // 1. [Ya 96][PadA 0-512] — public key first.
    let publicKey = Self.publicKey(for: privateKey)
    let padA = Self.randomBytes(Int.random(in: 0...512))
    try await channel.write(Data(publicKey + padA))
    try Task.checkCancellation()

    // 2. [Yb 96], with a fast path for a plaintext BT handshake reply.
    let first20 = try await channel.read(20)
    try Task.checkCancellation()
    if first20.count == 20, first20.first == 19,
      Data(first20.dropFirst()) == Data("BitTorrent protocol".utf8)
    {
      throw MSEHandshakeError.peerDoesNotSupportEncryption
    }
    let yb = Array(first20) + Array(try await channel.read(76))
    try Task.checkCancellation()
    precondition(yb.count == 96, "MSEByteChannel.read must return exactly count bytes")

    // 3. DH shared secret.
    let secret = modPow(yb, privateKey, MSEPrime.bytes)

    // 4. Keys + ciphers; drop the first 1024 keystream bytes.
    let keys = MSE.deriveKeys(secret: secret, streamKey: Array(infoHash))
    var sendCipher = RC4(key: keys.send)
    var recvCipher = RC4(key: keys.recv)
    sendCipher.drop(1024)
    recvCipher.drop(1024)

    // 5. Clear sync section.
    let sync =
      MSE.syncHash(secret: secret)
      + MSE.obfuscatedInfoHash(streamKey: Array(infoHash), secret: secret)
    try await channel.write(Data(sync))
    try Task.checkCancellation()

    // 6. Encrypted section: [VC][crypto_provide][len(PadC)=0][len(IA)=68][IA].
    var out = MSE.vc
    out += Self.be32Bytes(MSE.cryptoProvideRC4)
    out += [0, 0]
    out += [0, 68]
    out += Self.btHandshake(infoHash: infoHash, peerID: peerID)
    sendCipher.stream(&out)
    try await channel.write(Data(out))
    try Task.checkCancellation()

    // 7. Encrypted reply. PadB's length (0-512) is unknown, so resync the
    //    way libtorrent/Transmission do: encrypt 8 zero bytes with the recv
    //    stream and scan the raw incoming bytes for that ENCRYPT(VC)
    //    pattern. The recv cipher is left exactly 8 bytes into the stream,
    //    matching the position where the remaining ciphertext continues.
    var expectedVC = MSE.vc
    recvCipher.stream(&expectedVC)

    var reader = BufferedReader(channel: channel)
    let padLength = try await reader.scanFor(pattern: expectedVC, maxPad: 512)
    _ = try reader.consume(padLength + 8)  // drop PadB + VC

    var field = Array(try await reader.read(6))  // crypto_select (4) + len(PadD) (2)
    recvCipher.stream(&field)
    let cryptoSelect = Self.be32(Array(field[0..<4]))
    guard cryptoSelect & MSE.cryptoProvideRC4 != 0 else {
      throw MSEHandshakeError.cryptoNotSelected
    }
    let lenPadD = Int(field[4]) << 8 | Int(field[5])
    guard lenPadD <= 512 else { throw MSEHandshakeError.handshakeFailed }
    var padD = Array(try await reader.read(lenPadD))
    recvCipher.stream(&padD)

    var peerHandshake = Array(try await reader.read(68))
    recvCipher.stream(&peerHandshake)

    // 8. Verify the decrypted handshake: pstr + our infohash.
    guard peerHandshake.count == 68, peerHandshake[0] == 19,
      Array(peerHandshake[1..<20]) == Array("BitTorrent protocol".utf8),
      Array(peerHandshake[28..<48]) == Array(infoHash)
    else { throw MSEHandshakeError.handshakeFailed }

    return MSEHandshakeResult(
      sendCipher: sendCipher, recvCipher: recvCipher, peerHandshakeBytes: Data(peerHandshake))
  }

  // MARK: - Helpers

  /// The 68-byte BitTorrent handshake carried inside MSE's encrypted IA.
  /// Reserved byte 5 (index 25) bit 0x10 advertises BEP 10 extension
  /// support — REQUIRED before any extended message (id 20) is sent; peers
  /// that don't see the bit treat an extended message as a protocol
  /// violation and drop the connection.
  private static func btHandshake(infoHash: Data, peerID: Data) -> [UInt8] {
    var reserved = [UInt8](repeating: 0, count: 8)
    reserved[5] = 0x10  // BEP 10 extended messaging
    return [19] + Array("BitTorrent protocol".utf8) + reserved + Array(infoHash) + Array(peerID)
  }

  private static func be32(_ bytes: [UInt8]) -> UInt32 {
    UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
  }

  private static func be32Bytes(_ value: UInt32) -> [UInt8] {
    [
      UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
      UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value),
    ]
  }

  private static func randomBytes(_ count: Int) -> [UInt8] {
    (0..<count).map { _ in UInt8.random(in: .min ... .max) }
  }

  /// A 96-byte private key `< p` and non-zero (the MSE spec requires both;
  /// retry until a valid draw).
  private static func generatePrivateKey() -> [UInt8] {
    while true {
      let key = randomBytes(96)
      if key != [UInt8](repeating: 0, count: 96), key.lexicographicallyPrecedes(MSEPrime.bytes) {
        return key
      }
    }
  }
}

/// Buffered reader over an `MSEByteChannel` used during the handshake to scan
/// for resync patterns without knowing the pad length in advance.
private struct BufferedReader {
  let channel: any MSEByteChannel
  private var buffer = Data()

  /// Read exactly `count` bytes (from the buffer first, then the channel).
  mutating func read(_ count: Int) async throws -> Data {
    while buffer.count < count {
      buffer.append(try await channel.read(1))
      try Task.checkCancellation()
    }
    let out = Data(buffer.prefix(count))
    buffer.removeFirst(count)
    return out
  }

  /// Scan the incoming stream for `pattern` after at most `maxPad` leading
  /// pad bytes. Returns the offset of the pattern; the pad bytes before it
  /// stay in the buffer for the caller to consume. Throws
  /// `MSEHandshakeError.handshakeFailed` if the pattern is not found within
  /// the pad bound (the peer's stream is not a valid MSE reply).
  mutating func scanFor(pattern: [UInt8], maxPad: Int) async throws -> Int {
    let needle = Data(pattern)
    while true {
      if let range = buffer.range(of: needle) { return range.lowerBound }
      if buffer.count > maxPad + pattern.count { throw MSEHandshakeError.handshakeFailed }
      buffer.append(try await channel.read(1))
      try Task.checkCancellation()
    }
  }

  /// Drop the first `count` buffered bytes (padding, already-scanned data).
  mutating func consume(_ count: Int) throws -> Data {
    guard count <= buffer.count else { throw MSEHandshakeError.handshakeFailed }
    let out = Data(buffer.prefix(count))
    buffer.removeFirst(count)
    return out
  }
}
