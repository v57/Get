import Foundation
import Network

/// Errors thrown by `PeerConnection`.
public enum PeerConnectionError: Error, Equatable, Sendable {
    /// The TCP connection could not be established.
    case connectFailed(String)
    /// The MSE handshake failed a cryptographic or protocol check.
    case handshakeFailed
    /// A connect or read operation exceeded its timeout.
    case timedOut
    /// The connection is closed (or was never opened).
    case closed
    /// The peer answered with a plaintext BitTorrent handshake, or plaintext
    /// fallback was requested (v1 is MSE-only).
    case peerDoesNotSupportEncryption
}

/// One outbound peer connection: TCP connect, MSE handshake, then the
/// RC4-encrypted wire protocol on top.
///
/// The RC4 ciphers returned by `MSEHandshake.run` continue directly into the
/// wire protocol — nothing is re-keyed or re-dropped. Every wire frame is the
/// 4-byte big-endian length prefix + payload, all encrypted.
public actor PeerConnection {
    private let host: String
    private let port: UInt16
    private let infoHash: Data
    private let ourPeerID: Data
    private let encryptedOnly: Bool
    private let connectTimeout: Duration
    private let readTimeout: Duration

    private var connection: NWConnection?
    private var channel: NWByteChannel?
    private var sendCipher = RC4(key: [])
    private var recvCipher = RC4(key: [])
    private var remotePeerID = Data()
    private var closed = false
    private var started = false

    public init(host: String, port: UInt16, infoHash: Data, peerID: Data,
                encryptedOnly: Bool = true,
                connectTimeout: Duration = .seconds(20),
                readTimeout: Duration = .seconds(90)) {
        precondition(infoHash.count == 20, "infoHash must be 20 bytes")
        precondition(peerID.count == 20, "peerID must be 20 bytes")
        self.host = host
        self.port = port
        self.infoHash = infoHash
        self.ourPeerID = peerID
        self.encryptedOnly = encryptedOnly
        self.connectTimeout = connectTimeout
        self.readTimeout = readTimeout
    }

    /// The remote peer's 20-byte peer id, extracted from bytes 48..<68 of its
    /// decrypted 68-byte BitTorrent handshake. Empty until `start()` succeeds.
    public var peerID: Data { remotePeerID }

    /// Connect over TCP, run the MSE handshake, and record the remote peer id.
    /// On any failure the connection is torn down and the error rethrown.
    public func start() async throws {
        guard encryptedOnly else {
            // v1 is MSE-only; plaintext fallback is future work.
            throw PeerConnectionError.peerDoesNotSupportEncryption
        }
        guard !closed, !started else { throw PeerConnectionError.closed }

        let connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: NWEndpoint.Port(rawValue: port)!,
                                      using: .tcp)
        let channel = NWByteChannel(connection: connection)
        self.connection = connection
        self.channel = channel

        let queue = DispatchQueue(label: "Torrent.PeerConnection.\(host):\(port)")
        do {
            try await awaitConnected(connection, queue: queue, timeout: connectTimeout)
        } catch let error as PeerConnectionError {
            channel.close()
            throw error
        } catch is CancellationError {
            channel.close()
            throw CancellationError()
        } catch {
            channel.close()
            throw PeerConnectionError.connectFailed(String(describing: error))
        }

        do {
            let result = try await MSEHandshake(infoHash: infoHash, peerID: ourPeerID)
                .run(over: channel, timeout: connectTimeout)
            sendCipher = result.sendCipher
            recvCipher = result.recvCipher
            let handshakeBytes = result.peerHandshakeBytes
            guard handshakeBytes.count == Handshake.length else {
                throw PeerConnectionError.handshakeFailed
            }
            remotePeerID = handshakeBytes.subdata(in: 48..<68)
        } catch let error as MSEHandshakeError {
            channel.close()
            switch error {
            case .peerDoesNotSupportEncryption:
                throw PeerConnectionError.peerDoesNotSupportEncryption
            case .timedOut:
                throw PeerConnectionError.timedOut
            case .handshakeFailed, .cryptoNotSelected:
                throw PeerConnectionError.handshakeFailed
            }
        } catch is CancellationError {
            channel.close()
            throw CancellationError()
        } catch {
            channel.close()
            throw PeerConnectionError.handshakeFailed
        }
        started = true
    }

    /// Encode, RC4-encrypt (continuing the handshake's send stream), and write
    /// one wire message.
    public func send(_ m: WireMessage) async throws {
        guard !closed, let channel else { throw PeerConnectionError.closed }
        var bytes = Array(WireCodec.encode(m))
        sendCipher.stream(&bytes)
        do {
            try await channel.write(Data(bytes))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PeerConnectionError.closed
        }
    }

    /// Read one framed, RC4-decrypted wire message. Frames with a length
    /// prefix over the 2 MiB cap are rejected from the prefix alone (throwing
    /// `WireCodecError.payloadTooLarge`); an idle read exceeding `readTimeout`
    /// throws `.timedOut` and tears the connection down.
    public func receiveMessage() async throws -> WireMessage {
        guard !closed, let channel else { throw PeerConnectionError.closed }
        do {
            return try await withThrowingTaskGroup(of: WireMessage.self) { group in
                group.addTask { try await self.readFrame(over: channel) }
                group.addTask {
                    try await Task.sleep(for: self.readTimeout)
                    throw PeerConnectionError.timedOut
                }
                guard let message = try await group.next() else {
                    throw PeerConnectionError.closed
                }
                group.cancelAll()
                return message
            }
        } catch let error as WireCodecError {
            throw error
        } catch let error as PeerConnectionError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PeerConnectionError.closed
        }
    }

    /// Cancel the connection. Interrupts any in-flight `send`/`receiveMessage`.
    public func close() async {
        closed = true
        channel?.close()
        channel = nil
        connection = nil
    }

    // MARK: - Frame I/O

    /// Read one frame (4-byte BE length + payload), decrypting both parts with
    /// the continuing recv stream. The length cap is enforced BEFORE the
    /// payload is read so a malicious prefix cannot make us buffer megabytes.
    private func readFrame(over channel: NWByteChannel) async throws -> WireMessage {
        var prefix = Array(try await channel.read(4))
        recvCipher.stream(&prefix)
        let length = (Int(prefix[0]) << 24) | (Int(prefix[1]) << 16) | (Int(prefix[2]) << 8) | Int(prefix[3])
        guard length <= WireCodec.maxPayloadLength else {
            throw WireCodecError.payloadTooLarge(length)
        }
        var payload: [UInt8] = []
        if length > 0 {
            payload = Array(try await channel.read(length))
            recvCipher.stream(&payload)
        }
        var framed = Data()
        framed.append(contentsOf: prefix)
        framed.append(contentsOf: payload)
        return try WireCodec.decode(framed)
    }

    // MARK: - Connect

    /// Wait for the NWConnection to reach `.ready`, failing fast on `.failed`,
    /// with a `timeout` race. Cancellation cancels the connection so the
    /// awaiting task always completes.
    private func awaitConnected(_ connection: NWConnection, queue: DispatchQueue,
                                timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let once = ResumeOnce()
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        connection.stateUpdateHandler = { state in
                            switch state {
                            case .ready:
                                connection.stateUpdateHandler = nil
                                once.resume(.success(()))
                            case .failed(let error):
                                connection.stateUpdateHandler = nil
                                once.resume(.failure(error))
                            case .cancelled:
                                connection.stateUpdateHandler = nil
                                once.resume(.failure(CancellationError()))
                            default:
                                break
                            }
                        }
                        once.attach(cont)
                        connection.start(queue: queue)
                    }
                } onCancel: {
                    connection.cancel()
                    once.resume(.failure(CancellationError()))
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw PeerConnectionError.timedOut
            }
            guard try await group.next() != nil else {
                throw PeerConnectionError.closed
            }
            group.cancelAll()
        }
    }
}

