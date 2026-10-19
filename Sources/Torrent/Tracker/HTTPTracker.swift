import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
import Network

/// Parameters for a tracker announce (BEP 3).
public struct TrackerAnnounceParams: Sendable {
  /// 20 raw bytes — the torrent's info hash.
  public var infoHash: Data
  /// 20 raw bytes — this client's peer ID.
  public var peerID: Data
  /// The local port peers can connect to.
  public var port: UInt16
  /// Bytes uploaded so far (this client never uploads, so 0).
  public var uploaded: Int64 = 0
  /// Bytes downloaded so far.
  public var downloaded: Int64 = 0
  /// Bytes left to download.
  public var left: Int64
  /// Event: "started" | "completed" | "stopped" | nil.
  public var event: String?
  /// Requested number of peers.
  public var numwant: Int = 200

  public init(
    infoHash: Data, peerID: Data, port: UInt16, uploaded: Int64 = 0, downloaded: Int64 = 0,
    left: Int64, event: String? = nil, numwant: Int = 200
  ) {
    self.infoHash = infoHash
    self.peerID = peerID
    self.port = port
    self.uploaded = uploaded
    self.downloaded = downloaded
    self.left = left
    self.event = event
    self.numwant = numwant
  }
}

/// A parsed tracker announce response.
public struct TrackerResponse: Sendable {
  /// Seconds the client should wait before announcing again.
  public let interval: Int
  /// Peers to connect to (IPv4 compact `peers` plus any `peers6` entries).
  public let peers: [TrackerPeer]
  /// `complete` — number of seeders, when reported.
  public let seeders: Int?
  /// `incomplete` — number of leechers, when reported.
  public let leechers: Int?

  init(interval: Int, peers: [TrackerPeer], seeders: Int?, leechers: Int?) {
    self.interval = interval
    self.peers = peers
    self.seeders = seeders
    self.leechers = leechers
  }
}

public enum HTTPTrackerError: Error, Equatable {
  /// The tracker responded with a `failure reason`.
  case trackerError(String)
  /// The tracker's response was not a valid HTTP/bencode response.
  case badResponse
  /// The announce did not complete within the timeout.
  case timeout
  /// The connection could not be established (or failed mid-flight).
  case connectionFailed(String)
}

/// HTTP(S) tracker announce (BEP 3) over Network.framework raw TCP (+ TLS for
/// https). No URLSession, so there are no ATS concerns and it behaves
/// identically from tests and the app.
public enum HTTPTracker {
  private static let queue = DispatchQueue(label: "Torrent.HTTPTracker")

  /// Announce to an HTTP(S) tracker and return the decoded response.
  public static func announce(
    url: URL, params: TrackerAnnounceParams, timeout: Duration = .seconds(30)
  ) async throws -> TrackerResponse {
    let connection = try makeConnection(url: url)
    defer { connection.cancel() }
    return try await withThrowingTaskGroup(of: TrackerResponse.self) { group in
      group.addTask { try await perform(connection: connection, url: url, params: params) }
      group.addTask {
        try await Task.sleep(for: timeout)
        connection.cancel()
        throw HTTPTrackerError.timeout
      }
      let result: TrackerResponse
      do {
        guard let value = try await group.next() else { throw HTTPTrackerError.badResponse }
        result = value
      } catch {
        group.cancelAll()
        throw error
      }
      group.cancelAll()
      // Drain the (cancelled) timeout task's error so the group exits cleanly.
      while (try? await group.next()) != nil {}
      return result
    }
  }

  // MARK: - Connection

