import CryptoKit
import Foundation
import Testing

@testable import Torrent

// MARK: - Single-file parse

@Test func testParseSingleFile() throws {
  let content = Data((0..<100_000).map { UInt8($0 % 251) })
  let pieceLength = 16 * 1024
  let result = try SyntheticTorrent.make(data: content, pieceLength: pieceLength)
  let torrent = result.torrent
  let raw = result.data

  #expect(torrent.announce == "http://127.0.0.1:6969/announce")
  #expect(torrent.announceList == [])
  #expect(torrent.name == "synthetic.bin")
  #expect(torrent.pieceLength == pieceLength)
  #expect(torrent.infoHash.count == 20)
  #expect(torrent.totalSize == Int64(content.count))
  #expect(torrent.files.count == 1)
  #expect(torrent.files[0].length == Int64(content.count))
  #expect(torrent.files[0].path == ["synthetic.bin"])

  // Piece hashes independently recomputed over each piece of the content.
  let pieces = (content.count + pieceLength - 1) / pieceLength
  #expect(torrent.pieceHashes.count == pieces)
  var offset = 0
  for (i, hash) in torrent.pieceHashes.enumerated() {
    let end = min(offset + pieceLength, content.count)
    #expect(
      hash == Data(Insecure.SHA1.hash(data: content[offset..<end])), "piece \(i) hash mismatch")
    offset = end
  }

  // Infohash is the SHA-1 of the RAW info-dict bytes in the document —
  // never a re-encode.
  let (_, rawRange) = try Bencode.parseWithRawValue(raw, key: Data("info".utf8))
  #expect(torrent.infoHash == Data(Insecure.SHA1.hash(data: raw[rawRange])))

  // Parsing the same bytes again yields an equal value (Equatable sanity).
  #expect(try TorrentFile.parse(raw) == torrent)
}

@Test func testParseFromURL() throws {
  let result = try SyntheticTorrent.make(
    data: Data(repeating: 7, count: 1000), pieceLength: 512, name: "url.bin")
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "torrentfile-test-\(UUID().uuidString).torrent")
  defer { try? FileManager.default.removeItem(at: url) }
  try result.data.write(to: url)
  let parsed = try TorrentFile.parse(url: url)
  #expect(parsed == result.torrent)
  #expect(parsed.name == "url.bin")
}

// MARK: - Multi-file parse (one file straddles a piece boundary)

@Test func testParseMultiFile() throws {
  let pieceLength = 8 * 1024  // 8192
  // a.bin is 10240 bytes: piece 0 ends at 8192, so piece 1 starts INSIDE
  // a.bin (byte 2048 of it) and crosses into b.bin at 10240.
  let fileA = (path: ["dirA", "a.bin"], data: Data(repeating: 0xAB, count: 10 * 1024))
  let fileB = (path: ["b.bin"], data: Data(repeating: 0xCD, count: 4 * 1024))
  let result = try SyntheticTorrent.make(
    data: Data(), pieceLength: pieceLength, files: [fileA, fileB])
  let torrent = result.torrent

  #expect(torrent.files.count == 2)
  #expect(torrent.files[0].path == ["dirA", "a.bin"])
  #expect(torrent.files[0].length == 10 * 1024)
  #expect(torrent.files[1].path == ["b.bin"])
  #expect(torrent.files[1].length == 4 * 1024)
  #expect(torrent.totalSize == Int64(14 * 1024))
  #expect(torrent.name == "synthetic.bin")
  #expect(torrent.pieceLength == pieceLength)
  #expect(torrent.pieceHashes.count == 2)  // ceil(14336 / 8192)

  // Hashes computed over the concatenated stream (covers the straddle).
  let content = result.content
  #expect(content.count == 14 * 1024)
  #expect(torrent.pieceHashes[0] == Data(Insecure.SHA1.hash(data: content[0..<8192])))
  #expect(torrent.pieceHashes[1] == Data(Insecure.SHA1.hash(data: content[8192..<14 * 1024])))

  // Infohash is over the raw info bytes.
  let (_, rawRange) = try Bencode.parseWithRawValue(result.data, key: Data("info".utf8))
  #expect(torrent.infoHash == Data(Insecure.SHA1.hash(data: result.data[rawRange])))

  #expect(try TorrentFile.parse(result.data) == torrent)
}

// MARK: - Known infohash vector (precomputed with python3)

