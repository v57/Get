import Foundation

@testable import Torrent

/// In-process fake seeder for end-to-end session tests: a POSIX-socket
/// listener on 127.0.0.1:0 that accepts connections, runs the MSE responder
/// handshake (via `FakeMSEPeer.responderHandshake`), then serves piece data
/// from a real torrent's content stream over the RC4-encrypted wire protocol.
///
/// Sends an all-ones bitfield + unchoke (it has every piece), answers
/// `request` messages with `piece` data, and records every received message
/// so tests can assert the client never uploads and requests sequentially.
///
/// Built on raw BSD sockets because `NWListener` fails with EINVAL in CLI
/// test processes (same pattern as `FakeTracker`/`FakeWirePeer`).
final class FakeSeeder: @unchecked Sendable {
  enum Mode {
    case encrypted
    case plaintext  // answer the DH exchange with a plaintext BT handshake
  }

  /// What the fake observed, published when the connection handler exits.
  struct Result: Sendable {
    let receivedHandshake: Data
    let receivedMessages: [WireMessage]
  }

  let port: UInt16
  let pieceLength: Int
  /// The full content stream this seeder serves (torrent's concatenated files).
  let content: Data
  /// The torrent's infohash — settable after init (the infohash is only
  /// known once the torrent bundle is built, which needs the tracker URL,
  /// which needs this seeder's port).
  var infoHash: [UInt8]
  let peerID: [UInt8]
  /// Requested piece indices in arrival order (from receivedMessages).
  var requestedPieces: [Int] {
    lock.withLock { _receivedMessages }.compactMap { message in
      if case .request(let index, _, _) = message { return index }
      return nil
    }
  }

  /// Messages received so far (thread-safe; live-updates as they arrive).
  var receivedMessages: [WireMessage] { lock.withLock { _receivedMessages } }

  private let mode: Mode
  private let serveDelay: Duration
  private let listenFD: Int32
  private let acceptThread: Thread
  private let stopFlag = WirePeerStopFlag()
  private let lock = NSLock()

  private var _receivedMessages: [WireMessage] = []
  private var _receivedHandshake = Data()
  private var _result: Result?

