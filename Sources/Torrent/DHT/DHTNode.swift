import CryptoKit
import Foundation

#if os(Windows)
  import WinSDK
#endif

/// Thrown by DHT operations.
public enum DHTError: Error, Equatable, Sendable {
  case socket(String)
  case timeout
  case closed
  case badResponse(String)
}

/// A BEP 5 DHT node: a UDP listener + KRPC client with a k-bucket routing
/// table, used to discover peers for an infohash beyond what trackers return.
///
/// The node owns a raw POSIX UDP socket. A receiver thread reads datagrams,
/// matches each to a pending request by its transaction id (`t`), and resolves
/// the awaiting continuation. Requests carry a timeout; `close()` wakes the
/// receiver via the poll stop flag.
public final class DHTNode: @unchecked Sendable {
  public let nodeID: Data
  public let routing: RoutingTable

  public static let bootstrapNodes: [(String, UInt16)] = [
    ("router.bittorrent.com", 6881), ("router.utorrent.com", 6881),
    ("dht.transmissionbt.com", 6881),
  ]

  private let fd: DHTDescriptor
  private let lock = NSLock()
  private var pending: [String: CheckedContinuation<(Data, String, UInt16), Error>] = [:]
  private var stopped = false
  private var counter: UInt32 = 0

  /// Create a node bound to an ephemeral local UDP port.
  public init() throws {
    self.fd = try DHTSocket.bindAny()
    self.nodeID = Self.makeNodeID()
    self.routing = RoutingTable(ownID: nodeID)
    startReceiver()
  }

  /// Injectable for tests: construct over an existing bound fd + fixed node id.
  init(fd: DHTDescriptor, nodeID: Data) {
    self.fd = fd
    self.nodeID = nodeID
    self.routing = RoutingTable(ownID: nodeID)
    startReceiver()
  }

  deinit { stopAndClose() }

  // MARK: - Lifecycle

  private func startReceiver() {
    let thread = Thread { [weak self] in self?.receiverLoop() }
    thread.name = "Torrent.DHT"
    thread.start()
  }

  public func close() { stopAndClose() }

  private func stopAndClose() {
    if locked({
      let s = stopped
      stopped = true
      return s
    }) {
      return
    }
    DHTSocket.close(fd)
  }

  // MARK: - Receiver

  private func receiverLoop() {
    while true {
      if locked({ stopped }) { return }
      let rc = DHTSocket.waitReadable(fd, milliseconds: 200)
      if rc < 0 {
        if locked({ stopped }) { return }
        continue
      }
      if rc == 0 { continue }
      if let (data, host, port) = DHTSocket.receive(fd) { handleDatagram(data, host: host, port: port) }
    }
  }

  private func handleDatagram(_ data: Data, host: String, port: UInt16) {
    guard let t = transactionID(from: data) else { return }
    let cont = locked { pending.removeValue(forKey: t) }
    cont?.resume(returning: (data, host, port))
  }

  private func transactionID(from data: Data) -> String? {
    guard let msg = try? KRPC.decode(data) else { return nil }
    switch msg {
    case .query(let t, _, _), .response(let t, _), .error(let t, _, _): return t
    }
  }

  // MARK: - Core request/response

  /// Send a query and await the matching response, bounded by `timeout`.
  public func query(_ message: KRPCMessage, to node: DHTNodeInfo, timeout: Duration = .seconds(4))
    async throws -> KRPCMessage
  {
    let t: String
    guard case .query(let tt, _, _) = message else { throw DHTError.badResponse("not a query") }
    t = tt

    guard let endpoint = resolve(node.ip, port: node.port) else {
      throw DHTError.badResponse("unresolvable host \(node.ip)")
    }

    return try await withThrowingTaskGroup(of: (Data, String, UInt16).self) { group in
      group.addTask {
        try await self.awaitResponse(t: t, endpoint: endpoint, bytes: KRPC.encode(message))
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw DHTError.timeout
      }
      do {
        guard let value = try await group.next() else {
          self.failPending(t)
          throw DHTError.closed
        }
        group.cancelAll()
        while (try? await group.next()) != nil {}
        let reply = try KRPC.decode(value.0)
        if case .response(_, let values) = reply, case .string(let id)? = values["id"],
          id.count == 20
        {
          self.routing.insert(DHTNodeInfo(id: id, ip: node.ip, port: node.port))
        }
        return reply
      } catch {
        group.cancelAll()
        self.failPending(t)
        if let err = error as? DHTError, err == .timeout { throw DHTError.timeout }
        throw error
      }
    }
  }

