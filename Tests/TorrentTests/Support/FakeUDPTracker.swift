import Foundation

@testable import Torrent

/// Minimal in-process UDP tracker (BEP 15) used by tests: a POSIX UDP
/// socket bound to 127.0.0.1 on an ephemeral port that answers the
/// 16-byte connect request with a connection_id, then the 98-byte
/// announce request with interval/leechers/seeders + compact peers.
///
/// Implemented on raw `socket`/`bind`/`recvfrom`/`sendto` because
/// `NWListener` fails with `POSIXErrorCode(.EINVAL)` on every bind in this
/// environment (macOS 27 / Xcode 27 beta, CLI test processes). BSD sockets
/// work; outbound `NWConnection` works — only the listener is affected, and
/// listeners are test infrastructure only (the production client is
/// outbound-only).
final class FakeUDPTracker: @unchecked Sendable {
  /// A parsed announce request, as observed by the tracker.
  struct Announce: Sendable, Equatable {
    let connectionID: UInt64
    let infoHash: Data
    let peerID: Data
    let downloaded: UInt64
    let uploaded: UInt64
    let left: UInt64
    /// 0 = none, 1 = completed, 2 = started, 3 = stopped.
    let event: UInt32
    let ip: UInt32
    let key: UInt32
    let numwant: UInt32
    let port: UInt16
  }

  /// The connection_id this tracker hands out (fixed so tests can assert).
  static let connectionID: UInt64 = 0x1234_5678_9ABC_DEF0

  let url: URL
  let port: UInt16

  /// The most recent announce request (nil until the first one arrives).
  var lastAnnounce: Announce? { lock.withLock { _lastAnnounce } }

  /// Number of connect requests received (including dropped ones).
  var connectCount: Int { lock.withLock { _connectCount } }

  private let peersData: Data
  private let interval: Int
  private let leechers: Int
  private let seeders: Int
  /// Drop the first connect request (tests client retransmit).
  private let dropFirstConnect: Bool
  /// Reply to every request with a corrupted transaction id.
  private let wrongTxid: Bool
  /// When false, read datagrams but never reply (tests client timeout).
  private let respond: Bool

  private let fd: Int32
  private let receiveThread: Thread
  private let stop = StopFlag()

  private let lock = NSLock()
  private var _lastAnnounce: Announce?
  private var _connectCount = 0
  private var _droppedFirstConnect = false

