import Foundation
import Network

/// UDP tracker announce (BEP 15) over Network.framework.
///
/// Wire protocol: a 16-byte connect request (protocol id `0x41727101980`,
/// action 0, transaction id) is answered with a 16-byte response carrying an
/// 8-byte connection id; the 98-byte announce request (connection id,
/// action 1, transaction id, info hash, peer id, counters, event, ip, key,
/// numwant, port) is answered with interval/leechers/seeders plus compact
/// 6-byte peer entries.
///
/// The connect request is retransmitted with 2× backoff (up to 3 attempts,
/// same transaction id) when no valid response arrives in time; the overall
/// `timeout` bounds the whole announce. Transaction-id mismatches are treated
/// as a `badResponse`.
public enum UDPTracker {
    private static let queue = DispatchQueue(label: "Torrent.UDPTracker")
    /// BEP 15 magic: `0x41727101980`.
    private static let protocolID: UInt64 = 0x41727101980
    /// Connect retransmit budget: 3 sends, waiting initialTimeout, 2×, 4×.
    private static let maxConnectAttempts = 3
    /// How long to wait for the announce response after the last connect wait.
    private static let announceWaitFactor = 4

    /// Announce to a UDP tracker and return the decoded response.
    ///
    /// - Parameters:
    ///   - timeout: overall budget for the whole connect + announce exchange.
    ///   - initialTimeout: per-attempt wait for the first connect response
    ///     (doubles per retransmit); injectable so tests stay fast.
    public static func announce(url: URL, params: TrackerAnnounceParams,
                                timeout: Duration = .seconds(30),
                                initialTimeout: Duration = .seconds(2)) async throws -> TrackerResponse {
        let connection = try makeConnection(url: url)
        defer { connection.cancel() }
        return try await withThrowingTaskGroup(of: TrackerResponse.self) { group in
            group.addTask {
                try await perform(connection: connection, params: params,
                                  initialTimeout: initialTimeout)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                connection.cancel()
                throw HTTPTrackerError.timeout
            }
            let result: TrackerResponse
            do {
                guard let value = try await group.next() else {
                    throw HTTPTrackerError.badResponse
                }
                result = value
            } catch {
                group.cancelAll()
                throw error
            }
            group.cancelAll()
            // Drain the (cancelled) timeout task's error so the group exits cleanly.
            while let _ = try? await group.next() {}
            return result
        }
    }

    // MARK: - Exchange

    private static func perform(connection: NWConnection, params: TrackerAnnounceParams,
                                initialTimeout: Duration) async throws -> TrackerResponse {
        try await connect(connection: connection)

        // A single producer task feeds every received datagram into the
        // buffer; the connect/announce phases pop from it with their own
        // deadlines. NWConnection allows only one pending receive at a time,
        // so the phases never call receiveMessage directly. (An AsyncStream
        // was tried first, but cancelling a task suspended in `next()` —
        // which the per-attempt timeouts do — finishes the stream for every
        // later iterator, breaking retransmit. NSCondition has no such
        // cancellation semantics.)
        let buffer = DatagramBuffer()
        let receiver = Task {
            do {
                while true {
                    buffer.push(try await receiveMessage(connection: connection))
                }
            } catch {
                buffer.finish(error: error)
            }
        }
        defer { receiver.cancel() }

        let connectionID = try await connectPhase(connection: connection, buffer: buffer,
                                                  initialTimeout: initialTimeout)
        return try await announcePhase(connection: connection, buffer: buffer,
                                       params: params, connectionID: connectionID,
                                       initialTimeout: initialTimeout)
    }

    /// Connect: send the 16-byte request, retransmitting with 2× backoff
    /// (same txid) until a valid response arrives or the budget is exhausted.
    private static func connectPhase(connection: NWConnection, buffer: DatagramBuffer,
                                     initialTimeout: Duration) async throws -> UInt64 {
        let txid = randomTransactionID()
        let request = makeConnectRequest(txid: txid)
        var attempt = 0
        var wait = initialTimeout
        while true {
            try await send(connection: connection, data: request)
            switch buffer.pop(within: wait) {
            case .datagram(let data):
                if let connectionID = try parseConnectResponse(data, txid: txid) {
                    return connectionID
                }
                // Well-formed but untrusted (wrong txid) → reject loudly.
                throw HTTPTrackerError.badResponse
            case .finished(let error):
                throw HTTPTrackerError.connectionFailed(error.localizedDescription)
            case .timedOut:
                break
            }
            attempt += 1
            guard attempt < maxConnectAttempts else { throw HTTPTrackerError.timeout }
            wait = multiplied(wait, by: 2)
        }
    }

