import Foundation
@testable import Torrent

// MARK: - POSIX-socket byte channel

/// A blocking `MSEByteChannel` over a POSIX socket fd, used by `FakeWirePeer`
/// on its connection thread. `read` returns exactly `count` bytes, buffering
/// partial reads; every blocking read polls with a 200ms tick so the shared
/// stop flag (and an EOF from the client closing) is observed promptly.
final class FDByteChannel: MSEByteChannel, @unchecked Sendable {
    private let fd: Int32
    private let stop: WirePeerStopFlag
    private var buffer = Data()

    init(fd: Int32, stop: WirePeerStopFlag) {
        self.fd = fd
        self.stop = stop
    }

    func write(_ data: Data) async throws {
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < data.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), data.count - sent)
                if n <= 0 { throw FakeWirePeerError.closed }
                sent += n
            }
        }
    }

    func read(_ count: Int) async throws -> Data {
        while buffer.count < count {
            buffer.append(try readByte())
        }
        let out = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return out
    }

    /// Blocking single-byte read (poll + read), returning exactly one byte.
    private func readByte() throws -> UInt8 {
        while true {
            if stop.isSet { throw FakeWirePeerError.closed }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, 200)
            if pr < 0 { throw FakeWirePeerError.closed }
            if pr == 0 { continue }  // poll tick elapsed; re-check the stop flag
            var byte: UInt8 = 0
            let n = Darwin.read(fd, &byte, 1)
            if n <= 0 { throw FakeWirePeerError.closed }
            return byte
        }
    }
}

// MARK: - Fake MSE + wire-protocol peer

/// In-process fake peer for `PeerConnection` tests: a POSIX-socket listener on
/// 127.0.0.1:0 that accepts one connection, runs the MSE responder handshake
/// (via `FakeMSEPeer.responderHandshake`), then speaks the RC4-encrypted wire
/// protocol: sends an all-zero bitfield + unchoke, answers `request` messages
/// with `piece` data from an in-memory buffer, and records every received
/// message for assertions.
///
/// Implemented on raw BSD sockets because `NWListener` fails with EINVAL on
/// every bind in CLI test processes (see `FakeTracker` for the same pattern).
final class FakeWirePeer: @unchecked Sendable {
    enum Mode {
        case encrypted
        case plaintext   // answer the DH exchange with a plaintext BT handshake
    }

    /// What the fake observed, published when the connection handler exits.
    struct Result: Sendable {
        let receivedHandshake: Data
        let receivedMessages: [WireMessage]
    }

    /// Length prefix the fake sends in `oversizedFrame` mode (10 MiB — far
    /// over the 2 MiB wire-protocol cap).
    static let oversizedFrameLength = 10 * 1024 * 1024

    let port: UInt16
    let pieceCount: Int
    let pieceLength: Int
    /// Deterministic in-memory piece buffer the fake serves `request`s from.
    let pieceData: Data
    let infoHash: [UInt8]
    let peerID: [UInt8]

    /// Messages received so far (thread-safe; live-updates as they arrive).
    var receivedMessages: [WireMessage] { lock.withLock { _receivedMessages } }

    private let mode: Mode
    private let oversizedFrame: Bool
    private let listenFD: Int32
    private let acceptThread: Thread
    private let stopFlag = WirePeerStopFlag()
    private let lock = NSLock()

    private var _receivedMessages: [WireMessage] = []
    private var _receivedHandshake = Data()
    private var _result: Result?

