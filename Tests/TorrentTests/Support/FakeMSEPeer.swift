import Foundation
@testable import Torrent

// MARK: - In-memory loopback pipe

/// In-memory, unbounded byte pipe connecting the MSE initiator to the fake
/// responder within one test process. Both ends are `MSEByteChannel`s.
final class LoopbackPipe: @unchecked Sendable {
    let initiator: LoopbackPipeEndpoint
    let responder: LoopbackPipeEndpoint

    init() {
        let a = LoopbackPipeEndpoint()
        let b = LoopbackPipeEndpoint()
        a.peer = b
        b.peer = a
        initiator = a
        responder = b
    }
}

/// One end of a `LoopbackPipe`. `write` appends to the peer's buffer; `read`
/// blocks until `count` bytes are buffered and returns exactly `count` bytes.
/// Reads are cancellation-cooperative: cancelling the awaiting task resumes
/// the read with `CancellationError` (the MSE timeout path relies on this).
final class LoopbackPipeEndpoint: MSEByteChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var waiters: [Waiter] = []
    fileprivate weak var peer: LoopbackPipeEndpoint?

    func write(_ data: Data) async throws {
        guard let peer else { throw LoopbackPipeError.disconnected }
        peer.append(data)
    }

    func read(_ count: Int) async throws -> Data {
        while true {
            if let out = take(count) { return out }
            try Task.checkCancellation()
            let waiter = Waiter(count: count)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    waiter.attach(cont)
                    if enqueue(waiter) { waiter.resume() }
                }
            } onCancel: {
                waiter.cancel()
            }
        }
    }

    /// Non-async so NSLock's async-context restriction does not apply.
    private func take(_ count: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard buffer.count >= count else { return nil }
        let out = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return out
    }

    /// Add the waiter to the wait list. Returns true when the data it wants is
    /// already buffered (caller resumes it immediately), false once enqueued.
    private func enqueue(_ waiter: Waiter) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if waiter.isDone { return false }          // cancelled concurrently
        if buffer.count >= waiter.count { return true }
        waiters.append(waiter)
        return false
    }

    fileprivate func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        let w = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in w { waiter.resume() }
    }
}

/// One blocked `read`; safe against the enqueue path and the cancellation
/// handler racing each other (guarded by its own lock, `done` is sticky).
private final class Waiter: @unchecked Sendable {
    let count: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var done = false

    init(count: Int) { self.count = count }

    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    func attach(_ cont: CheckedContinuation<Void, Error>) {
        lock.lock()
        if done {
            lock.unlock()
            cont.resume(throwing: CancellationError())
            return
        }
        continuation = cont
        lock.unlock()
    }

    func resume() {
        lock.lock()
        guard !done, let cont = continuation else { lock.unlock(); return }
        done = true
        continuation = nil
        lock.unlock()
        cont.resume()
    }

    func cancel() {
        lock.lock()
        guard !done, let cont = continuation else { lock.unlock(); return }
        done = true
        continuation = nil
        lock.unlock()
        cont.resume(throwing: CancellationError())
    }
}

enum LoopbackPipeError: Error {
    case disconnected
}

/// Buffered reader over an `MSEByteChannel` for the responder's resync:
/// accumulates 1-byte reads so it can find `HASH('req1', S)` without knowing
/// the length of PadA in advance.
private struct BufferedChannelReader {
    let channel: any MSEByteChannel
    private var buffer = Data()

    /// Read exactly `count` bytes (from the buffer first, then the channel).
    mutating func read(_ count: Int) async throws -> Data {
        while buffer.count < count {
            buffer.append(try await channel.read(1))
        }
        let out = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return out
    }

    /// Scan the incoming stream for `pattern` after at most `maxScan` leading
    /// pad bytes. Returns the pad length preceding the match; the pattern and
    /// everything after it stay in the buffer.
    mutating func scanFor(pattern: [UInt8], maxScan: Int) async throws -> Int {
        let needle = Data(pattern)
        while true {
            if let range = buffer.range(of: needle) {
                return range.lowerBound
            }
            if buffer.count > maxScan + pattern.count {
                throw MSEHandshakeError.handshakeFailed
            }
            buffer.append(try await channel.read(1))
        }
    }
}

// MARK: - Fake MSE responder

