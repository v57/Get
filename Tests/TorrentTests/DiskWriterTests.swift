import Foundation
import Testing
@testable import Torrent

// MARK: - Helpers

/// Unique temp dir per test, removed on scope exit.
private func makeTempDir(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)")
}

private func fileSize(_ url: URL) throws -> Int64 {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs[.size] as? NSNumber)?.int64Value ?? -1
}

private func makeSingleFileWriter(name: String = "single.bin",
                                  content: Data,
                                  pieceLength: Int = 16 * 1024) throws -> (DiskWriter, FileLayout) {
    let (_, torrent, _) = try SyntheticTorrent.make(data: content, pieceLength: pieceLength, name: name)
    let layout = try FileLayout(torrent: torrent, baseDirectory: makeTempDir("DiskWriterSingle"))
    return (DiskWriter(layout: layout, pieceLength: torrent.pieceLength), layout)
}

private func makeTwoFileWriter(pieceLength: Int = 64) throws -> (DiskWriter, FileLayout, Data) {
    let files: [(path: [String], data: Data)] = [
        (["a.bin"], Data(repeating: 0x11, count: 100)),
        (["b.bin"], Data(repeating: 0x22, count: 100)),
    ]
    let (_, torrent, content) = try SyntheticTorrent.make(data: Data(), pieceLength: pieceLength, name: "straddle", files: files)
    let layout = try FileLayout(torrent: torrent, baseDirectory: makeTempDir("DiskWriterMulti"))
    return (DiskWriter(layout: layout, pieceLength: torrent.pieceLength), layout, content)
}

// MARK: - prepare()

@Test func prepareCreatesSingleFileWithExactSize() async throws {
    let content = Data(repeating: 0x5A, count: 40_000)
    let (writer, layout) = try makeSingleFileWriter(content: content)
    defer { try? FileManager.default.removeItem(at: layout.baseDirectory) }

    try await writer.prepare()
    let fileURL = layout.entries[0].url
    #expect(FileManager.default.fileExists(atPath: fileURL.path))
    #expect(try fileSize(fileURL) == Int64(content.count))
}

@Test func prepareCreatesMultiFileTreeWithExactSizes() async throws {
    let files: [(path: [String], data: Data)] = [
        (["a.txt"], Data(repeating: 0x01, count: 100)),
        (["sub", "b.txt"], Data(repeating: 0x02, count: 250)),
        (["empty.bin"], Data()),
    ]
    let (_, torrent, _) = try SyntheticTorrent.make(data: Data(), pieceLength: 64, name: "multi", files: files)
    let layout = try FileLayout(torrent: torrent, baseDirectory: makeTempDir("DiskWriterPrepareMulti"))
    defer { try? FileManager.default.removeItem(at: layout.baseDirectory) }
    let writer = DiskWriter(layout: layout, pieceLength: torrent.pieceLength)

    try await writer.prepare()

    // Subdirectory tree exists (b.txt can only exist under multi/sub/).
    for (i, entry) in layout.entries.enumerated() {
        #expect(FileManager.default.fileExists(atPath: entry.url.path), "entry \(i) missing at \(entry.url.path)")
        #expect(try fileSize(entry.url) == Int64(files[i].data.count))
    }
}

// MARK: - write(piece:data:)

@Test func writeFullPieceLandsBytesAtRightOffset() async throws {
    let content = Data((0..<40_000).map { UInt8($0 % 251) })
    let (writer, layout) = try makeSingleFileWriter(content: content)
    defer { try? FileManager.default.removeItem(at: layout.baseDirectory) }
    try await writer.prepare()

    let piece0 = content.subdata(in: 0..<16 * 1024)
    try await writer.write(piece: 0, data: piece0)

    let onDisk = try Data(contentsOf: layout.entries[0].url)
    #expect(onDisk.subdata(in: 0..<(16 * 1024)) == piece0)
    // Everything past the written piece is still zero (sparse preallocation).
    #expect(onDisk.dropFirst(16 * 1024).allSatisfy { $0 == 0 })
}