  private static func makeConnection(url: URL) throws -> NWConnection {
    guard let hostName = url.host else {
      throw HTTPTrackerError.connectionFailed("announce URL has no host: \(url.absoluteString)")
    }
    let port: UInt16
    if let explicit = url.port {
      guard explicit > 0, explicit < 65536 else {
        throw HTTPTrackerError.connectionFailed(
          "invalid port in announce URL: \(url.absoluteString)")
      }
      port = UInt16(explicit)
    } else {
      port = url.scheme == "https" ? 443 : 80
    }
    let parameters: NWParameters
    switch url.scheme {
    case "http": parameters = NWParameters.tcp
    case "https": parameters = NWParameters.tls
    default:
      throw HTTPTrackerError.connectionFailed("unsupported announce scheme: \(url.scheme ?? "nil")")
    }
    let endpoint = NWEndpoint.hostPort(
      host: NWEndpoint.Host(hostName), port: NWEndpoint.Port(rawValue: port)!)
    return NWConnection(to: endpoint, using: parameters)
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
        default: break
        }
      }
      connection.start(queue: Self.queue)
    }
  }

  private static func perform(connection: NWConnection, url: URL, params: TrackerAnnounceParams)
    async throws -> TrackerResponse
  {
    try await connect(connection: connection)
    let request = try buildRequest(url: url, params: params)
    try await send(connection: connection, data: request)
    let body = try await receiveBody(connection: connection)
    return try parseBody(body)
  }

  private static func send(connection: NWConnection, data: Data) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      connection.send(
        content: data, contentContext: .defaultMessage, isComplete: false,
        completion: .contentProcessed { error in
          if let error {
            cont.resume(throwing: HTTPTrackerError.connectionFailed(error.localizedDescription))
          } else {
            cont.resume(returning: ())
          }
        })
    }
  }

  // MARK: - HTTP response

  private static func receiveBody(connection: NWConnection) async throws -> Data {
    var buffer = Data()
    while true {
      if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        let (status, contentLength) = try parseHeaders(headerData)
        guard (200..<300).contains(status) else { throw HTTPTrackerError.badResponse }
        var body = buffer.subdata(in: headerEnd.upperBound..<buffer.endIndex)
        while body.count < contentLength {
          body.append(try await receiveChunk(connection: connection))
        }
        if body.count > contentLength {
          body = body.subdata(in: body.startIndex..<(body.startIndex + contentLength))
        }
        return body
      }
      guard buffer.count < 64 * 1024 else { throw HTTPTrackerError.badResponse }
      buffer.append(try await receiveChunk(connection: connection))
    }
  }

  private static func receiveChunk(connection: NWConnection) async throws -> Data {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
      connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
        data, _, _, error in
        if let error {
          cont.resume(throwing: HTTPTrackerError.connectionFailed(error.localizedDescription))
        } else if let data, !data.isEmpty {
          cont.resume(returning: data)
        } else {
          // Clean EOF before the body was fully read.
          cont.resume(throwing: HTTPTrackerError.badResponse)
        }
      }
    }
  }

  private static func parseHeaders(_ headerData: Data) throws -> (status: Int, contentLength: Int) {
    let text = String(decoding: headerData, as: UTF8.self)
    let lines = text.components(separatedBy: "\r\n")
    guard let statusLine = lines.first else { throw HTTPTrackerError.badResponse }
    let statusParts = statusLine.split(separator: " ", maxSplits: 2)
    guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
      throw HTTPTrackerError.badResponse
    }
    var contentLength: Int?
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      guard name == "content-length" else { continue }
      contentLength = Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }
    guard let contentLength else { throw HTTPTrackerError.badResponse }
    return (status, contentLength)
  }

  // MARK: - Response body

  private static func parseBody(_ body: Data) throws -> TrackerResponse {
    let value: BencodeValue
    do { value = try Bencode.parse(body) } catch { throw HTTPTrackerError.badResponse }
    guard case .dict(let dict) = value else { throw HTTPTrackerError.badResponse }

    if let reason = dict[Data("failure reason".utf8)], case .string(let bytes) = reason {
      throw HTTPTrackerError.trackerError(String(decoding: bytes, as: UTF8.self))
    }
    guard case .int(let interval)? = dict[Data("interval".utf8)] else {
      throw HTTPTrackerError.badResponse
    }
    guard case .string(let compact)? = dict[Data("peers".utf8)] else {
      throw HTTPTrackerError.badResponse
    }
    var peers = PeerList.decode(compact: compact)
    if let peers6 = dict[Data("peers6".utf8)], case .string(let v6bytes) = peers6 {
      peers.append(contentsOf: PeerList.decodeV6(compact: v6bytes))
    }
    var seeders: Int?
    if case .int(let n)? = dict[Data("complete".utf8)] { seeders = Int(n) }
    var leechers: Int?
    if case .int(let n)? = dict[Data("incomplete".utf8)] { leechers = Int(n) }
    return TrackerResponse(
      interval: Int(interval), peers: peers, seeders: seeders, leechers: leechers)
  }

  // MARK: - Request building

  /// Build the `?key=value&...` query string for an announce, with every byte of
  /// `info_hash`/`peer_id` percent-encoded except unreserved [A-Za-z0-9-._~].
  static func buildQuery(params: TrackerAnnounceParams) -> String {
    var parts: [String] = []
    parts.append("info_hash=" + percentEncode(params.infoHash))
    parts.append("peer_id=" + percentEncode(params.peerID))
    parts.append("port=" + String(params.port))
    parts.append("uploaded=" + String(params.uploaded))
    parts.append("downloaded=" + String(params.downloaded))
    parts.append("left=" + String(params.left))
    parts.append("compact=1")
    parts.append("numwant=" + String(params.numwant))
    if let event = params.event { parts.append("event=" + percentEncode(Data(event.utf8))) }
    return parts.joined(separator: "&")
  }

  /// The announce URL with the announce query appended to any existing query.
  static func buildRequestURL(url: URL, params: TrackerAnnounceParams) throws -> URL {
    let components = try buildRequestComponents(url: url, params: params)
    guard let built = components.url else {
      throw HTTPTrackerError.connectionFailed("invalid announce URL: \(url.absoluteString)")
    }
    return built
  }

  private static func buildRequestComponents(url: URL, params: TrackerAnnounceParams) throws
    -> URLComponents
  {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw HTTPTrackerError.connectionFailed("invalid announce URL: \(url.absoluteString)")
    }
    let newQuery = buildQuery(params: params)
    let existing = components.percentEncodedQuery ?? ""
    components.percentEncodedQuery = existing.isEmpty ? newQuery : existing + "&" + newQuery
    return components
  }

  /// The full HTTP/1.1 GET request bytes.
  static func buildRequest(url: URL, params: TrackerAnnounceParams) throws -> Data {
    let components = try buildRequestComponents(url: url, params: params)
    let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
    var request = "GET \(path)"
    if let query = components.percentEncodedQuery { request += "?" + query }
    request += " HTTP/1.1\r\n"
    var host = components.host ?? ""
    if let port = components.port {
      let isDefault =
        (components.scheme == "http" && port == 80) || (components.scheme == "https" && port == 443)
      if !isDefault { host += ":\(port)" }
    }
    request += "Host: \(host)\r\n"
    request += "User-Agent: Get/1.0\r\n"
    request += "Accept: */*\r\n"
    request += "Connection: close\r\n"
    request += "\r\n"
    return Data(request.utf8)
  }

  /// Percent-encode bytes, leaving unreserved [A-Za-z0-9-._~] untouched.
  static func percentEncode(_ data: Data) -> String {
    let hexDigits = Array("0123456789ABCDEF".utf8)
    var out = String.UnicodeScalarView()
    out.reserveCapacity(data.count * 3)
    for byte in data {
      switch byte {
      case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
        UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."),
        UInt8(ascii: "_"), UInt8(ascii: "~"):
        out.append(UnicodeScalar(byte))
      default:
        out.append(UnicodeScalar(UInt8(ascii: "%")))
        out.append(UnicodeScalar(hexDigits[Int(byte >> 4)]))
        out.append(UnicodeScalar(hexDigits[Int(byte & 0x0F)]))
      }
    }
    return String(out)
  }
}