/// In-process MSE *responder* used to cross-check the initiator handshake.
/// Runs over the same `MSEByteChannel` abstraction as the client and is an
/// independent implementation: mirrored key derivation, sync-hash resync,
/// VC/crypto_provide verification, and the encrypted 68-byte handshake.
struct FakeMSEPeer {
    enum Mode {
        case encrypted
        case plaintext              // answer with a plaintext BT handshake
        case badVC                  // encrypt the reply with a wrong key
        case cryptoSelectPlaintext  // select plaintext (0x01) instead of RC4
        case mismatchedInfoHash     // its own handshake uses a different infohash
    }

    struct Result: Sendable {
        let receivedPublicKey: [UInt8]   // Ya as received from the initiator
        let sendCipher: RC4              // post-handshake, continuing
        let recvCipher: RC4              // post-handshake, continuing
        let peerHandshake: Data          // the 68-byte handshake this peer sent
        let receivedHandshake: Data      // the initiator's 68-byte handshake
        let receivedByte: UInt8          // decrypted post-handshake byte from the initiator
    }

    static let postHandshakeByte: UInt8 = 0x42
    static let replyByte: UInt8 = 0x99

    /// Responder-side MSE handshake: steps 1-7 (everything before the
    /// post-handshake byte exchange). Returns the continuing RC4 ciphers
    /// (positioned exactly where the wire protocol resumes), the initiator's
    /// decrypted 68-byte handshake, and the initiator's public key.
    static func responderHandshake(
        over channel: MSEByteChannel,
        infoHash: [UInt8],
        peerID: [UInt8],
        mode: Mode = .encrypted
    ) async throws -> (sendCipher: RC4, recvCipher: RC4, receivedHandshake: Data, receivedPublicKey: [UInt8]) {
        precondition(infoHash.count == 20, "infoHash must be 20 bytes")
        precondition(peerID.count == 20, "peerID must be 20 bytes")
        // 1. Read the initiator's public key (exactly 96 bytes).
        let ya = Array(try await channel.read(96))

        // Plaintext mode: answer with a standard BT handshake instead of
        // [Yb][PadB] — an encrypted-only client must drop us. Drain the
        // client's unread PadA first so close() sends a clean FIN: closing
        // with unread data sends RST, which can discard the handshake we just
        // sent (flaky under parallel load).
        if mode == .plaintext {
            try await channel.write(Data(btHandshake(infoHash: infoHash, peerID: peerID)))
            await channel.drain()
            return (RC4(key: []), RC4(key: []), Data(), ya)
        }

        // 2. Our key pair; reply [Yb 96][PadB 0-512].
        let privateKey = randomPrivateKey()
        let yb = modPow([2], privateKey, MSEPrime.bytes)
        let padB = randomBytes(Int.random(in: 0...512))
        try await channel.write(Data(yb + padB))

        // 3. DH secret; keys mirrored (our send = initiator recv).
        let secret = modPow(ya, privateKey, MSEPrime.bytes)
        let keys = MSE.deriveKeys(secret: secret, streamKey: infoHash)
        var sendCipher = RC4(key: keys.recv)
        var recvCipher = RC4(key: keys.send)
        sendCipher.drop(1024)
        recvCipher.drop(1024)

        // 4. Resync on HASH('req1', S): the incoming clear stream is
        //    [PadA][sync 20][obfuscated 20][encrypted...]; PadA's length is
        //    unknown, so find the sync hash.
        let syncHash = MSE.syncHash(secret: secret)
        var reader = BufferedChannelReader(channel: channel)
        let padLen = try await reader.scanFor(pattern: syncHash, maxScan: 512)
        // Consume PadA plus the matched 20-byte sync hash: scanFor leaves them
        // in the buffer, and the next 20 bytes must be the obfuscated infohash.
        _ = try await reader.read(padLen + 20)

        // 5. Verify the obfuscated infohash.
        let obfuscated = Array(try await reader.read(20))
        let expectedObfuscated = MSE.obfuscatedInfoHash(streamKey: infoHash, secret: secret)
        guard obfuscated == expectedObfuscated else { throw MSEHandshakeError.handshakeFailed }

        // 6. Read + verify the encrypted section:
        //    [VC 8][crypto_provide 4][len(PadC) 2][PadC][len(IA) 2][IA 68].
        var header = Array(try await reader.read(14))
        recvCipher.stream(&header)
        guard Array(header.prefix(8)) == MSE.vc else { throw MSEHandshakeError.handshakeFailed }
        guard be32(Array(header[8..<12])) & MSE.cryptoProvideRC4 != 0 else {
            throw MSEHandshakeError.handshakeFailed
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
        guard ia.count == 68, ia[0] == 19,
              Array(ia[1..<20]) == Array("BitTorrent protocol".utf8),
              Array(ia[28..<48]) == infoHash else {
            throw MSEHandshakeError.handshakeFailed
        }
        let receivedHandshake = Data(ia)

        // 7. Reply: [VC 8][crypto_select 4][len(PadD) 2 = 0][handshake 68],
        //    encrypted with our send stream.
        let handshakeInfoHash = mode == .mismatchedInfoHash ? wrongInfoHash : infoHash
        let myHandshake = btHandshake(infoHash: handshakeInfoHash, peerID: peerID)
        let select: UInt32 = mode == .cryptoSelectPlaintext ? MSE.cryptoProvidePlaintext : MSE.cryptoProvideRC4
        var reply = MSE.vc + be32Bytes(select) + [0, 0] + myHandshake

        if mode == .badVC {
            // Encrypt with keys derived from a *different* secret so the
            // initiator's ENCRYPT(VC) scan cannot succeed...
            let wrongKeys = MSE.deriveKeys(secret: randomBytes(96), streamKey: infoHash)
            var wrongCipher = RC4(key: wrongKeys.recv)
            wrongCipher.drop(1024)
            wrongCipher.stream(&reply)
            // ...and pad the reply past the initiator's 512-byte scan bound so
            // it fails fast instead of waiting for more data.
            reply += randomBytes(520)
        } else {
            sendCipher.stream(&reply)
        }
        try await channel.write(Data(reply))

        return (sendCipher, recvCipher, receivedHandshake, ya)
    }

    static func run(
        over channel: MSEByteChannel,
        infoHash: [UInt8],
        peerID: [UInt8],
        mode: Mode = .encrypted
    ) async throws -> Result {
        let handshake = try await responderHandshake(over: channel, infoHash: infoHash, peerID: peerID, mode: mode)
        var sendCipher = handshake.sendCipher
        var recvCipher = handshake.recvCipher

        // The 68-byte handshake this peer sent (empty in plaintext mode).
        var myHandshake: [UInt8] = []
        if mode != .plaintext {
            let handshakeInfoHash = mode == .mismatchedInfoHash ? wrongInfoHash : infoHash
            myHandshake = btHandshake(infoHash: handshakeInfoHash, peerID: peerID)
        }

        // 8. (encrypted mode only) post-handshake byte roundtrip: proves the
        //    two RC4 streams on both sides are aligned.
        var receivedByte: UInt8 = 0
        if mode == .encrypted {
            var reader = BufferedChannelReader(channel: channel)
            var encrypted = Array(try await reader.read(1))
            recvCipher.stream(&encrypted)
            guard encrypted == [postHandshakeByte] else { throw MSEHandshakeError.handshakeFailed }
            receivedByte = encrypted[0]
            var out: [UInt8] = [replyByte]
            sendCipher.stream(&out)
            try await channel.write(Data(out))
        }

        return Result(receivedPublicKey: handshake.receivedPublicKey, sendCipher: sendCipher, recvCipher: recvCipher,
                      peerHandshake: Data(myHandshake), receivedHandshake: handshake.receivedHandshake,
                      receivedByte: receivedByte)
    }

    // MARK: - Helpers

    private static let wrongInfoHash = hex("000102030405060708090a0b0c0d0e0f10111213")

    private static func btHandshake(infoHash: [UInt8], peerID: [UInt8]) -> [UInt8] {
        // BEP 10 extension support (reserved byte 5, bit 0x10) — a modern
        // client advertises it; the test fixture mirrors production.
        var reserved = [UInt8](repeating: 0, count: 8)
        reserved[5] = 0x10
        return [19] + Array("BitTorrent protocol".utf8) + reserved + infoHash + peerID
    }

    private static func be32(_ bytes: [UInt8]) -> UInt32 {
        UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    private static func be32Bytes(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 24),
         UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8),
         UInt8(truncatingIfNeeded: value)]
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        (0..<count).map { _ in UInt8.random(in: .min ... .max) }
    }

    private static func randomPrivateKey() -> [UInt8] {
        while true {
            let key = randomBytes(96)
            if key != [UInt8](repeating: 0, count: 96), key.lexicographicallyPrecedes(MSEPrime.bytes) {
                return key
            }
        }
    }

    private static func hex(_ s: String) -> [UInt8] {
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
}
