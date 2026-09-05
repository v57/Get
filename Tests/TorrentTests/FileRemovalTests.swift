import Foundation
import Testing

@testable import Torrent

// MARK: - Helpers

private let peerA = PeerID(raw: Data([1]))

private func makeTempDir(_ name: String) -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
}

private func fileSize(_ url: URL) throws -> Int64 {
  let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
  return (attrs[.size] as? NSNumber)?.int64Value ?? -1
}

private func makePicker(pieceCount: Int = 10, pieceLength: Int = 16 * 1024) -> PiecePicker {
  PiecePicker(pieceCount: pieceCount, pieceLength: pieceLength, lastPieceLength: pieceLength)
}

private func makeTwoFileWriter(pieceLength: Int = 64) throws -> (DiskWriter, FileLayout, Data) {
  let files: [(path: [String], data: Data)] = [
    (["a.bin"], Data(repeating: 0x11, count: 100)), (["b.bin"], Data(repeating: 0x22, count: 100)),
  ]
  let (_, torrent, content) = try SyntheticTorrent.make(
    data: Data(), pieceLength: pieceLength, name: "straddle", files: files)
  let layout = try FileLayout(torrent: torrent, baseDirectory: makeTempDir("FileRemoval"))
  return (DiskWriter(layout: layout, pieceLength: torrent.pieceLength), layout, content)
}

// MARK: - FileLayout.isMultiFile

@Test func isMultiFileDistinguishesSingleAndMulti() throws {
  // Single-file torrent → one entry, not multi-file.
  let (_, single, _) = try SyntheticTorrent.make(
    data: Data(repeating: 0x01, count: 100), pieceLength: 64, name: "single.bin")
  let singleLayout = try FileLayout(torrent: single, baseDirectory: makeTempDir("ismulti-single"))
  #expect(!singleLayout.isMultiFile)

  // Two-file torrent → multi-file.
  let files: [(path: [String], data: Data)] = [
    (["a.bin"], Data(repeating: 0x02, count: 100)), (["b.bin"], Data(repeating: 0x03, count: 100)),
  ]
  let (_, multi, _) = try SyntheticTorrent.make(
    data: Data(), pieceLength: 64, name: "multi", files: files)
  let multiLayout = try FileLayout(torrent: multi, baseDirectory: makeTempDir("ismulti-multi"))
  #expect(multiLayout.isMultiFile)
}

// MARK: - TorrentSession.piecesTouchingFile

@Test func piecesTouchingFileIncludesStraddlingPieces() {
  // Two 100-byte files, 64-byte pieces. File 0 = [0,100), File 1 = [100,200).
  let fileEnds: [Int64] = [100, 200]
  // Pieces touching file 0: piece 0 (0..64) + piece 1 (64..128) — it far
  // ends into file 0 only up to byte 100, but its range starts at 64.
  #expect(
    TorrentSession.piecesTouchingFile(
      fileEnds: fileEnds, pieceLength: 64, totalSize: 200, file: 0) == [0, 1])
  // Pieces touching file 1: piece 1 (64..128, straddles in), piece 2
  // (128..192), piece 3 (192..200 short last piece).
  #expect(
    TorrentSession.piecesTouchingFile(
      fileEnds: fileEnds, pieceLength: 64, totalSize: 200, file: 1) == [1, 2, 3])
  // Out-of-range file → empty.
  #expect(
    TorrentSession.piecesTouchingFile(
      fileEnds: fileEnds, pieceLength: 64, totalSize: 200, file: 7).isEmpty)
}

// MARK: - PiecePicker

@Test func unverifyRewindsFrontierToRefetch() {
  var picker = makePicker(pieceCount: 10)
  picker.advancePast(0)
  picker.advancePast(1)
  picker.advancePast(2)
  #expect(picker.cursor == 3)

  // Un-verify a piece below the frontier: the frontier must rewind to it so
  // it is fetched again (e.g. its file was removed and its data deleted).
  picker.unverify(1)
  #expect(picker.cursor == 1, "unverify must rewind the frontier to the lowest uncompleted piece")
  #expect(picker.completed == [0, 2])
}

@Test func dropPendingRemovesOnlyGivenPieces() {
  var picker = makePicker(pieceCount: 10)
  picker.setAllAvailable(on: peerA)
  _ = picker.request(for: peerA, pipeline: 10)  // piece 0
  _ = picker.request(for: peerA, pipeline: 10)  // piece 1
  #expect(picker.pending[peerA]?.count == 2)

  let dropped = picker.dropPending(forPieces: [1], on: peerA)
  #expect(dropped == [PiecePicker.BlockKey(piece: 1, begin: 0)])
  #expect(picker.pending[peerA] == Set([PiecePicker.BlockKey(piece: 0, begin: 0)]))
}

// MARK: - DiskWriter removed-file handling

@Test func writeSkipsRemovedFileSpan() async throws {
  // Piece 1 (bytes 64..128) straddles a.bin[64..100] + b.bin[0..28]. Removing
  // file 1 (b.bin) must write only a.bin's span and never recreate b.bin.
  let (writer, layout, content) = try makeTwoFileWriter()
  defer { try? FileManager.default.removeItem(at: layout.baseDirectory) }
  try await writer.prepare()
  // Simulate the session removing file 1: delete its data and tell the writer.
  await writer.deleteFileData(1)
  await writer.setRemovedFiles([1])

  try await writer.write(piece: 1, data: content.subdata(in: 64..<128))

  // The kept file's span landed.
  let a = try Data(contentsOf: layout.entries[0].url)
  #expect(a.subdata(in: 64..<100) == content.subdata(in: 64..<100))
  // The removed file must NOT be recreated by the straddling write.
  #expect(!FileManager.default.fileExists(atPath: layout.entries[1].url.path))
}

@Test func deleteFileDataRemovesOnDiskFile() async throws {
  let (writer, layout, _) = try makeTwoFileWriter()
  defer { try? FileManager.default.removeItem(at: layout.baseDirectory) }
  try await writer.prepare()
  #expect(FileManager.default.fileExists(atPath: layout.entries[1].url.path))
  #expect(try fileSize(layout.entries[1].url) == 0)

  await writer.deleteFileData(1)
  #expect(!FileManager.default.fileExists(atPath: layout.entries[1].url.path))
}

@Test func writeRecreatesDeletedFileOnRestore() async throws {
  let (writer, layout, content) = try makeTwoFileWriter()
  defer { try? FileManager.default.removeItem(at: layout.baseDirectory) }
  try await writer.prepare()
  // Remove file 1, then restore it (clear removedFiles); a write must
  // recreate the file on demand.
  await writer.deleteFileData(1)
  #expect(!FileManager.default.fileExists(atPath: layout.entries[1].url.path))

  await writer.setRemovedFiles([])
  // Piece 3 = 192..200 → b.bin[92..100]. The short last piece.
  try await writer.write(piece: 3, data: content.subdata(in: 192..<200))

  #expect(FileManager.default.fileExists(atPath: layout.entries[1].url.path))
  let b = try Data(contentsOf: layout.entries[1].url)
  #expect(b.subdata(in: 92..<100) == content.subdata(in: 192..<200))
}