@Test func testInfoHashMatchesKnownVector() throws {
  // Hand-built, deliberately NON-canonical key order inside info
  // (name before length; canonical would be length, name, ...) and at the
  // top level (info before announce). A re-encode-based infohash would
  // produce different bytes, so this vector pins the raw-range semantics.
  //
  // info raw bytes:
  //   d4:name5:hello6:lengthi20480e12:piece lengthi16384e6:pieces40:<40x00>e
  // SHA-1 precomputed once with:
  //   python3 -c "import hashlib; print(hashlib.sha1(info).hexdigest())"
  //   => 4fa5f22b88551ef6109aad90319d901166b6b8c8
  var raw = Data("d4:infod4:name5:hello6:lengthi20480e12:piece lengthi16384e6:pieces40:".utf8)
  raw.append(Data(repeating: 0, count: 40))
  raw.append(Data("e8:announce30:http://127.0.0.1:6969/announcee".utf8))

  let torrent = try TorrentFile.parse(raw)
  #expect(
    torrent.infoHash
      == Data([
        0x4f, 0xa5, 0xf2, 0x2b, 0x88, 0x55, 0x1e, 0xf6, 0x10, 0x9a, 0xad, 0x90, 0x31, 0x9d, 0x90,
        0x11, 0x66, 0xb6, 0xb8, 0xc8,
      ]))
  #expect(torrent.name == "hello")
  #expect(torrent.totalSize == 20_480)
  #expect(torrent.pieceLength == 16_384)
  #expect(torrent.pieceHashes.count == 2)
  #expect(torrent.files.count == 1)
  #expect(torrent.files[0].path == ["hello"])
  #expect(torrent.announce == "http://127.0.0.1:6969/announce")

  // Guard against re-encode: hashing a canonical re-encode of the info value
  // must NOT equal the infohash (the raw fixture bytes are non-canonical).
  let (_, rawRange) = try Bencode.parseWithRawValue(raw, key: Data("info".utf8))
  let reencoded = Bencode.encode(try Bencode.parse(raw[rawRange]))
  #expect(reencoded != raw[rawRange])
  #expect(torrent.infoHash != Data(Insecure.SHA1.hash(data: reencoded)))
}

// MARK: - Invalid UTF-8 name fallback

@Test func testUTF8NameFallback() throws {
  // name bytes are invalid UTF-8: FF (bad lead), 80 80 (bare continuations),
  // C3 28 (truncated 2-byte seq), F0 9F 98 (truncated 4-byte seq).
  // Strings must decode with U+FFFD replacement and never throw.
  let nameBytes: [UInt8] = [0xFF, 0x80, 0x80, 0xC3, 0x28, 0xF0, 0x9F, 0x98]
  var raw = Data("d4:infod4:name8:".utf8)
  raw.append(contentsOf: nameBytes)
  raw.append(Data("6:lengthi10e12:piece lengthi16384e6:pieces20:".utf8))
  raw.append(Data(repeating: 0, count: 20))
  raw.append(Data("e8:announce30:http://127.0.0.1:6969/announcee".utf8))

  let torrent = try TorrentFile.parse(raw)  // must not throw
  // One U+FFFD per maximal invalid subpart, ASCII '(' preserved.
  #expect(torrent.name == "\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}(\u{FFFD}")
  // Rest of the torrent still parses normally.
  #expect(torrent.totalSize == 10)
  #expect(torrent.pieceHashes.count == 1)

  // Direct mapping from the raw bytes (replacement semantics, never null).
  #expect(torrent.name == String(decoding: Data(nameBytes), as: UTF8.self))
}

// MARK: - Piece hash count edges (empty-last-piece)

@Test func testPieceHashesCount() throws {
  let pieceLength = 4096
  // Exact multiple of the piece length — no padding piece.
  let (_, exact, _) = try SyntheticTorrent.make(
    data: Data(repeating: 1, count: 3 * pieceLength), pieceLength: pieceLength)
  #expect(exact.pieceHashes.count == 3)
  // Short final piece (> multiple, < multiple + pieceLength).
  let (_, short, _) = try SyntheticTorrent.make(
    data: Data(repeating: 2, count: 3 * pieceLength + 1), pieceLength: pieceLength)
  #expect(short.pieceHashes.count == 4)
  // Empty content: zero pieces — never a synthetic empty-last-piece hash.
  let (_, empty, _) = try SyntheticTorrent.make(data: Data(), pieceLength: pieceLength)
  #expect(empty.pieceHashes.count == 0)
  #expect(empty.totalSize == 0)
  #expect(empty.files.count == 1)
  #expect(empty.files[0].length == 0)
}

// MARK: - announce-list tiers

@Test func testAnnounceList() throws {
  var raw = Data("d4:info".utf8)
  raw.append(Data("d4:name4:test6:lengthi5e12:piece lengthi16384e6:pieces20:".utf8))
  raw.append(Data(repeating: 0, count: 20))
  raw.append(Data("e".utf8))
  raw.append(
    Data(
      "13:announce-listll25:http://a.example/announce25:http://b.example/announceel25:http://c.example/announceee"
        .utf8))
  raw.append(Data("e".utf8))

  let torrent = try TorrentFile.parse(raw)
  #expect(
    torrent.announceList == [
      ["http://a.example/announce", "http://b.example/announce"], ["http://c.example/announce"],
    ])
  #expect(torrent.announce == nil)
  #expect(torrent.totalSize == 5)
}

// MARK: - Malformed input

@Test func testMalformedTorrents() {
  #expect(throws: BencodeError.self) { try TorrentFile.parse(Data()) }
  #expect(throws: BencodeError.self) { try TorrentFile.parse(Data("de".utf8)) }  // no info key
  #expect(throws: BencodeError.self) { try TorrentFile.parse(Data("l4:spame".utf8)) }  // top-level not a dict
  // info present but pieces not a multiple of 20 bytes.
  let bad = Data("d4:infod4:name4:test6:lengthi5e12:piece lengthi16384e6:pieces7:1234567ee".utf8)
  #expect(throws: BencodeError.self) { try TorrentFile.parse(bad) }
}