    /// Announce: send the 98-byte request once and wait for the response.
    private static func announcePhase(connection: NWConnection, buffer: DatagramBuffer,
                                      params: TrackerAnnounceParams, connectionID: UInt64,
                                      initialTimeout: Duration) async throws -> TrackerResponse {
        let txid = randomTransactionID()
        let request = makeAnnounceRequest(connectionID: connectionID, txid: txid, params: params)
        try await send(connection: connection, data: request)
        let deadline = ContinuousClock.now.advanced(by: multiplied(initialTimeout, by: announceWaitFactor))
        while true {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { throw HTTPTrackerError.timeout }
            switch buffer.pop(within: remaining) {
            case .datagram(let data):
                if let response = try parseAnnounceResponse(data, txid: txid) {
                    return response
                }
                // Datagram that is not an announce response (e.g. a duplicate
                // connect response): ignore and keep waiting.
            case .finished(let error):
                throw HTTPTrackerError.connectionFailed(error.localizedDescription)
            case .timedOut:
                throw HTTPTrackerError.timeout
            }
        }
    }

    // MARK: - Request building

    private static func makeConnectRequest(txid: UInt32) -> Data {
        var request = Data()
        appendUInt64(protocolID, to: &request)   // 8: protocol id
        appendUInt32(0, to: &request)            // 4: action = connect
        appendUInt32(txid, to: &request)         // 4: transaction id
        return request                           // 16 bytes
    }

    private static func makeAnnounceRequest(connectionID: UInt64, txid: UInt32,
                                            params: TrackerAnnounceParams) -> Data {
        var request = Data()
        appendUInt64(connectionID, to: &request)         // 8: connection id
        appendUInt32(1, to: &request)                    // 4: action = announce
        appendUInt32(txid, to: &request)                 // 4: transaction id
        request.append(params.infoHash)                  // 20: info hash
        request.append(params.peerID)                    // 20: peer id
        appendUInt64(UInt64(params.downloaded), to: &request)  // 8
        appendUInt64(UInt64(params.uploaded), to: &request)    // 8
        appendUInt64(UInt64(params.left), to: &request)        // 8
        appendUInt32(eventValue(params.event), to: &request)   // 4: event
        appendUInt32(0, to: &request)                          // 4: ip = 0
        appendUInt32(UInt32.random(in: 0...UInt32.max), to: &request)  // 4: key
        appendUInt32(UInt32(params.numwant), to: &request)     // 4: numwant
        appendUInt16(params.port, to: &request)                // 2: port
        return request                                         // 98 bytes
    }

    private static func eventValue(_ event: String?) -> UInt32 {
        switch event {
        case "completed": return 1
        case "started": return 2
        case "stopped": return 3
        default: return 0
        }
    }

    // MARK: - Response parsing

    /// Returns the connection id for a valid connect response, nil for
    /// datagrams that are not connect responses, and throws for a well-formed
    /// response with a mismatched txid (or a tracker error response).
    private static func parseConnectResponse(_ data: Data, txid: UInt32) throws -> UInt64? {
        guard data.count >= 16 else { return nil }
        let action = readUInt32(data, at: 0)
        if action == 2, readUInt32(data, at: 4) == txid {
            throw HTTPTrackerError.trackerError(String(decoding: data.dropFirst(8), as: UTF8.self))
        }
        guard action == 0, data.count == 16 else { return nil }
        guard readUInt32(data, at: 4) == txid else { throw HTTPTrackerError.badResponse }
        return readUInt64(data, at: 8)
    }