@Test func writeStraddlingPieceLandsInBothFiles() async throws {
    let (writer, layout, content) = try makeTwoFileWriter()
    defer { try? FileManager.default.removeItem(at: layout.baseDirectory) }
    try await writer.prepare()

    // Piece 1 = bytes 64..128 → a.bin[64..100] + b.bin[0..28].
    let piece1 = content.subdata(in: 64..<128)
    try await writer.write(piece: 1, data: piece1)

    let a = try Data(contentsOf: layout.entries[0].url)
    let b = try Data(contentsOf: layout.entries[1].url)
    #expect(a.subdata(in: 64..<100) == content.subdata(in: 64..<100))
    #expect(b.subdata(in: 0..<28) == content.subdata(in: 100..<128))
    // Untouched regions remain zero.
    #expect(a.prefix(64).allSatisfy { $0 == 0 })
    #expect(b.dropFirst(28).allSatisfy { $0 == 0 })
}

@Test func writeLastShortPieceWorks() async throws {
    let (writer, layout, content) = try makeTwoFileWriter() // 200 bytes total, pieceLength 64
    defer { try? FileManager.default.removeItem(at: layout.baseDirectory) }
    try await writer.prepare()

    // Last piece is index 3 = bytes 192..200: 8 bytes in b.bin at offset 92.
    let last = content.subdata(in: 192..<200)
    #expect(last.count == 8)
    try await writer.write(piece: 3, data: last)

    let b = try Data(contentsOf: layout.entries[1].url)
    #expect(b.subdata(in: 92..<100) == content.subdata(in: 192..<200))
}

@Test func writeRejectsWrongSizedData() async throws {
    let (writer, layout) = try makeSingleFileWriter(content: Data(repeating: 0x01, count: 40_000))
    defer { try? FileManager.default.removeItem(at: layout.baseDirectory) }
    try await writer.prepare()

    // Wire-sized data must never be trusted: a 100-byte payload for a
    // 16 KiB piece is rejected.
    await #expect(throws: (any Error).self) {
        try await writer.write(piece: 0, data: Data(repeating: 0x00, count: 100))
    }

    // The short last piece also rejects a full pieceLength payload.
    let (twoWriter, twoLayout, _) = try makeTwoFileWriter()
    defer { try? FileManager.default.removeItem(at: twoLayout.baseDirectory) }
    try await twoWriter.prepare()
    await #expect(throws: (any Error).self) {
        try await twoWriter.write(piece: 3, data: Data(repeating: 0x00, count: 64))
    }
}

@Test func overwriteSamePieceIsIdempotent() async throws {
    let content = Data((0..<40_000).map { UInt8($0 % 251) })
    let (writer, layout) = try makeSingleFileWriter(content: content)
    defer { try? FileManager.default.removeItem(at: layout.baseDirectory) }
    try await writer.prepare()

    let piece0 = content.subdata(in: 0..<16 * 1024)
    try await writer.write(piece: 0, data: piece0)
    try await writer.write(piece: 0, data: piece0)

    let onDisk = try Data(contentsOf: layout.entries[0].url)
    #expect(onDisk.subdata(in: 0..<(16 * 1024)) == piece0)
}

// MARK: - close()

@Test func closeFlushesWrites() async throws {
    let content = Data(repeating: 0x77, count: 40_000)
    let (writer, layout) = try makeSingleFileWriter(content: content)
    defer { try? FileManager.default.removeItem(at: layout.baseDirectory) }
    try await writer.prepare()

    let piece0 = content.subdata(in: 0..<16 * 1024)
    try await writer.write(piece: 0, data: piece0)
    await writer.close()

    // A fresh read after close() sees the flushed bytes.
    let onDisk = try Data(contentsOf: layout.entries[0].url)
    #expect(onDisk.subdata(in: 0..<(16 * 1024)) == piece0)
    #expect(onDisk.count == content.count)
}
