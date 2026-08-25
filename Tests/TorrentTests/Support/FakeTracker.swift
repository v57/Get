import Foundation

@testable import Torrent

/// Minimal in-process HTTP tracker used by tests: a POSIX-socket listener
/// bound to 127.0.0.1 on an ephemeral port that answers `GET /announce?…`
/// requests with a bencoded compact-peer response (or a failure-reason body,
/// or a raw body).
///
/// Implemented on raw `socket`/`bind`/`listen`/`accept` because
/// `NWListener` fails with `POSIXErrorCode(.EINVAL)` on every bind in this
/// environment (macOS 27 / Xcode 27 beta, CLI test processes). BSD sockets
/// work; outbound `NWConnection` works — only the listener is affected, and
/// listeners are test infrastructure only (the production client is
/// outbound-only).
final class FakeTracker: @unchecked Sendable {
  /// A parsed announce request, as observed by the tracker.
  struct Announce: Sendable, Equatable {
    let path: String
    /// Query parameters, percent-decoded. Binary fields (`info_hash`,
    /// `peer_id`) are lossy here — use `rawQuery` for exact bytes.
    let query: [String: String]
    /// The raw query string exactly as received on the wire.
    let rawQuery: String
  }

  let url: URL
  let port: UInt16

  /// The most recent announce request (nil until the first one arrives).
  var lastAnnounce: Announce? { lock.withLock { _lastAnnounce } }

  private var peersData: Data
  private var peers6Data: Data
  private let interval: Int
  private let failureReason: String?
  private let seeders: Int?
  private let leechers: Int?
  private let rawBody: Data?

  private let listenFD: Int32
  private let acceptThread: Thread
  private let stop = StopFlag()

  private let lock = NSLock()
  private var _lastAnnounce: Announce?