    /// Returns a decoded response for a valid announce response, nil for
    /// datagrams that are not announce responses, and throws for a
    /// well-formed response with a mismatched txid (or a tracker error).
    private static func parseAnnounceResponse(_ data: Data, txid: UInt32) throws -> TrackerResponse? {
        guard data.count >= 20 else { return nil }
        let action = readUInt32(data, at: 0)
        if action == 2, readUInt32(data, at: 4) == txid {
            throw HTTPTrackerError.trackerError(String(decoding: data.dropFirst(8), as: UTF8.self))
        }
        guard action == 1 else { return nil }
        guard readUInt32(data, at: 4) == txid else { throw HTTPTrackerError.badResponse }
        let interval = Int(readUInt32(data, at: 8))
        let leechers = Int(readUInt32(data, at: 12))
        let seeders = Int(readUInt32(data, at: 16))
        let peers = PeerList.decode(compact: data.dropFirst(20))
        return TrackerResponse(interval: interval, peers: peers, seeders: seeders, leechers: leechers)
    }

    // MARK: - Connection

    private static func makeConnection(url: URL) throws -> NWConnection {
        guard url.scheme == "udp" else {
            throw HTTPTrackerError.connectionFailed("unsupported announce scheme: \(url.scheme ?? "nil")")
        }
        guard let hostName = url.host else {
            throw HTTPTrackerError.connectionFailed("announce URL has no host: \(url.absoluteString)")
        }
        let port: UInt16
        if let explicit = url.port {
            guard explicit > 0, explicit < 65536 else {
                throw HTTPTrackerError.connectionFailed("invalid port in announce URL: \(url.absoluteString)")
            }
            port = UInt16(explicit)
        } else {
            port = 80   // UDP trackers default to port 80 per spec
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(hostName),
                                           port: NWEndpoint.Port(rawValue: port)!)
        return NWConnection(to: endpoint, using: .udp)
    }

    private static func connect(connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    cont.resume(returning: ())
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    cont.resume(throwing: HTTPTrackerError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    cont.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            connection.start(queue: Self.queue)
        }
    }

    private static func send(connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, contentContext: .defaultMessage, isComplete: true,
                            completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: HTTPTrackerError.connectionFailed(error.localizedDescription))
                } else {
                    cont.resume(returning: ())
                }
            })
        }
    }

    /// One UDP datagram per completion.
    private static func receiveMessage(connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receiveMessage { data, _, _, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: HTTPTrackerError.badResponse)
                }
            }
        }
    }

    // MARK: - Big-endian helpers

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        data.append(UInt8((value >> 56) & 0xFF))
        data.append(UInt8((value >> 48) & 0xFF))
        data.append(UInt8((value >> 40) & 0xFF))
        data.append(UInt8((value >> 32) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        UInt64(data[offset]) << 56
            | UInt64(data[offset + 1]) << 48
            | UInt64(data[offset + 2]) << 40
            | UInt64(data[offset + 3]) << 32
            | UInt64(data[offset + 4]) << 24
            | UInt64(data[offset + 5]) << 16
            | UInt64(data[offset + 6]) << 8
            | UInt64(data[offset + 7])
    }

    private static func multiplied(_ duration: Duration, by factor: Int) -> Duration {
        let components = duration.components
        return Duration(secondsComponent: components.seconds * Int64(factor),
                        attosecondsComponent: components.attoseconds * Int64(factor))
    }

    private static func randomTransactionID() -> UInt32 {
        UInt32.random(in: 0...UInt32.max)
    }
}

/// A thread-safe FIFO of received datagrams. The receiver task pushes, the
/// connect/announce phases pop with a per-attempt deadline.
private final class DatagramBuffer: @unchecked Sendable {
    enum PopResult {
        case datagram(Data)
        case timedOut
        case finished(Error)
    }

    private let condition = NSCondition()
    private var queue: [Data] = []
    private var finishError: Error?

    func push(_ data: Data) {
        condition.lock(); defer { condition.unlock() }
        queue.append(data)
        condition.signal()
    }

    /// Marks the buffer as dead (the receive loop ended). Wakes any waiter.
    func finish(error: Error) {
        condition.lock(); defer { condition.unlock() }
        finishError = error
        condition.broadcast()
    }

    /// Blocks until a datagram is available, `timeout` elapses, or the
    /// buffer is finished.
    func pop(within timeout: Duration) -> PopResult {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date.now.addingTimeInterval(Self.seconds(timeout))
        while queue.isEmpty && finishError == nil {
            if !condition.wait(until: deadline) { return .timedOut }
        }
        if !queue.isEmpty { return .datagram(queue.removeFirst()) }
        return .finished(finishError ?? HTTPTrackerError.connectionFailed("UDP receive ended"))
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
