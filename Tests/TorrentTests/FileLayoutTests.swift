import Foundation
import Testing
@testable import Torrent

// MARK: - Helpers

/// Unique temp dir per test, removed on scope exit.
private func makeTempDir(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)")
}

private func url(_ base: URL, _ components: String...) -> URL {
    components.reduce(base) { $0.appendingPathComponent($1) }
}

// MARK: - Layout resolution

@Test func singleFileResolvesToBaseNameWithCorrectLength() throws {
    let content = Data("hello world, this is a single-file torrent payload".utf8)
    let (_, torrent, _) = try SyntheticTorrent.make(data: content, pieceLength: 16, name: "solo.bin")
    let base = makeTempDir("FileLayoutSingle")
    defer { try? FileManager.default.removeItem(at: base) }

    let layout = try FileLayout(torrent: torrent, baseDirectory: base)
    #expect(layout.entries.count == 1)
    #expect(layout.entries[0].path == ["solo.bin"])
    #expect(layout.entries[0].length == Int64(content.count))
    #expect(layout.entries[0].url == url(base, "solo.bin"))
    #expect(layout.fileEnds == [Int64(content.count)])
}

@Test func multiFileResolvesPathsIncludingSubdirectories() throws {
    let files: [(path: [String], data: Data)] = [
        (["a.txt"], Data("AAAA".utf8)),
        (["sub", "b.txt"], Data("BBBBBB".utf8)),
        (["empty.bin"], Data()),
    ]
    let (_, torrent, _) = try SyntheticTorrent.make(data: Data(), pieceLength: 4, name: "multi", files: files)
    let base = makeTempDir("FileLayoutMulti")
    defer { try? FileManager.default.removeItem(at: base) }

    let layout = try FileLayout(torrent: torrent, baseDirectory: base)
    #expect(layout.entries.count == 3)
    #expect(layout.entries[0].path == ["multi", "a.txt"])
    #expect(layout.entries[0].length == 4)
    #expect(layout.entries[0].url == url(base, "multi", "a.txt"))
    #expect(layout.entries[1].path == ["multi", "sub", "b.txt"])
    #expect(layout.entries[1].length == 6)
    #expect(layout.entries[1].url == url(base, "multi", "sub", "b.txt"))
    #expect(layout.entries[2].length == 0)
    #expect(layout.entries[2].url == url(base, "multi", "empty.bin"))
    #expect(layout.fileEnds == [4, 10, 10])
}

// MARK: - rootURL (Trash unit)

@Test func rootURLIsTheFileForSingleFileTorrents() throws {
    let content = Data("single-file torrent payload".utf8)
    let (_, torrent, _) = try SyntheticTorrent.make(data: content, pieceLength: 16, name: "solo.bin")
    let base = makeTempDir("FileLayoutRootSingle")
    defer { try? FileManager.default.removeItem(at: base) }

    let layout = try FileLayout(torrent: torrent, baseDirectory: base)
    #expect(layout.rootURL == url(base, "solo.bin"),
            "single-file root should be the file itself")
}

@Test func rootURLIsTheNameDirectoryForMultiFileTorrents() throws {
    let files: [(path: [String], data: Data)] = [
        (["a.txt"], Data("AAAA".utf8)),
        (["sub", "b.txt"], Data("BBBBBB".utf8)),
    ]
    let (_, torrent, _) = try SyntheticTorrent.make(data: Data(), pieceLength: 4,
                                                    name: "multi", files: files)
    let base = makeTempDir("FileLayoutRootMulti")
    defer { try? FileManager.default.removeItem(at: base) }

    let layout = try FileLayout(torrent: torrent, baseDirectory: base)
    #expect(layout.rootURL == url(base, "multi"),
            "multi-file root should be the <name>/ directory")
}

// MARK: - Piece → (file, offset, length) spans

/// Content: file0 = 100 bytes, file1 = 100 bytes, pieceLength 64.
/// Piece 0 = bytes 0..64 (file 0, offset 0), piece 2 = bytes 128..192
/// (file 1, offset 28), last piece 3 = bytes 192..200 (file 1, offset 92).
private func makeTwoFileLayout() throws -> FileLayout {
    let files: [(path: [String], data: Data)] = [
        (["a.bin"], Data(repeating: 0x11, count: 100)),
        (["b.bin"], Data(repeating: 0x22, count: 100)),
    ]
    let (_, torrent, _) = try SyntheticTorrent.make(data: Data(), pieceLength: 64, name: "spans", files: files)
    return try FileLayout(torrent: torrent, baseDirectory: makeTempDir("FileLayoutSpans"))
}

@Test func spansForPieceInsideOneFile() throws {
    let layout = try makeTwoFileLayout()

    let first = layout.spans(forPieceRange: 0..<64)
    #expect(first.count == 1)
    #expect(first[0].file == 0)
    #expect(first[0].offset == 0)
    #expect(first[0].length == 64)

    let midFile1 = layout.spans(forPieceRange: 128..<192)
    #expect(midFile1.count == 1)
    #expect(midFile1[0].file == 1)
    #expect(midFile1[0].offset == 28)
    #expect(midFile1[0].length == 64)

    let lastShort = layout.spans(forPieceRange: 192..<200)
    #expect(lastShort.count == 1)
    #expect(lastShort[0].file == 1)
    #expect(lastShort[0].offset == 92)
    #expect(lastShort[0].length == 8)
}

