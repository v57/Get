import Foundation

/// Errors thrown while resolving a torrent's files to disk locations.
public enum FileLayoutError: Error, Equatable, Sendable {
  /// A path component is empty, ".", "..", or contains "/", "\", or NUL.
  case invalidPathComponent(String)
}

/// Maps a torrent's content stream onto concrete files on disk.
///
/// Every torrent file is resolved under `baseDirectory/<name>/…` (multi-file)
/// or directly at `baseDirectory/<name>` (single-file). All path components —
/// including the torrent's own `name` — come from untrusted `.torrent` files
/// and are run through `sanitize` so a malicious name can never escape the
/// base directory. `spans(forPieceRange:)` converts piece byte ranges into
/// (file, offsetInFile, length) segments, since a piece may straddle files.
public struct FileLayout: Sendable {
  /// Download root; every entry lives under this directory.
  public let baseDirectory: URL
  /// Resolved files in torrent order: relative path (torrent name first),
  /// length, and the absolute file URL.
  public let entries: [Entry]
  /// Prefix sums of entry lengths: `fileEnds[i]` is the exclusive end of
  /// file `i` in the torrent's content stream.
  public let fileEnds: [Int64]

  public struct Entry: Sendable {
    /// Path components relative to `baseDirectory`, torrent name first.
    public let path: [String]
    /// File size in bytes (from the torrent, never the wire).
    public let length: Int64
    /// Absolute URL of the file on disk.
    public let url: URL
  }

  /// Resolve every torrent file under `baseDirectory`.
  ///
  /// Single-file torrents (whose sole entry's path is `[name]`) land
  /// directly at `baseDirectory/<name>`; multi-file torrents at
  /// `baseDirectory/<name>/<path components>`. Throws `FileLayoutError`
  /// if any component — including `torrent.name` — fails `sanitize`.
  public init(torrent: TorrentFile, baseDirectory: URL) throws {
    self.baseDirectory = baseDirectory
    let safeName = try Self.sanitize(torrent.name)

    // A single-file torrent synthesizes one entry whose path is [name];
    // it lives directly in the save directory, not in a name/ subdir.
    let isSingleFile = torrent.files.count == 1 && torrent.files[0].path == [torrent.name]

    var entries: [Entry] = []
    entries.reserveCapacity(torrent.files.count)
    if isSingleFile {
      let file = torrent.files[0]
      entries.append(
        Entry(
          path: [safeName], length: file.length, url: baseDirectory.appendingPathComponent(safeName)
        ))
    } else {
      for file in torrent.files {
        var components = [safeName]
        components.reserveCapacity(file.path.count + 1)
        for component in file.path { components.append(try Self.sanitize(component)) }
        var url = baseDirectory
        for component in components { url.appendPathComponent(component) }
        entries.append(Entry(path: components, length: file.length, url: url))
      }
    }

    var ends: [Int64] = []
    ends.reserveCapacity(entries.count)
    var running: Int64 = 0
    for entry in entries {
      running += entry.length
      ends.append(running)
    }
    self.entries = entries
    self.fileEnds = ends
  }

  /// The top-level thing this torrent owns on disk: the single file itself
  /// for single-file torrents, the `<name>/` directory for multi-file ones.
  /// This is the natural unit for "move the download to Trash".
  public var rootURL: URL {
    guard let first = entries.first else { return baseDirectory }
    return baseDirectory.appendingPathComponent(first.path[0])
  }

  /// Map a byte range of the torrent's content stream to disk segments.
  ///
  /// Returns one `(file, offset, length)` tuple per file the range touches,
  /// in file order. `offset` is relative to the start of that file and
  /// `length` the number of bytes to write there. Zero-length files are
  /// skipped. The range must lie within `0..<totalSize`.
  public func spans(forPieceRange range: Range<Int64>) -> [(file: Int, offset: Int64, length: Int)]
  {
    precondition(range.lowerBound >= 0, "piece range starts before the content stream")
    precondition(
      range.upperBound <= (fileEnds.last ?? 0), "piece range ends past the content stream")

    var result: [(file: Int, offset: Int64, length: Int)] = []
    var cursor = range.lowerBound
    var fileIndex = 0
    while cursor < range.upperBound && fileIndex < entries.count {
      let fileEnd = fileEnds[fileIndex]
      if cursor < fileEnd {
        let fileStart = fileIndex == 0 ? 0 : fileEnds[fileIndex - 1]
        let spanEnd = min(range.upperBound, fileEnd)
        result.append((file: fileIndex, offset: cursor - fileStart, length: Int(spanEnd - cursor)))
        cursor = spanEnd
      }
      fileIndex += 1
    }
    return result
  }

  /// The index of the file containing byte `offset` of the content stream.
  ///
  /// Binary search over the prefix sums; a zero-length file never contains
  /// any byte, so offsets land in the file whose range strictly contains
  /// them. The offset must lie within `0..<totalSize`.
  public func fileIndex(ofByteOffset offset: Int64) -> Int {
    precondition(offset >= 0, "byte offset is negative")
    precondition(offset < (fileEnds.last ?? 0), "byte offset past the content stream")
    var low = 0
    var high = entries.count - 1
    while low < high {
      let mid = (low + high) / 2
      if offset < fileEnds[mid] { high = mid } else { low = mid + 1 }
    }
    return low
  }

  /// Validate one path component from an untrusted torrent.
  ///
  /// Rejects empty components, ".", "..", and any component containing "/",
  /// "\", or a NUL byte — the path-traversal defense. Spaces and UTF-8 are
  /// allowed. Returns the component unchanged on success.
  public static func sanitize(_ component: String) throws -> String {
    guard !component.isEmpty else { throw FileLayoutError.invalidPathComponent(component) }
    guard component != ".", component != ".." else {
      throw FileLayoutError.invalidPathComponent(component)
    }
    guard !component.contains("/"), !component.contains("\\"), !component.contains("\0") else {
      throw FileLayoutError.invalidPathComponent(component)
    }
    return component
  }
}
