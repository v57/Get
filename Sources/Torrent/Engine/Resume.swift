import Foundation

/// Persisted verified-piece state for one torrent, used to resume an
/// interrupted download without re-fetching pieces that already verified.
///
/// Stored as JSON at `~/Library/Application Support/Get/<infohash-hex>.state`
/// (`{ "pieceLength": …, "totalSize": …, "verified": [int…] }`). Writes are
/// atomic (temp file + rename) so a crash mid-save can never corrupt the
/// previous snapshot. The verified list is trusted as-is on load; re-hashing
/// the files on start is a future option.
public struct ResumeState: Codable, Sendable, Equatable {
  /// The torrent's piece length in bytes.
  public var pieceLength: Int
  /// The torrent's total size in bytes.
  public var totalSize: Int64
  /// Piece indices verified and written to disk (ascending).
  public var verified: [Int]

  public init(pieceLength: Int, totalSize: Int64, verified: [Int]) {
    self.pieceLength = pieceLength
    self.totalSize = totalSize
    self.verified = verified
  }

  /// The on-disk location of this torrent's resume state:
  /// `~/Library/Application Support/Get/<infohash-hex>.state`.
  public static func fileURL(infoHash: Data) -> URL { fileURL(infoHashHex: hex(infoHash)) }

  /// The on-disk location of this torrent's resume state, given the
  /// infohash already formatted as hex (as the app keys downloads by).
  public static func fileURL(infoHashHex: String) -> URL {
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!.appendingPathComponent("Get", isDirectory: true)
    return directory.appendingPathComponent("\(infoHashHex).state")
  }

  /// Load the persisted state for `infoHash`, or nil when the file is
  /// missing or unreadable (corrupt JSON, wrong types, …).
  public static func load(infoHash: Data) -> ResumeState? {
    let url = fileURL(infoHash: infoHash)
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(ResumeState.self, from: data)
  }

  /// Atomically persist this state for `infoHash`: write a temp file in the
  /// same directory, then rename it over the destination (creating the
  /// directory tree first). Best effort — failures are swallowed so a
  /// failed snapshot can never fail the download.
  public func save(infoHash: Data) {
    let url = Self.fileURL(infoHash: infoHash)
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(self)
      let tempURL = url.deletingLastPathComponent().appendingPathComponent(
        "\(url.lastPathComponent).tmp-\(UUID().uuidString)")
      try data.write(to: tempURL)
      if FileManager.default.fileExists(atPath: url.path) {
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
      } else {
        try FileManager.default.moveItem(at: tempURL, to: url)
      }
    } catch {
      // Best effort: leave the previous snapshot (if any) in place.
    }
  }

  private static func hex(_ data: Data) -> String {
    data.reduce(into: "") { $0 += String(format: "%02x", $1) }
  }
}
