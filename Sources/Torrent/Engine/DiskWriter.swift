import Foundation

/// Errors thrown by `DiskWriter`.
public enum DiskWriterError: Error, Equatable, Sendable {
  /// The piece payload did not match the torrent-derived piece size.
  case pieceSizeMismatch(index: Int, expected: Int, actual: Int)
  /// The piece index is outside the torrent's piece range.
  case pieceIndexOutOfRange(index: Int)
  /// An OS-level file operation failed (open/ftruncate/write).
  case io(String)
}

/// Writes verified piece bytes to the files described by a `FileLayout`.
///
/// `prepare()` creates the directory tree and preallocates every file to its
/// exact torrent length (sparse via `ftruncate`). `write(piece:data:)` maps
/// the piece's byte range through the layout into per-file spans and writes
/// each span with a cached, lazily-opened `FileHandle`. Piece sizes are always
/// derived from the torrent (`pieceLength`, except the last piece which is
/// `totalSize - index * pieceLength`) — wire-supplied lengths are never
/// trusted, and any payload of the wrong size is rejected.
public actor DiskWriter {
  private let layout: FileLayout
  private let pieceLength: Int
  private let totalSize: Int64
  private var handles: [Int: FileHandle] = [:]

  public init(layout: FileLayout, pieceLength: Int) {
    self.layout = layout
    self.pieceLength = pieceLength
    self.totalSize = layout.fileEnds.last ?? 0
  }

  /// Create the base directory (and all subdirectories) and preallocate
  /// every file to its exact torrent length. Sparse files are fine — the
  /// preallocation guarantees the final size and reserves the space.
  public func prepare() throws {
    try FileManager.default.createDirectory(
      at: layout.baseDirectory, withIntermediateDirectories: true)
    for entry in layout.entries {
      try FileManager.default.createDirectory(
        at: entry.url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let fd = open(entry.url.path, O_CREAT | O_RDWR, 0o644)
      guard fd >= 0 else {
        throw DiskWriterError.io("open failed for \(entry.url.path): \(errnoText())")
      }
      defer { Darwin.close(fd) }
      guard ftruncate(fd, entry.length) == 0 else {
        throw DiskWriterError.io("ftruncate failed for \(entry.url.path): \(errnoText())")
      }
    }
  }

  /// Write one verified piece to disk.
  ///
  /// - Parameters:
  ///   - index: piece index in the torrent's piece order.
  ///   - data: exactly `pieceLength` bytes (or the truncated last piece).
  /// - Throws: `DiskWriterError.pieceSizeMismatch` if `data.count` differs
  ///   from the torrent-derived piece size.
  public func write(piece index: Int, data: Data) throws {
    precondition(index >= 0, "piece index must be non-negative")
    let pieceStart = Int64(index) * Int64(pieceLength)
    guard pieceStart < totalSize else { throw DiskWriterError.pieceIndexOutOfRange(index: index) }
    let remaining = totalSize - pieceStart
    let pieceEnd = pieceStart + min(Int64(pieceLength), remaining)
    let expected = Int(pieceEnd - pieceStart)
    guard data.count == expected else {
      throw DiskWriterError.pieceSizeMismatch(index: index, expected: expected, actual: data.count)
    }

    let spans = layout.spans(forPieceRange: pieceStart..<pieceEnd)
    var dataOffset = 0
    for span in spans {
      let handle = try fileHandle(for: span.file)
      handle.seek(toFileOffset: UInt64(span.offset))
      let chunk = data.subdata(in: dataOffset..<(dataOffset + span.length))
      try handle.write(contentsOf: chunk)
      dataOffset += span.length
    }
  }

  /// Read back one piece's bytes from disk (used to re-verify pieces
  /// claimed by persisted resume state before trusting them).
  ///
  /// Returns the piece's exact torrent-derived byte range (`pieceLength`,
  /// except the last piece which is `totalSize - index * pieceLength`).
  /// - Throws: `DiskWriterError.pieceIndexOutOfRange` if the piece index is
  ///   outside the torrent's piece range.
  public func read(piece index: Int) throws -> Data {
    precondition(index >= 0, "piece index must be non-negative")
    let pieceStart = Int64(index) * Int64(pieceLength)
    guard pieceStart < totalSize else { throw DiskWriterError.pieceIndexOutOfRange(index: index) }
    let pieceEnd = pieceStart + min(Int64(pieceLength), totalSize - pieceStart)
    let spans = layout.spans(forPieceRange: pieceStart..<pieceEnd)
    var out = Data()
    out.reserveCapacity(Int(pieceEnd - pieceStart))
    for span in spans {
      let handle = try fileHandle(for: span.file)
      handle.seek(toFileOffset: UInt64(span.offset))
      guard let chunk = try handle.read(upToCount: span.length) else {
        throw DiskWriterError.io("read failed for \(entryURL(span.file)) at \(span.offset)")
      }
      out.append(chunk)
    }
    return out
  }

  /// Flush and close every cached file handle.
  public func close() {
    for (_, handle) in handles {
      try? handle.synchronize()
      try? handle.close()
    }
    handles.removeAll()
  }

  // MARK: - Helpers

  private func entryURL(_ file: Int) -> String {
    layout.entries.indices.contains(file) ? layout.entries[file].url.path : "<unknown>"
  }

  /// Lazily open (read-write, without truncation) and cache a file handle.
  private func fileHandle(for file: Int) throws -> FileHandle {
    if let handle = handles[file] { return handle }
    let url = layout.entries[file].url
    let handle = try FileHandle(forUpdating: url)
    handles[file] = handle
    return handle
  }

  private func errnoText() -> String { String(cString: strerror(errno)) }
}