@Test func spansForPieceStraddlingTwoFiles() throws {
    let layout = try makeTwoFileLayout()

    // Piece 1 = bytes 64..128: file 0 at offset 64 (36 bytes) + file 1 at
    // offset 0 (28 bytes).
    let spans = layout.spans(forPieceRange: 64..<128)
    #expect(spans.count == 2)
    #expect(spans[0].file == 0)
    #expect(spans[0].offset == 64)
    #expect(spans[0].length == 36)
    #expect(spans[1].file == 1)
    #expect(spans[1].offset == 0)
    #expect(spans[1].length == 28)
}

@Test func spansSkipZeroLengthFiles() throws {
    let files: [(path: [String], data: Data)] = [
        (["a.bin"], Data(repeating: 0x01, count: 10)),
        (["hole.bin"], Data()),
        (["b.bin"], Data(repeating: 0x02, count: 10)),
    ]
    let (_, torrent, _) = try SyntheticTorrent.make(data: Data(), pieceLength: 64, name: "holes", files: files)
    let layout = try FileLayout(torrent: torrent, baseDirectory: makeTempDir("FileLayoutHoles"))

    // Bytes 6..14 cross the zero-length file: two spans, no zero-length span.
    let spans = layout.spans(forPieceRange: 6..<14)
    #expect(spans.count == 2)
    #expect(spans[0].file == 0 && spans[0].offset == 6 && spans[0].length == 4)
    #expect(spans[1].file == 2 && spans[1].offset == 0 && spans[1].length == 4)
}

// MARK: - Byte offset → file index

@Test func fileIndexMapsOffsetsToFiles() throws {
    let layout = try makeTwoFileLayout()  // file0 = bytes 0..100, file1 = 100..200

    #expect(layout.fileIndex(ofByteOffset: 0) == 0)
    #expect(layout.fileIndex(ofByteOffset: 50) == 0)
    #expect(layout.fileIndex(ofByteOffset: 99) == 0)
    #expect(layout.fileIndex(ofByteOffset: 100) == 1)
    #expect(layout.fileIndex(ofByteOffset: 199) == 1)
}

@Test func fileIndexSkipsZeroLengthFiles() throws {
    let files: [(path: [String], data: Data)] = [
        (["a.bin"], Data(repeating: 0x01, count: 10)),
        (["hole.bin"], Data()),
        (["b.bin"], Data(repeating: 0x02, count: 10)),
    ]
    let (_, torrent, _) = try SyntheticTorrent.make(data: Data(), pieceLength: 64, name: "holes", files: files)
    let layout = try FileLayout(torrent: torrent, baseDirectory: makeTempDir("FileLayoutHoles"))

    // Bytes 0..10 → file 0; byte 10 (past the zero-length file) → file 2.
    #expect(layout.fileIndex(ofByteOffset: 0) == 0)
    #expect(layout.fileIndex(ofByteOffset: 9) == 0)
    #expect(layout.fileIndex(ofByteOffset: 10) == 2)
    #expect(layout.fileIndex(ofByteOffset: 19) == 2)
}

// MARK: - Sanitization

@Test func sanitizeRejectsEmptyDotDotDotAndSlashes() {
    #expect(throws: (any Error).self) { try FileLayout.sanitize("") }
    #expect(throws: (any Error).self) { try FileLayout.sanitize(".") }
    #expect(throws: (any Error).self) { try FileLayout.sanitize("..") }
    #expect(throws: (any Error).self) { try FileLayout.sanitize("a/b") }
    #expect(throws: (any Error).self) { try FileLayout.sanitize("a\\b") }
    #expect(throws: (any Error).self) { try FileLayout.sanitize("a\0b") }
}

@Test func sanitizeRejectsAbsolutePathComponents() {
    #expect(throws: (any Error).self) { try FileLayout.sanitize("/etc/passwd") }
    #expect(throws: (any Error).self) { try FileLayout.sanitize("/tmp") }
    #expect(throws: (any Error).self) { try FileLayout.sanitize("C:\\windows\\evil") }
}

@Test func sanitizeAllowsSpacesAndUTF8() throws {
    #expect(try FileLayout.sanitize("my file.txt") == "my file.txt")
    #expect(try FileLayout.sanitize("héllo wörld.txt") == "héllo wörld.txt")
    #expect(try FileLayout.sanitize("日本語 資料.bin") == "日本語 資料.bin")
    #expect(try FileLayout.sanitize("dash-underscore_1.2.3") == "dash-underscore_1.2.3")
}

@Test func initRejectsTraversalInNameAndPaths() throws {
    // name is never trusted
    let (_, evilName, _) = try SyntheticTorrent.make(data: Data("x".utf8), name: "../evil")
    #expect(throws: (any Error).self) {
        try FileLayout(torrent: evilName, baseDirectory: makeTempDir("FileLayoutTraversal"))
    }

    // path components are never trusted either
    let files: [(path: [String], data: Data)] = [
        (["..", "escape.txt"], Data("y".utf8)),
    ]
    let (_, evilPath, _) = try SyntheticTorrent.make(data: Data(), pieceLength: 4, name: "multi", files: files)
    #expect(throws: (any Error).self) {
        try FileLayout(torrent: evilPath, baseDirectory: makeTempDir("FileLayoutTraversal"))
    }
}