// MARK: - NWConnection byte channel

/// Error thrown by `NWByteChannel` at end-of-stream.
private enum ChannelError: Error {
    case eof
}

/// An `MSEByteChannel` over an outbound `NWConnection`. `read` returns exactly
/// `count` bytes, buffering partial receives. Reads are cancellation-
/// cooperative: cancelling the awaiting task cancels the connection and
/// resumes the read with `CancellationError` (the MSE timeout path relies on
/// this), and `close()` unblocks any in-flight read the same way.
final class NWByteChannel: MSEByteChannel, @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var buffer = Data()
    private var pending: CheckedContinuation<Data, Error>?
    private var cancelled = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func write(_ data: Data) async throws {
        let cancelledNow = lock.withLock { cancelled }
        guard !cancelledNow else { throw CancellationError() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    func read(_ count: Int) async throws -> Data {
        while true {
            switch lock.withLock({ takeIfAvailable(count) }) {
            case .bytes(let out):
                return out
            case .cancelled:
                throw CancellationError()
            case .waiting:
                let chunk = try await receiveChunk()
                lock.withLock { buffer.append(chunk) }
            }
        }
    }

    /// Cancel the connection; any pending read resumes with `CancellationError`.
    func close() {
        lock.lock()
        cancelled = true
        let cont = pending
        pending = nil
        lock.unlock()
        connection.cancel()
        cont?.resume(throwing: CancellationError())
    }

    /// Outcome of a `takeIfAvailable` attempt.
    private enum TakeResult {
        case bytes(Data)
        case cancelled
        case waiting
    }

    /// Caller must hold `lock`. Returns buffered bytes when `count` are
    /// available, `.cancelled` once the connection is closed, else `.waiting`.
    private func takeIfAvailable(_ count: Int) -> TakeResult {
        if buffer.count >= count {
            let out = Data(buffer.prefix(count))
            buffer.removeFirst(count)
            return .bytes(out)
        }
        if cancelled { return .cancelled }
        return .waiting
    }

    /// One `receive` roundtrip. The continuation is stored under the lock and
    /// resumed exactly once, either by the completion handler or by
    /// cancellation.
    private func receiveChunk() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                let cancelledNow = lock.withLock {
                    if cancelled {
                        return true
                    }
                    pending = cont
                    return false
                }
                if cancelledNow {
                    cont.resume(throwing: CancellationError())
                    return
                }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    self.completeReceive(data: data, isComplete: isComplete, error: error)
                }
            }
        } onCancel: {
            cancelPendingReceive()
        }
    }

    /// Runs on the connection's queue. Takes the continuation out from under
    /// the lock before resuming it (never resume while holding the lock).
    private func completeReceive(data: Data?, isComplete: Bool, error: NWError?) {
        lock.lock()
        guard let cont = pending else {
            lock.unlock()
            return
        }
        pending = nil
        lock.unlock()

        if let error {
            if cancelled {
                cont.resume(throwing: CancellationError())
            } else {
                cont.resume(throwing: error)
            }
        } else if let data, !data.isEmpty {
            cont.resume(returning: data)
        } else {
            // EOF (data nil/empty + isComplete), or an empty non-complete
            // delivery which should not happen with minimumIncompleteLength 1.
            cont.resume(throwing: ChannelError.eof)
        }
    }

    private func cancelPendingReceive() {
        lock.lock()
        cancelled = true
        let cont = pending
        pending = nil
        lock.unlock()
        connection.cancel()
        cont?.resume(throwing: CancellationError())
    }
}

// MARK: - Connect-state helper

/// A one-shot continuation slot safe against the state handler (connection
/// queue) and the cancellation handler racing each other; `done` is sticky.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var done = false

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

    func resume(_ result: Result<Void, Error>) {
        lock.lock()
        guard !done, let cont = continuation else {
            lock.unlock()
            return
        }
        done = true
        continuation = nil
        lock.unlock()
        cont.resume(with: result)
    }
}
