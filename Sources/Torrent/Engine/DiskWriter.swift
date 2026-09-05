import CryptoKit
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
/// `prepare()` creates the directory tree. Single-file torrents preallocate
/// their one file to the exact torrent length (sparse via `ftruncate`), so the
/// final size is reserved and `read`/`hash` can read unwritten regions as
/// zeros. Multi-file torrents do NOT reserve space up front — `prepare()` only
/// creates each file empty, and it grows as pieces are written. `write(piece:
/// data:)` maps the piece's byte range through the layout into per-file spans
/// and writes each span with a cached, lazily-opened `FileHandle`. Piece sizes
/// are always derived from the torrent (`pieceLength`, except the last piece
/// which is `totalSize - index * pieceLength`) — wire-supplied lengths are
/// never trusted, and any payload of the wrong size is rejected.
public actor DiskWriter {
  private let layout: FileLayout
  private let pieceLength: Int
  private let totalSize: Int64
  private var handles: [Int: FileHandle] = [:]
  /// Files the user has removed from the download. Their on-disk data is
  /// deleted; `write` must NEVER recreate a removed file. A straddling piece
  /// that spans a kept file and a removed one writes the kept file's portion
  /// and skips the removed file's portion entirely.
  private var removedFiles: Set<Int> = []

  public init(layout: FileLayout, pieceLength: Int) {
    self.layout = layout
    self.pieceLength = pieceLength
    self.totalSize = layout.fileEnds.last ?? 0
  }

  /// Create the base directory (and all subdirectories) and, for single-file
  /// torrents, preallocate the file to its exact torrent length (sparse via
  /// `ftruncate`). Multi-file torrents create each file empty — no space is
  /// reserved up front, and files grow as pieces land.
  public func prepare() throws {
    try FileManager.default.createDirectory(
      at: layout.baseDirectory, withIntermediateDirectories: true)
    for (index, entry) in layout.entries.enumerated() {
      // A file the user removed must not be created at all — prepare must not
      // resurrect a file that was removed before start() (its data is gone).
      if removedFiles.contains(index) { continue }
      try FileManager.default.createDirectory(
        at: entry.url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let fd = open(entry.url.path, O_CREAT | O_RDWR, 0o644)
      guard fd >= 0 else {
        throw DiskWriterError.io("open failed for \(entry.url.path): \(errnoText())")
      }
      defer { Darwin.close(fd) }
      // Multi-file downloads must not reserve space for files the user may
      // not want (e.g. a file they'll remove). Create the file empty and let
      // it grow as pieces land. Single-file downloads still preallocate so
      // unwritten regions read back as zeros.
      guard !layout.isMultiFile else { continue }
      guard ftruncate(fd, entry.length) == 0 else {
        throw DiskWriterError.io("ftruncate failed for \(entry.url.path): \(errnoText())")
      }
    }
  }

  /// Record which files have been removed from the download so `write` skips
  /// them (never recreating a deleted file).
  public func setRemovedFiles(_ files: Set<Int>) { removedFiles = files }

  /// Delete one file's on-disk data and drop its cached handle. Best effort —
  /// a missing file is a no-op. The caller is responsible for removing the
  /// file from `removedFiles` if it gets restored.
  public func deleteFileData(_ fileIndex: Int) {
    guard fileIndex >= 0, fileIndex < layout.entries.count else { return }
    if let handle = handles.removeValue(forKey: fileIndex) { try? handle.close() }
    let url = layout.entries[fileIndex].url
    if FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.removeItem(at: url)
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
      // A removed file's data was deleted; never recreate it. Advance over the
      // removed file's bytes (they still exist in the assembled piece) but do
      // not write them — the kept portion of a straddling piece still lands.
      if removedFiles.contains(span.file) {
        dataOffset += span.length
        continue
      }
      let handle = try fileHandle(for: span.file, createIfMissing: true)
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
  ///   outside the torrent's piece range, or `DiskWriterError.io` if a
  ///   backing file does not exist (an unwritten multi-file piece).
  public func read(piece index: Int) throws -> Data {
    precondition(index >= 0, "piece index must be non-negative")
    let pieceStart = Int64(index) * Int64(pieceLength)
    guard pieceStart < totalSize else { throw DiskWriterError.pieceIndexOutOfRange(index: index) }
    let pieceEnd = pieceStart + min(Int64(pieceLength), totalSize - pieceStart)
    let spans = layout.spans(forPieceRange: pieceStart..<pieceEnd)
    var out = Data()
    out.reserveCapacity(Int(pieceEnd - pieceStart))
    for span in spans {
      let handle = try fileHandle(for: span.file, createIfMissing: false)
      handle.seek(toFileOffset: UInt64(span.offset))
      guard let chunk = try handle.read(upToCount: span.length) else {
        throw DiskWriterError.io("read failed for \(entryURL(span.file)) at \(span.offset)")
      }
      out.append(chunk)
    }
    return out
  }

  /// Stream one piece's bytes through SHA-1 and return the 20-byte digest,
  /// WITHOUT ever building the whole piece as a `Data`.
  ///
  /// The resume-on-launch re-verify used to call `read(piece:)` in a loop,
  /// allocating a full piece-sized `Data` per piece. On a large download the
  /// transient heap blew up to tens of GB (the "loads 19 GB on launch" leak —
  /// the bytes were held and only released once the whole scan finished).
  /// Streaming the hash keeps the scan's memory O(chunk size) regardless of
  /// how many pieces are claimed. A missing backing file (an unwritten
  /// multi-file piece) throws, which the caller treats as "not verified".
  public func hash(piece index: Int) throws -> Data {
    precondition(index >= 0, "piece index must be non-negative")
    let pieceStart = Int64(index) * Int64(pieceLength)
    guard pieceStart < totalSize else { throw DiskWriterError.pieceIndexOutOfRange(index: index) }
    let pieceEnd = pieceStart + min(Int64(pieceLength), totalSize - pieceStart)
    let spans = layout.spans(forPieceRange: pieceStart..<pieceEnd)
    var hasher = Insecure.SHA1()
    let chunkSize = 256 * 1024
    // One fixed-size Data reused for every read — no per-chunk allocation.
    // (FileHandle.read would malloc+free a fresh Data on each chunk, churning
    // through the whole resume scan.) A Data slice shares that same storage,
    // so feeding the hasher `buffer[0..<n]` is also zero-copy.
    var buffer = Data(count: chunkSize)
    for span in spans {
      let handle = try fileHandle(for: span.file, createIfMissing: false)
      handle.seek(toFileOffset: UInt64(span.offset))
      let fd = handle.fileDescriptor
      var remaining = span.length
      while remaining > 0 {
        let n = min(remaining, chunkSize)
        let count = buffer.withUnsafeMutableBytes { p -> Int in
          Darwin.read(fd, p.baseAddress, n)
        }
        guard count > 0 else {
          throw DiskWriterError.io("read failed for \(entryURL(span.file)) at \(span.offset)")
        }
        hasher.update(data: buffer[0..<count])
        remaining -= count
      }
    }
    return Data(hasher.finalize())
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
  ///
  /// When `createIfMissing` is true and the file does not exist (a multi-file
  /// torrent that starts empty, or a file restored after being removed), the
  /// file is created empty first; `write` extends it as pieces land. When
  /// false (read/hash), a missing file throws so the caller treats the piece
  /// as not verified rather than silently reading nothing.
  private func fileHandle(for file: Int, createIfMissing: Bool) throws -> FileHandle {
    if let handle = handles[file] { return handle }
    let url = layout.entries[file].url
    if !FileManager.default.fileExists(atPath: url.path) {
      guard createIfMissing else {
        throw DiskWriterError.io("file missing: \(url.path)")
      }
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let handle = try FileHandle(forUpdating: url)
    handles[file] = handle
    return handle
  }

  private func errnoText() -> String { String(cString: strerror(errno)) }
}
