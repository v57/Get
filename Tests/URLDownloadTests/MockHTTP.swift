import Foundation

/// An in-process HTTP server for URL download tests: a `URLProtocol` that
/// serves registered resources under `https://mock.test/<path>`, with byte
/// ranges, `If-Range`, injected failures and request logging. No sockets, so
/// the suite stays hermetic.
final class MockHTTP: URLProtocol, @unchecked Sendable {
  struct Resource {
    var data: Data
    var acceptsRanges = true
    var etag: String? = "\"v1\""
    var headers: [String: String] = [:]
    /// Overrides the status of every response (e.g. 404).
    var status: Int?
    /// The next `failures` responses send this many body bytes, then drop
    /// the connection.
    var failAfter: Int?
    var failures = 0
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var resources: [String: Resource] = [:]
  nonisolated(unsafe) private static var log: [URLRequest] = []

  /// Register `resource` and return its URL. Paths must be unique per test
  /// (tests run in parallel).
  static func serve(_ resource: Resource, at path: String) -> URL {
    lock.withLock { resources[path] = resource }
    return URL(string: "https://mock.test/\(path)")!
  }

  static func update(_ path: String, _ change: (inout Resource) -> Void) {
    lock.withLock { change(&resources[path]!) }
  }

  static func requests(for path: String) -> [URLRequest] {
    lock.withLock { log.filter { $0.url?.path == "/\(path)" } }
  }

  static func configuration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockHTTP.self]
    return configuration
  }

  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "mock.test" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    let path = String(request.url!.path.dropFirst())
    let (resource, failAfter): (Resource?, Int?) = Self.lock.withLock {
      Self.log.append(request)
      guard var resource = Self.resources[path] else { return (nil, nil) }
      var failAfter: Int?
      if resource.failures > 0 {
        resource.failures -= 1
        failAfter = resource.failAfter
        Self.resources[path] = resource
      }
      return (resource, failAfter)
    }
    guard let resource else { return respond(status: 404, headers: [:], body: Data()) }
    if let status = resource.status { return respond(status: status, headers: [:], body: Data()) }

    let total = resource.data.count
    var headers = resource.headers
    if let etag = resource.etag { headers["ETag"] = etag }
    var range: Range<Int>?
    if resource.acceptsRanges, let header = request.value(forHTTPHeaderField: "Range"),
      header.hasPrefix("bytes=")
    {
      let ifRange = request.value(forHTTPHeaderField: "If-Range")
      if ifRange == nil || ifRange == resource.etag {
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        let start = Int(parts[0])!
        let end = parts.count > 1 && !parts[1].isEmpty ? Int(parts[1])! + 1 : total
        guard start < total else {
          return respond(status: 416, headers: ["Content-Range": "bytes */\(total)"], body: Data())
        }
        range = start..<min(end, total)
      }
    }
    if resource.acceptsRanges { headers["Accept-Ranges"] = "bytes" }
    if let range {
      headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(total)"
      respond(status: 206, headers: headers, body: resource.data[range], failAfter: failAfter)
    } else {
      respond(status: 200, headers: headers, body: resource.data, failAfter: failAfter)
    }
  }

  private func respond(status: Int, headers: [String: String], body: Data, failAfter: Int? = nil) {
    var headers = headers
    headers["Content-Length"] = String(body.count)
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    let limit = failAfter.map { min($0, body.count) } ?? body.count
    var offset = body.startIndex
    while offset < body.startIndex + limit {
      let end = min(offset + 8 * 1024, body.startIndex + limit)
      client?.urlProtocol(self, didLoad: body[offset..<end])
      offset = end
    }
    if failAfter != nil {
      // Drop the connection a moment later, as a network would: failing in
      // the same breath makes URLSession discard the bytes still queued for
      // the delegate.
      DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) {
        self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
      }
    } else {
      client?.urlProtocolDidFinishLoading(self)
    }
  }
}
