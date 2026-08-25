import Foundation
import Network
import os

/// Errors thrown by `PeerAcceptor`.
public enum PeerAcceptorError: Error, Sendable {
    /// The NWListener could not bind to the requested port.
    case bindFailed(String)
}

/// Accepts inbound TCP connections for one torrent and turns each into a
/// `PeerConnection` in the responder role (MSE handshake). This is what lets
/// other clients (Transmission, …) see Get as a peer: they connect to our
/// advertised port and we answer their MSE handshake.
///
/// The acceptor binds a real listener on `port` (or an ephemeral port when
/// `port` is 0 — the actual port is exposed via `port()`). Inbound
/// connections that complete the MSE responder handshake are passed to
/// `onConnection`; the caller owns the `PeerConnection` from then on.
///
/// LIFETIME PITFALL (verified 2026-08-20 with a standalone repro): the
/// listener's `stateUpdateHandler`/`newConnectionHandler` must be set ONCE
/// before `start()`, and the `stateUpdateHandler` must NOT be cleared or
/// replaced after `.ready` — doing so leaves the listener bound but inert
/// (connections are refused, no state callbacks fire). Resolve the bound
/// port inside the single `.ready` callback instead.
public actor PeerAcceptor {
    private let infoHash: Data
    private let peerID: Data
    private let encryptedOnly: Bool
    private let connectTimeout: Duration
    private let readTimeout: Duration
    private let onConnection: @Sendable (PeerConnection) async -> Void

    private var listener: NWListener?
    private var acceptTask: Task<Void, Never>?
    private var boundPort: UInt16 = 0

    /// Create an acceptor. `onConnection` is invoked (on the actor) for every
    /// inbound connection that completes the MSE responder handshake.
    public init(infoHash: Data, peerID: Data,
                encryptedOnly: Bool = true,
                connectTimeout: Duration = .seconds(20),
                readTimeout: Duration = .seconds(90),
                onConnection: @escaping @Sendable (PeerConnection) async -> Void) {
        precondition(infoHash.count == 20, "infoHash must be 20 bytes")
        precondition(peerID.count == 20, "peerID must be 20 bytes")
        self.infoHash = infoHash
        self.peerID = peerID
        self.encryptedOnly = encryptedOnly
        self.connectTimeout = connectTimeout
        self.readTimeout = readTimeout
        self.onConnection = onConnection
    }

    /// The port the listener actually bound (useful when 0 was requested).
    public func port() -> UInt16 { boundPort }

    /// Bind the listener and start accepting. Throws `PeerAcceptorError` on
    /// bind failure. The listener keeps accepting until `stop()`.
    public func start(port: UInt16 = 6881) async throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        // Allow the port to be reused immediately after a stop/relaunch.
        params.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            throw PeerAcceptorError.bindFailed(String(describing: error))
        }
        self.listener = listener

        // Set BOTH handlers once, BEFORE start(), and never clear/replace the
        // state handler (see the lifetime pitfall above). The bound port is
        // resolved in the single .ready callback.
        let resolved: UInt16 = await withCheckedContinuation { (cont: CheckedContinuation<UInt16, Never>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Self.log.info("listener ready on \(listener.port?.rawValue ?? port, privacy: .public)")
                    cont.resume(returning: listener.port?.rawValue ?? port)
                case .failed(let error):
                    Self.log.error("listener failed: \(String(describing: error), privacy: .public)")
                    cont.resume(returning: port)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Self.log.info("inbound TCP connection received")
                Task { await self?.handleInbound(connection) }
            }
            listener.start(queue: .global(qos: .utility))
        }
        boundPort = resolved

        // Park task keeps the accept loop alive until stop() cancels it.
        acceptTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Stop accepting and cancel any in-flight accept.
    public func stop() {
        listener?.cancel()
        listener = nil
        acceptTask?.cancel()
        acceptTask = nil
    }

    // MARK: - Inbound handling

    /// Run the MSE responder handshake over an accepted connection, then hand
    /// the established `PeerConnection` to the caller. Failures (plaintext
    /// peer, bad handshake, timeout) just close the connection.
    private func handleInbound(_ connection: NWConnection) async {
        let peer = PeerConnection(accepted: connection,
                                  infoHash: infoHash,
                                  peerID: peerID,
                                  encryptedOnly: encryptedOnly,
                                  connectTimeout: connectTimeout,
                                  readTimeout: readTimeout)
        do {
            try await peer.start()
        } catch {
            Self.log.error("inbound handshake failed: \(String(describing: error), privacy: .public)")
            await peer.close()
            return
        }
        let remoteID = await peer.remotePeerIDHex()
        Self.log.info("accepted MSE peer \(remoteID, privacy: .public)")
        await onConnection(peer)
    }

    private static let log = Logger(subsystem: "dev.v57.get", category: "engine")
}