  init(
    peers: Data = Data(), interval: Int = 1800, leechers: Int = 0, seeders: Int = 0,
    dropFirstConnect: Bool = false, wrongTxid: Bool = false, respond: Bool = true
  ) throws {
    self.peersData = peers
    self.interval = interval
    self.leechers = leechers
    self.seeders = seeders
    self.dropFirstConnect = dropFirstConnect
    self.wrongTxid = wrongTxid
    self.respond = respond

    // socket/bind on 127.0.0.1:0 (ephemeral UDP port).
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { throw FakeUDPTrackerError.posix(errno) }
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
      throw FakeUDPTrackerError.posix(errno)
    }
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    var bound = sockaddr_in()
    let nameResult = withUnsafeMutablePointer(to: &bound) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in getsockname(fd, sp, &len) }
    }
    guard nameResult == 0 else {
      close(fd)
      throw FakeUDPTrackerError.posix(errno)
    }
    let assigned = UInt16(bigEndian: bound.sin_port)
    guard assigned != 0 else {
      close(fd)
      throw FakeUDPTrackerError.noPort
    }

    self.fd = fd
    self.port = assigned
    self.url = URL(string: "udp://127.0.0.1:\(assigned)/announce")!

    // Receive loop on a dedicated thread; poll() keeps the stop flag
    // responsive (closing an fd does not wake a blocked recvfrom on
    // macOS). The closure captures a weak box instead of self (self is
    // not fully initialized until receiveThread is assigned); the box is
    // populated right after start(), well before the first 200ms tick.
    let stop = self.stop
    let recvFD = fd
    let box = TrackerBox()
    self.receiveThread = Thread {
      var buffer = [UInt8](repeating: 0, count: 2048)
      while !stop.isSet {
        var pfd = pollfd(fd: recvFD, events: Int16(POLLIN), revents: 0)
        let pr = poll(&pfd, 1, 200)
        if pr <= 0 { continue }
        var from = sockaddr_in()
        var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) { p in
          p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
            recvfrom(recvFD, &buffer, buffer.count, 0, sp, &fromLen)
          }
        }
        guard n > 0, let tracker = box.tracker else { continue }
        tracker.handleDatagram(Data(buffer.prefix(n)), from: from)
      }
      close(recvFD)
    }
    receiveThread.name = "FakeUDPTracker.recv"
    receiveThread.start()
    box.tracker = self
  }

  deinit {
    stop.set()
    // The receive thread closes the fd and exits on the next poll tick.
    receiveThread.cancel()
  }

  // MARK: - Datagram handling (receive thread only)

  private func handleDatagram(_ data: Data, from source: sockaddr_in) {
    guard data.count >= 16 else { return }
    // Both request types carry action at offset 8 (after the 8-byte
    // protocol/connection id) and the transaction id at offset 12.
    let action = readUInt32(data, at: 8)
    let txid = readUInt32(data, at: 12)
    if action == 0, data.count == 16 {
      // Connect request.
      lock.withLock { _connectCount += 1 }
      guard respond else { return }
      var dropped = false
      if dropFirstConnect {
        lock.withLock {
          if !_droppedFirstConnect {
            _droppedFirstConnect = true
            dropped = true
          }
        }
        if dropped { return }
      }
      var reply = Data()
      appendUInt32(0, to: &reply)  // action: connect
      appendUInt32(wrongTxid ? txid ^ 0xFFFF_FFFF : txid, to: &reply)
      appendUInt64(Self.connectionID, to: &reply)
      send(reply, to: source)
    } else if action == 1, data.count == 98 {
      // Announce request.
      let announce = Announce(
        connectionID: readUInt64(data, at: 0), infoHash: data.subdata(in: 16..<36),
        peerID: data.subdata(in: 36..<56), downloaded: readUInt64(data, at: 56),
        uploaded: readUInt64(data, at: 64), left: readUInt64(data, at: 72),
        event: readUInt32(data, at: 80), ip: readUInt32(data, at: 84),
        key: readUInt32(data, at: 88), numwant: readUInt32(data, at: 92),
        port: readUInt16(data, at: 96))
      lock.withLock { _lastAnnounce = announce }
      guard respond else { return }
      var reply = Data()
      appendUInt32(1, to: &reply)  // action: announce
      appendUInt32(wrongTxid ? txid ^ 0xFFFF_FFFF : txid, to: &reply)
      appendUInt32(UInt32(interval), to: &reply)
      appendUInt32(UInt32(leechers), to: &reply)
      appendUInt32(UInt32(seeders), to: &reply)
      reply.append(peersData)
      send(reply, to: source)
    }
  }

  private func send(_ data: Data, to source: sockaddr_in) {
    data.withUnsafeBytes { raw in
      var to = source
      _ = withUnsafePointer(to: &to) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
          sendto(fd, raw.baseAddress, data.count, 0, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
    }
  }

  // MARK: - Big-endian helpers

  private func appendUInt16(_ value: UInt16, to data: inout Data) {
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
  }

  private func appendUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
  }

  private func appendUInt64(_ value: UInt64, to data: inout Data) {
    data.append(UInt8((value >> 56) & 0xFF))
    data.append(UInt8((value >> 48) & 0xFF))
    data.append(UInt8((value >> 40) & 0xFF))
    data.append(UInt8((value >> 32) & 0xFF))
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
  }

  private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
  }

  private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8
      | UInt32(data[offset + 3])
  }

  private func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
    UInt64(data[offset]) << 56 | UInt64(data[offset + 1]) << 48 | UInt64(data[offset + 2]) << 40
      | UInt64(data[offset + 3]) << 32 | UInt64(data[offset + 4]) << 24 | UInt64(data[offset + 5])
      << 16 | UInt64(data[offset + 6]) << 8 | UInt64(data[offset + 7])
  }
}

enum FakeUDPTrackerError: Error {
  case noPort
  case posix(Int32)
}

/// Atomic stop flag for the receive loop.
private final class StopFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var flag = false
  func set() { lock.withLock { flag = true } }
  var isSet: Bool { lock.withLock { flag } }
}

/// Weak reference to the tracker for the receive thread (breaks the
/// thread → tracker → thread retain cycle).
private final class TrackerBox: @unchecked Sendable { weak var tracker: FakeUDPTracker? }
