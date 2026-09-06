import Foundation

/// Persisted verified-piece state for one torrent, used to resume an
/// interrupted download without re-fetching pieces that already verified.
///
/// Stored as JSON at `~/Library/Application Support/Get/<infohash-hex>.state`
/// (`{ "pieceLength": …, "totalSize": …, "verified": [int…], "pausedFiles": …,
/// "priorities": …, "removedFiles": … }`). Writes are atomic (temp file +
/// rename) so a crash mid-save can never corrupt the previous snapshot. The
/// verified list is trusted as-is on load; re-hashing the files on start is a
/// future option.
///
/// Besides verified pieces, this carries the per-file download policy
/// (paused / priority / removed) so a download's file state survives a
/// relaunch — a file the user paused last session stays paused, a removed
/// file stays excluded, and priorities are re-applied. The per-file fields
/// decode as empty when absent so old state files (written before this was
/// added) still load.
public struct ResumeState: Codable, Sendable, Equatable {
  /// The torrent's piece length in bytes.
  public var pieceLength: Int
  /// The torrent's total size in bytes.
  public var totalSize: Int64
  /// Piece indices verified and written to disk (ascending).
  public var verified: [Int]
  /// File indices the user paused (their pieces are not fetched until resumed).
  public var pausedFiles: [Int] = []
  /// File index → download priority (1...4). Unprioritized files (absent)
  /// are fetched after every prioritized one.
  public var priorities: [Int: Int] = [:]
  /// File indices the user removed (excluded from fetching, not counted
  /// toward completion; their data was deleted).
  public var removedFiles: [Int] = []

  public init(
    pieceLength: Int, totalSize: Int64, verified: [Int], pausedFiles: [Int] = [],
    priorities: [Int: Int] = [:], removedFiles: [Int] = []
  ) {
    self.pieceLength = pieceLength
    self.totalSize = totalSize
    self.verified = verified
    self.pausedFiles = pausedFiles
    self.priorities = priorities
    self.removedFiles = removedFiles
  }

  private enum CodingKeys: String, CodingKey {
    case pieceLength, totalSize, verified, pausedFiles, priorities, removedFiles
  }

  /// Decode tolerantly: the per-file fields are optional so a state file
  /// written before they existed (old schema) still loads, defaulting to no
  /// per-file policy.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    pieceLength = try container.decode(Int.self, forKey: .pieceLength)
    totalSize = try container.decode(Int64.self, forKey: .totalSize)
    verified = try container.decode([Int].self, forKey: .verified)
    pausedFiles = try container.decodeIfPresent([Int].self, forKey: .pausedFiles) ?? []
    priorities = try container.decodeIfPresent([Int: Int].self, forKey: .priorities) ?? [:]
    removedFiles = try container.decodeIfPresent([Int].self, forKey: .removedFiles) ?? []
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

  /// Load the persisted state for an infohash already formatted as hex
  /// (matching how the app keys downloads).
  public static func load(infoHashHex: String) -> ResumeState? {
    let url = fileURL(infoHashHex: infoHashHex)
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
