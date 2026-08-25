import Foundation
import Testing

@testable import Torrent

// Infohash used throughout: a 20-byte SHA-1.
private let testHex = "9fbb17d030f7f5c51310fa49319eb28a30eb3329"
// Vector generated with:
//   python3 -c "import base64; print(base64.b32encode(bytes.fromhex('9fbb17d030f7f5c51310fa49319eb28a30eb3329')).decode())"
private let testBase32 = "T65RPUBQ6724KEYQ7JETDHVSRIYOWMZJ"

/// Hex string -> Data, for expected values in tests.
private func hexData(_ hex: String) -> Data {
  var out = Data()
  var index = hex.startIndex
  while index < hex.endIndex {
    let end = hex.index(index, offsetBy: 2)
    out.append(UInt8(hex[index..<end], radix: 16)!)
    index = end
  }
  return out
}

// MARK: - Happy paths

@Test func testParseHexXt() throws {
  // Uppercase hex proves case-insensitive decoding; tr and dn are percent-encoded.
  let uri =
    "magnet:?xt=urn:btih:9FBB17D030F7F5C51310FA49319EB28A30EB3329"
    + "&tr=http%3A%2F%2Fx%2Fannounce&dn=My%20Torrent"
  let link = try MagnetLink.parse(uri)
  #expect(link.infohash == hexData(testHex))
  #expect(link.trackers == ["http://x/announce"])
  #expect(link.displayName == "My Torrent")
}

@Test func testBase32Xt() throws {
  // RFC 4648 base32 (32 chars, no padding) — the standard magnet representation.
  let uri = "magnet:?xt=urn:btih:\(testBase32)&tr=http://x/announce"
  let link = try MagnetLink.parse(uri)
  #expect(link.infohash == hexData(testHex))
  #expect(link.trackers == ["http://x/announce"])
}

@Test func testBase32XtLowercase() throws {
  // base32 alphabet is case-insensitive on the wire.
  let uri = "magnet:?xt=urn:btih:\(testBase32.lowercased())"
  let link = try MagnetLink.parse(uri)
  #expect(link.infohash == hexData(testHex))
}

@Test func testMultipleTrackers() throws {
  let uri =
    "magnet:?xt=urn:btih:\(testHex)" + "&tr=http%3A%2F%2Ftracker1.example%2Fannounce"
    + "&tr=udp%3A%2F%2Ftracker2.example%3A1337%2Fannounce"
    + "&tr=http%3A%2F%2Ftracker3.example%2Fannounce"
  let link = try MagnetLink.parse(uri)
  #expect(
    link.trackers == [
      "http://tracker1.example/announce", "udp://tracker2.example:1337/announce",
      "http://tracker3.example/announce",
    ])
}

@Test func testNoTrackers() throws {
  let link = try MagnetLink.parse("magnet:?xt=urn:btih:\(testHex)&dn=no-trackers")
  #expect(link.trackers.isEmpty)
  #expect(link.infohash == hexData(testHex))
  #expect(link.displayName == "no-trackers")
}

@Test func testDisplayNameNilWhenAbsent() throws {
  let link = try MagnetLink.parse("magnet:?xt=urn:btih:\(testHex)")
  #expect(link.displayName == nil)
}

@Test func testPercentEncodedTracker() throws {
  // Tracker URL whose query contains an encoded '&' — must not be split as a param.
  let uri =
    "magnet:?xt=urn:btih:\(testHex)&tr=http%3A%2F%2Fx%2Fannounce%3Fpasskey%3Dabc%26key%3Ddef"
  let link = try MagnetLink.parse(uri)
  #expect(link.trackers == ["http://x/announce?passkey=abc&key=def"])
}

@Test func testUnknownParamsIgnored() throws {
  let uri =
    "magnet:?xt=urn:btih:\(testHex)&xs=http%3A%2F%2Fx%2Fmetadata&so=0-100"
    + "&kt=ultra&tr=http%3A%2F%2Fx%2Fannounce"
  let link = try MagnetLink.parse(uri)
  #expect(link.infohash == hexData(testHex))
  #expect(link.trackers == ["http://x/announce"])
}

// MARK: - Error paths

@Test func testMissingXtThrows() {
  // No xt parameter at all.
  #expect(throws: MagnetError.self) { try MagnetLink.parse("magnet:?dn=foo&tr=http://x/announce") }
  // xt present but not a btih infohash (v2 style) — not supported.
  #expect(throws: MagnetError.self) { try MagnetLink.parse("magnet:?xt=urn:btmh:1220\(testHex)") }
  #expect(throws: MagnetError.self) { try MagnetLink.parse("magnet:?xt=urn:ed2k:abc") }
}

@Test func testNonMagnetURIThrows() {
  #expect(throws: MagnetError.self) { try MagnetLink.parse("http://example.com/not-a-magnet") }
}

@Test func testMalformedHexInfohashThrows() {
  // 40 chars but 'Z' is not a hex digit.
  #expect(throws: MagnetError.self) {
    try MagnetLink.parse("magnet:?xt=urn:btih:ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ")
  }
  // Too long for hex (41 chars), too short for base32.
  #expect(throws: MagnetError.self) { try MagnetLink.parse("magnet:?xt=urn:btih:\(testHex)0") }
  // 39 chars, too short for both encodings.
  #expect(throws: MagnetError.self) {
    try MagnetLink.parse("magnet:?xt=urn:btih:\(testHex.dropLast())")
  }
  // 32 chars but not a valid base32 alphabet.
  #expect(throws: MagnetError.self) {
    try MagnetLink.parse("magnet:?xt=urn:btih:!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")
  }
}