  /// Register a continuation for transaction `t`, send the datagram, and wait.
  /// On cancellation (timeout/group cancel) the continuation is resumed with
  /// `DHTError.timeout` so it never leaks.
  private func awaitResponse(t: String, endpoint: sockaddr_in, bytes: Data) async throws -> (
    Data, String, UInt16
  ) {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (cont: CheckedContinuation<(Data, String, UInt16), Error>) in
        self.failPending(t)
        self.locked { self.pending[t] = cont }
        self.sendDatagram(bytes, to: endpoint)
      }
    } onCancel: {
      self.failPending(t)
    }
  }

  private func failPending(_ t: String) {
    let cont = locked { pending.removeValue(forKey: t) }
    cont?.resume(throwing: DHTError.timeout)
  }

  // MARK: - Public operations

  public func bootstrap(timeout: Duration = .seconds(4)) async {
    for (host, port) in Self.bootstrapNodes {
      // Bootstrap nodes have unknown ids; query ping to learn them.
      let node = DHTNodeInfo(id: Data(repeating: 0, count: 20), ip: host, port: port)
      _ = try? await query(ping(), to: node, timeout: timeout)
    }
  }

  /// Iteratively find peers for `infoHash`; returns discovered peers.
  /// Queries the closest known nodes CONCURRENTLY (a serial walk stalls on
  /// the first dead node — with a mostly-empty routing table after a 3-ping
  /// bootstrap, a serial lookup finds almost nothing).
  public func getPeers(infoHash: Data, timeout: Duration = .seconds(3)) async -> [DHTNodeInfo] {
    var queried = Set<Data>()
    var peers: [DHTNodeInfo] = []
    var candidates = routing.findClosest(to: infoHash, count: 16)
    if candidates.isEmpty {
      candidates = Self.bootstrapNodes.map {
        DHTNodeInfo(id: Data(repeating: 0, count: 20), ip: $0.0, port: $0.1)
      }
    }
    // Do up to 3 parallel rounds: each round queries up to 8 of the
    // closest unqueried nodes at once and folds their nodes/peers in.
    for _ in 0..<3 {
      let batch = candidates.prefix(8).filter {
        $0.id == Data(repeating: 0, count: 20) || !queried.contains($0.id)
      }
      if batch.isEmpty { break }
      for node in batch { queried.insert(node.id) }
      let responses = await withTaskGroup(of: KRPCMessage?.self) { group in
        for node in batch {
          group.addTask {
            let msg = KRPCMessage.query(
              transaction: self.nextTransaction(), method: "get_peers",
              arguments: KRPC.args(id: self.nodeID, ["info_hash": .string(infoHash)]))
            guard let reply = try? await self.query(msg, to: node, timeout: timeout),
              case .response(_, _) = reply
            else { return nil }
            return reply
          }
        }
        var out: [KRPCMessage?] = []
        for await r in group { out.append(r) }
        return out
      }
      for reply in responses {
        guard let reply, case .response(_, let values) = reply else { continue }
        if let rawValues = values["values"], case .list(let list) = rawValues {
          for case .string(let compact) in list {
            peers.append(contentsOf: parseCompactPeers(compact))
          }
        }
        if let rawNodes = values["nodes"], case .string(let nodesCompact) = rawNodes {
          for n in DHTNodeInfo.nodes(from: nodesCompact, ipv6: false) {
            routing.insert(n)
            candidates.append(n)
          }
        }
        if let rawNodes6 = values["nodes6"], case .string(let nodes6) = rawNodes6 {
          for n in DHTNodeInfo.nodes(from: nodes6, ipv6: true) {
            routing.insert(n)
            candidates.append(n)
          }
        }
      }
      candidates.sort {
        RoutingTable.xor(infoHash, $0.id).lexicographicallyPrecedes(
          RoutingTable.xor(infoHash, $1.id))
      }
      if peers.count >= 50 { break }
    }
    return peers
  }

  public func announcePeer(infoHash: Data, port: UInt16, timeout: Duration = .seconds(3)) async {
    for node in routing.findClosest(to: infoHash, count: 4) {
      let msg = KRPCMessage.query(
        transaction: nextTransaction(), method: "announce_peer",
        arguments: KRPC.args(
          id: nodeID,
          [
            "info_hash": .string(infoHash), "port": .int(Int64(port)),
            "token": .string(Data("hm".utf8)), "implied_port": .int(0),
          ]))
      _ = try? await query(msg, to: node, timeout: timeout)
    }
  }

  public func nextTransaction() -> String {
    locked {
      counter &+= 1
      return String(counter, radix: 16)
    }
  }

  func ping() -> KRPCMessage {
    KRPCMessage.query(
      transaction: nextTransaction(), method: "ping", arguments: KRPC.args(id: nodeID, [:]))
  }

  // MARK: - Helpers

  private func parseCompactPeers(_ compact: Data) -> [DHTNodeInfo] {
    var out: [DHTNodeInfo] = []
    var i = compact.startIndex
    let end = compact.endIndex
    while i < end {
      if end - i >= 18 {
        let ip = DHTNodeInfo.formatV6(compact.subdata(in: i..<(i + 16)))
        let port = (UInt16(compact[i + 16]) << 8) | UInt16(compact[i + 17])
        out.append(DHTNodeInfo(id: Data(repeating: 0, count: 20), ip: ip, port: port))
        i += 18
      } else if end - i >= 6 {
        let ip = DHTNodeInfo.formatV4(compact.subdata(in: i..<(i + 4)))
        let port = (UInt16(compact[i + 4]) << 8) | UInt16(compact[i + 5])
        out.append(DHTNodeInfo(id: Data(repeating: 0, count: 20), ip: ip, port: port))
        i += 6
      } else {
        break
      }
    }
    return out
  }

  private func sendDatagram(_ data: Data, to endpoint: sockaddr_in) {
    DHTSocket.send(fd, data, to: endpoint)
  }

  private func resolve(_ host: String, port: UInt16) -> sockaddr_in? {
    DHTSocket.resolve(host, port: port)
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  private static func makeNodeID() -> Data {
    Data(Insecure.SHA1.hash(data: Data(UUID().uuidString.utf8)))
  }
}