  init(
    peers: Data = Data(), peers6: Data = Data(), interval: Int = 1800, failureReason: String? = nil,
    seeders: Int? = nil, leechers: Int? = nil, rawBody: Data? = nil
  ) throws {
    self.peersData = peers
    self.peers6Data = peers6
    self.interval = interval
    self.failureReason = failureReason
    self.seeders = seeders
    self.leechers = leechers
    self.rawBody = rawBody

    // socket/bind/listen on 127.0.0.1:0 (ephemeral).
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw FakeTrackerError.posix(errno) }
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
      throw FakeTrackerError.posix(errno)
    }
    guard listen(fd, 16) == 0 else {
      close(fd)
      throw FakeTrackerError.posix(errno)
    }
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    var bound = sockaddr_in()
    let nameResult = withUnsafeMutablePointer(to: &bound) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in getsockname(fd, sp, &len) }
    }
    guard nameResult == 0 else {
      close(fd)
      throw FakeTrackerError.posix(errno)
    }
    let assigned = UInt16(bigEndian: bound.sin_port)
    guard assigned != 0 else {
      close(fd)
      throw FakeTrackerError.noPort
    }

    self.listenFD = fd
    self.port = assigned
    self.url = URL(string: "http://127.0.0.1:\(assigned)/announce")!

    // Accept loop on a dedicated thread; poll() keeps the stop flag
    // responsive (closing an fd does not wake a blocked accept on macOS).
    // The closure captures a weak box instead of self (self is not fully
    // initialized until acceptThread is assigned); the box is populated
    // right after start(), well before the first 200ms poll tick.
    let stop = self.stop
    let acceptFD = fd
    let box = TrackerBox()
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
          guard let tracker = box.tracker else {
            close(client)
            continue
          }
          Thread.detachNewThread { tracker.handleConnection(client) }
        }
      }
      close(acceptFD)
    }
    acceptThread.name = "FakeTracker.accept"
    acceptThread.start()
    box.tracker = self
  }

  /// Allow tests to change the peer list served on subsequent announces.
  func setPeers(_ peers: Data, peers6: Data = Data()) {
    lock.withLock {
      self.peersData = peers
      self.peers6Data = peers6
    }
  }

  deinit {
    stop.set()
    // The accept thread closes the fd and exits on the next poll tick.
    acceptThread.cancel()
  }

  // MARK: - Connection handling

  private func handleConnection(_ fd: Int32) {
    defer { close(fd) }
    var buffer = Data()
    // Blocking read until the end of the HTTP header block.
    var byte: UInt8 = 0
    while buffer.range(of: Data("\r\n\r\n".utf8)) == nil, buffer.count < 64 * 1024 {
      let n = read(fd, &byte, 1)
      if n <= 0 { break }
      buffer.append(byte)
    }
    guard buffer.range(of: Data("\r\n\r\n".utf8)) != nil else { return }
    guard let body = response(for: buffer) else { return }
    let head =
      "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    let response = Data(head.utf8) + body
    response.withUnsafeBytes { raw in
      var sent = 0
      while sent < response.count {
        let n = write(fd, raw.baseAddress!.advanced(by: sent), response.count - sent)
        if n <= 0 { break }
        sent += n
      }
    }
  }

  // MARK: - Request parsing / response building

  private func response(for headerData: Data) -> Data? {
    let text = String(decoding: headerData, as: UTF8.self)
    let lines = text.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    let parts = requestLine.split(separator: " ", maxSplits: 2)
    guard parts.count >= 2, parts[0] == "GET" else { return nil }
    let target = String(parts[1])
    let targetParts = target.split(separator: "?", maxSplits: 1)
    let path = String(targetParts[0])
    let rawQuery = targetParts.count == 2 ? String(targetParts[1]) : ""
    let query = Self.parseQuery(rawQuery)
    lock.withLock { _lastAnnounce = Announce(path: path, query: query, rawQuery: rawQuery) }
    return makeBody()
  }

  private func makeBody() -> Data {
    if let rawBody { return rawBody }
    if let reason = failureReason {
      return Bencode.encode(.dict([Data("failure reason".utf8): .string(Data(reason.utf8))]))
    }
    var dict: [Data: BencodeValue] = [
      Data("interval".utf8): .int(Int64(interval)), Data("peers".utf8): .string(peersData),
    ]
    if let seeders { dict[Data("complete".utf8)] = .int(Int64(seeders)) }
    if let leechers { dict[Data("incomplete".utf8)] = .int(Int64(leechers)) }
    if !peers6Data.isEmpty { dict[Data("peers6".utf8)] = .string(peers6Data) }
    return Bencode.encode(.dict(dict))
  }

  private static func parseQuery(_ raw: String) -> [String: String] {
    var result: [String: String] = [:]
    for pair in raw.split(separator: "&") {
      let kv = pair.split(separator: "=", maxSplits: 1)
      guard kv.count == 2 else { continue }
      result[String(kv[0])] = percentDecode(String(kv[1]))
    }
    return result
  }

  private static func percentDecode(_ s: String) -> String {
    let bytes = Array(s.utf8)
    var decoded: [UInt8] = []
    var index = 0
    while index < bytes.count {
      if bytes[index] == UInt8(ascii: "%"), index + 2 < bytes.count,
        let hi = hexValue(bytes[index + 1]), let lo = hexValue(bytes[index + 2])
      {
        decoded.append(hi << 4 | lo)
        index += 3
      } else {
        decoded.append(bytes[index])
        index += 1
      }
    }
    return String(decoding: decoded, as: UTF8.self)
  }

  private static func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
    default: return nil
    }
  }
}

enum FakeTrackerError: Error {
  case noPort
  case posix(Int32)
}

/// Atomic stop flag for the accept loop.
private final class StopFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var flag = false
  func set() { lock.withLock { flag = true } }
  var isSet: Bool { lock.withLock { flag } }
}

/// Weak reference to the tracker for the accept thread (breaks the
/// thread → tracker → thread retain cycle).
private final class TrackerBox: @unchecked Sendable { weak var tracker: FakeTracker? }
