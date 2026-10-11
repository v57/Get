import Foundation

/// Everything needed to continue a URL download after a pause or relaunch:
/// the source, the chosen file name, what the server said about the file,
/// and how far each segment got. Saved as JSON by the session.
public struct URLDownloadRecord: Codable, Sendable, Equatable {
  /// One byte range of the file, fetched over its own connection.
  public struct Segment: Codable, Sendable, Equatable {
    public var start: Int64
    /// The next byte to fetch: `start..<next` is on disk.
    public var next: Int64
    /// Exclusive end, or nil when the file's length is unknown (a single
    /// stream read to the end).
    public var end: Int64?

    public init(start: Int64, next: Int64? = nil, end: Int64?) {
      self.start = start
      self.next = next ?? start
      self.end = end
    }

    public var isDone: Bool { end.map { next >= $0 } ?? false }
    public var remaining: Int64? { end.map { $0 - next } }
  }

  public var url: URL
  /// The checksum the user gave, checked when the download finishes.
  public var checksum: Checksum?
  /// File name in the save directory, set by the first response.
  public var filename: String?
  /// File length, when the server reported it.
  public var totalBytes: Int64?
  /// Strong ETag or Last-Modified of the file: sent as `If-Range` so a file
  /// that changed on the server restarts instead of mixing two versions.
  public var validator: String?
  /// The server honours `Range` requests, so the file can be fetched in
  /// segments and a download can resume.
  public var acceptsRanges = false
  /// The checksum the server published (`Repr-Digest` / `Digest`), used when
  /// the user gave none.
  public var serverChecksum: Checksum?
  public var segments: [Segment] = []

  public init(url: URL, checksum: Checksum? = nil) {
    self.url = url
    self.checksum = checksum
  }

  /// Bytes on disk across all segments.
  public var receivedBytes: Int64 { segments.reduce(0) { $0 + ($1.next - $1.start) } }

  public static func load(from file: URL) -> URLDownloadRecord? {
    guard let data = try? Data(contentsOf: file) else { return nil }
    return try? JSONDecoder().decode(URLDownloadRecord.self, from: data)
  }

  /// Best effort: a failed save only means a relaunch starts over.
  public func save(to file: URL) {
    guard let data = try? JSONEncoder().encode(self) else { return }
    try? FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: file, options: .atomic)
  }
}