    init(infoHash: [UInt8], peerID: [UInt8], pieceCount: Int = 4, pieceLength: Int = 16_384,
         mode: Mode = .encrypted, oversizedFrame: Bool = false) throws {
        self.infoHash = infoHash
        self.peerID = peerID
        self.pieceCount = pieceCount
        self.pieceLength = pieceLength
        self.mode = mode
        self.oversizedFrame = oversizedFrame
        self.pieceData = Data((0..<(pieceCount * pieceLength)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })

        // socket/bind/listen on 127.0.0.1:0 (ephemeral).
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FakeWirePeerError.posix(errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // ephemeral
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                bind(fd, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw FakeWirePeerError.posix(errno)
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw FakeWirePeerError.posix(errno)
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var bound = sockaddr_in()
        let nameResult = withUnsafeMutablePointer(to: &bound) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                getsockname(fd, sp, &len)
            }
        }
        guard nameResult == 0 else {
            close(fd)
            throw FakeWirePeerError.posix(errno)
        }
        let assigned = UInt16(bigEndian: bound.sin_port)
        guard assigned != 0 else {
            close(fd)
            throw FakeWirePeerError.noPort
        }

        self.listenFD = fd
        self.port = assigned

        // Accept loop on a dedicated thread (poll keeps the stop flag
        // responsive). The closure captures a weak box instead of self; the
        // box is populated right after start, well before the first poll tick.
        let stop = self.stopFlag
        let acceptFD = fd
        let box = WirePeerBox()
        self.acceptThread = Thread {
            while !stop.isSet {
                var pfd = pollfd(fd: acceptFD, events: Int16(POLLIN), revents: 0)
                let pr = poll(&pfd, 1, 200)
                if pr <= 0 { continue }
                var clientAddr = sockaddr_in()
                var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let client = withUnsafeMutablePointer(to: &clientAddr) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                        accept(acceptFD, sp, &clientLen)
                    }
                }
                if client >= 0 {
                    guard let peer = box.peer else {
                        close(client)
                        continue
                    }
                    Thread.detachNewThread { peer.handleConnection(client) }
                }
            }
            close(acceptFD)
        }
        acceptThread.name = "FakeWirePeer.accept"
        acceptThread.start()
        box.peer = self
    }

    deinit {
        stopFlag.set()
        acceptThread.cancel()
    }

    func stop() {
        stopFlag.set()
    }

    /// Block until the connection handler exits (bounded by `timeout`) and
    /// return what the fake observed. Cancellation-cooperative.
    func waitForResult(timeout: Duration = .seconds(5)) async throws -> Result {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            if let result = lock.withLock({ _result }) { return result }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw FakeWirePeerError.timedOut
    }

    // MARK: - Connection handling

    /// Runs on the connection thread (detached by the accept loop): wraps the
    /// fd in a blocking byte channel and drives the async peer session on the
    /// cooperative pool, waiting here until it completes.
    private func handleConnection(_ fd: Int32) {
        defer { close(fd) }
        let channel = FDByteChannel(fd: fd, stop: stopFlag)
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                try await self.serve(channel)
            } catch {
                // Client closed or a protocol error — the result is published
                // from whatever was recorded so far.
            }
            self.publishResult()
            sem.signal()
        }
        sem.wait()
    }

    /// The MSE responder handshake followed by the wire protocol (or the
    /// one-shot plaintext/oversized-frame behaviors).
    private func serve(_ channel: FDByteChannel) async throws {
        if mode == .plaintext {
            // Answer the DH exchange with a plaintext BT handshake and stop:
            // an MSE-only client must drop us immediately.
            _ = try await FakeMSEPeer.responderHandshake(over: channel, infoHash: infoHash,
                                                         peerID: peerID, mode: .plaintext)
            return
        }

        let handshake = try await FakeMSEPeer.responderHandshake(over: channel, infoHash: infoHash, peerID: peerID)
        lock.withLock { _receivedHandshake = handshake.receivedHandshake }
        var sendCipher = handshake.sendCipher
        var recvCipher = handshake.recvCipher

        if oversizedFrame {
            // A single frame with a 10 MiB length prefix (and no payload):
            // the client must reject it from the prefix alone.
            var prefix = Self.be32Bytes(UInt32(Self.oversizedFrameLength))
            sendCipher.stream(&prefix)
            try await channel.write(Data(prefix))
            return
        }

        // Greet: all-zero bitfield + unchoke (politeness, no uploads).
        try await sendFrame(.bitfield(Data(repeating: 0, count: (pieceCount + 7) / 8)),
                            over: channel, cipher: &sendCipher)
        try await sendFrame(.unchoke, over: channel, cipher: &sendCipher)

        // Serve requests from the in-memory buffer until the client closes.
        while true {
            let message = try await readFrame(from: channel, cipher: &recvCipher)
            lock.withLock { _receivedMessages.append(message) }
            if case .request(let index, let begin, let length) = message {
                let start = index * pieceLength + begin
                let data = pieceData.subdata(in: start..<(start + length))
                try await sendFrame(.piece(index: index, begin: begin, data: data),
                                    over: channel, cipher: &sendCipher)
            }
        }
    }

    private func sendFrame(_ message: WireMessage, over channel: FDByteChannel, cipher: inout RC4) async throws {
        var bytes = Array(WireCodec.encode(message))
        cipher.stream(&bytes)
        try await channel.write(Data(bytes))
    }

    private func readFrame(from channel: FDByteChannel, cipher: inout RC4) async throws -> WireMessage {
        var prefix = Array(try await channel.read(4))
        cipher.stream(&prefix)
        let length = (Int(prefix[0]) << 24) | (Int(prefix[1]) << 16) | (Int(prefix[2]) << 8) | Int(prefix[3])
        guard length <= WireCodec.maxPayloadLength else {
            throw WireCodecError.payloadTooLarge(length)
        }
        var payload: [UInt8] = length > 0 ? Array(try await channel.read(length)) : []
        cipher.stream(&payload)
        var framed = Data()
        framed.append(contentsOf: prefix)
        framed.append(contentsOf: payload)
        return try WireCodec.decode(framed)
    }

    private func publishResult() {
        lock.withLock {
            guard _result == nil else { return }
            _result = Result(receivedHandshake: _receivedHandshake, receivedMessages: _receivedMessages)
        }
    }

    private static func be32Bytes(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 24),
         UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8),
         UInt8(truncatingIfNeeded: value)]
    }
}

enum FakeWirePeerError: Error {
    case timedOut
    case closed
    case noPort
    case posix(Int32)
}

/// Atomic stop flag for the accept loop (mirrors FakeTracker's private one).
/// Named distinctly to avoid colliding with other test support files' StopFlag.
final class WirePeerStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var isSet: Bool { lock.withLock { flag } }
}

/// Weak reference to the peer for the accept thread (breaks the
/// thread → peer → thread retain cycle).
private final class WirePeerBox: @unchecked Sendable {
    weak var peer: FakeWirePeer?
}