  init(
    content: Data, pieceLength: Int, infoHash: [UInt8], peerID: [UInt8], mode: Mode = .encrypted,
    serveDelay: Duration = .zero, port: UInt16 = 0
  ) throws {
    self.content = content
    self.pieceLength = pieceLength
    self.infoHash = infoHash
    self.peerID = peerID
    self.mode = mode
    self.serveDelay = serveDelay

    // socket/bind/listen on 127.0.0.1:port (ephemeral if port == 0).
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw FakeSeederError.posix(errno) }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port.bigEndian)  // specific port or 0 = ephemeral
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bindResult = withUnsafePointer(to: &addr) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
        bind(fd, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else {
      close(fd)
      throw FakeSeederError.posix(errno)
    }
    guard listen(fd, 16) == 0 else {
      close(fd)
      throw FakeSeederError.posix(errno)
    }
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    var bound = sockaddr_in()
    let nameResult = withUnsafeMutablePointer(to: &bound) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in getsockname(fd, sp, &len) }
    }
    guard nameResult == 0 else {
      close(fd)
      throw FakeSeederError.posix(errno)
    }
    let assigned = UInt16(bigEndian: bound.sin_port)
    guard assigned != 0 else {
      close(fd)
      throw FakeSeederError.noPort
    }

    self.listenFD = fd
    self.port = assigned

    // Accept loop on a dedicated thread (poll keeps the stop flag
    // responsive). The closure captures a weak box instead of self.
    let stop = self.stopFlag
    let acceptFD = fd
    let box = SeederBox()
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
          guard let seeder = box.seeder else {
            close(client)
            continue
          }
          Thread.detachNewThread { seeder.handleConnection(client) }
        }
      }
      close(acceptFD)
    }
    acceptThread.name = "FakeSeeder.accept"
    acceptThread.start()
    box.seeder = self
  }

  deinit {
    stopFlag.set()
    acceptThread.cancel()
  }

  func stop() { stopFlag.set() }

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
    throw FakeSeederError.timedOut
  }

  // MARK: - Connection handling

  /// Runs on the connection thread (detached by the accept loop): wraps the
  /// fd in a blocking byte channel and drives the async seeder session on
  /// the cooperative pool, waiting here until it completes.
  private func handleConnection(_ fd: Int32) {
    defer { close(fd) }
    let channel = FDByteChannel(fd: fd, stop: stopFlag)
    let sem = DispatchSemaphore(value: 0)
    Task {
      do { try await self.serve(channel) } catch {
        // Client closed or a protocol error — the result is published
        // from whatever was recorded so far.
      }
      self.publishResult()
      sem.signal()
    }
    sem.wait()
  }

  /// The MSE responder handshake followed by the wire protocol (or the
  /// one-shot plaintext behavior).
  private func serve(_ channel: FDByteChannel) async throws {
    if mode == .plaintext {
      // Answer the DH exchange with a plaintext BT handshake and stop:
      // an MSE-only client must drop us immediately.
      _ = try await FakeMSEPeer.responderHandshake(
        over: channel, infoHash: infoHash, peerID: peerID, mode: .plaintext)
      return
    }

    let handshake = try await FakeMSEPeer.responderHandshake(
      over: channel, infoHash: infoHash, peerID: peerID)
    lock.withLock { _receivedHandshake = handshake.receivedHandshake }
    var sendCipher = handshake.sendCipher
    var recvCipher = handshake.recvCipher

    // Greet as a seeder: all-ones bitfield + unchoke.
    let pieceCount = (content.count + pieceLength - 1) / pieceLength
    try await sendFrame(
      .bitfield(Data(repeating: 0xFF, count: (pieceCount + 7) / 8)), over: channel,
      cipher: &sendCipher)
    try await sendFrame(.unchoke, over: channel, cipher: &sendCipher)

    // Serve requests from the content stream until the client closes.
    while true {
      let message = try await readFrame(from: channel, cipher: &recvCipher)
      lock.withLock { _receivedMessages.append(message) }
      if case .request(let index, let begin, let length) = message {
        let start = index * pieceLength + begin
        guard start >= 0, start + length <= content.count else {
          throw FakeSeederError.badRequest(index: index, begin: begin, length: length)
        }
        let data = content.subdata(in: start..<(start + length))
        if serveDelay > .zero { try? await Task.sleep(for: serveDelay) }
        try await sendFrame(
          .piece(index: index, begin: begin, data: data), over: channel, cipher: &sendCipher)
      }
    }
  }

  private func sendFrame(_ message: WireMessage, over channel: FDByteChannel, cipher: inout RC4)
    async throws
  {
    var bytes = Array(WireCodec.encode(message))
    cipher.stream(&bytes)
    try await channel.write(Data(bytes))
  }

  private func readFrame(from channel: FDByteChannel, cipher: inout RC4) async throws -> WireMessage
  {
    var prefix = Array(try await channel.read(4))
    cipher.stream(&prefix)
    let length =
      (Int(prefix[0]) << 24) | (Int(prefix[1]) << 16) | (Int(prefix[2]) << 8) | Int(prefix[3])
    guard length <= WireCodec.maxPayloadLength else { throw WireCodecError.payloadTooLarge(length) }
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
}

enum FakeSeederError: Error {
  case timedOut
  case closed
  case noPort
  case posix(Int32)
  case badRequest(index: Int, begin: Int, length: Int)
}

/// Weak reference to the seeder for the accept thread (breaks the
/// thread → seeder → thread retain cycle).
private final class SeederBox: @unchecked Sendable { weak var seeder: FakeSeeder? }
