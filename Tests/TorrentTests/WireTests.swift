import Testing
import Foundation
@testable import Torrent

// MARK: - Handshake

@Test func testHandshakeEncodeDecode() throws {
    let infoHash = Data((0..<20).map { UInt8($0) })
    let peerID = Data((0..<20).map { UInt8(0x41 + ($0 % 26)) })
    let encoded = Handshake.encode(infoHash: infoHash, peerID: peerID)

    // Byte layout: pstrlen(1) + pstr(19) + reserved(8, zero) + infoHash(20) + peerID(20) = 68.
    #expect(encoded.count == Handshake.length)
    #expect(encoded.count == 68)
    #expect(encoded[0] == 19)
    #expect(Data(encoded[1..<20]) == Data(Handshake.pstr.utf8))
    #expect(Data(encoded[20..<28]) == Data(repeating: 0, count: 8)) // reserved: all zero
    #expect(Data(encoded[28..<48]) == infoHash)
    #expect(Data(encoded[48..<68]) == peerID)

    // Roundtrip.
    let decoded = try Handshake.decode(encoded)
    #expect(decoded.infoHash == infoHash)
    #expect(decoded.peerID == peerID)
    #expect(decoded == Handshake(infoHash: infoHash, peerID: peerID))
}

@Test func testHandshakeMalformed() {
    let infoHash = Data(repeating: 0x11, count: 20)
    let peerID = Data(repeating: 0x22, count: 20)
    let valid = Handshake.encode(infoHash: infoHash, peerID: peerID)

    // Wrong total length.
    #expect(throws: HandshakeError.malformed) { try Handshake.decode(valid.dropLast()) }
    #expect(throws: HandshakeError.malformed) { try Handshake.decode(Data()) }
    // Wrong pstrlen (byte 0 != 19).
    var badPstrlen = valid
    badPstrlen[0] = 18
    #expect(throws: HandshakeError.malformed) { try Handshake.decode(badPstrlen) }
    // Wrong pstr bytes.
    var badPstr = valid
    badPstr[5] = 0x58
    #expect(throws: HandshakeError.malformed) { try Handshake.decode(badPstr) }
}

// MARK: - Wire messages

@Test func testMessageRoundTrip() throws {
    let messages: [WireMessage] = [
        .keepAlive,
        .choke,
        .unchoke,
        .interested,
        .notInterested,
        .have(piece: 0),
        .have(piece: 2_147_483_647),
        .bitfield(Data([0x80])),
        .bitfield(Data([0xFF, 0x00, 0x01])),
        .bitfield(Data()),
        .request(index: 0, begin: 0, length: 16_384),
        .request(index: 123_456, begin: 65_536, length: 1024),
        .piece(index: 3, begin: 16_384, data: Data("hello".utf8)),
        .piece(index: 0, begin: 0, data: Data()),
        .piece(index: 1_000, begin: 1_048_576, data: Data(repeating: 0xAB, count: 512)),
        .cancel(index: 9, begin: 100, length: 16_384),
    ]
    for message in messages {
        #expect(try WireCodec.decode(WireCodec.encode(message)) == message)
    }
}

@Test func testMessageByteLayout() throws {
    // choke: length 1, id 0.
    #expect(WireCodec.encode(.choke) == Data([0, 0, 0, 1, 0]))
    // have(piece: 1): length 5, id 4, piece 1.
    #expect(WireCodec.encode(.have(piece: 1)) == Data([0, 0, 0, 5, 4, 0, 0, 0, 1]))
    // request(index: 0, begin: 16384, length: 16384): length 13, id 6.
    let request = Data([0, 0, 0, 13, 6, 0, 0, 0, 0, 0, 0, 64, 0, 0, 0, 64, 0])
    #expect(WireCodec.encode(.request(index: 0, begin: 16_384, length: 16_384)) == request)
    #expect(try WireCodec.decode(request) == .request(index: 0, begin: 16_384, length: 16_384))
    // bitfield: length 1 + n, id 5.
    #expect(WireCodec.encode(.bitfield(Data([0x80, 0x40]))) == Data([0, 0, 0, 3, 5, 0x80, 0x40]))
}

@Test func testKeepAliveIsZeroLength() throws {
    let encoded = WireCodec.encode(.keepAlive)
    #expect(encoded.count == 4) // just the zero length prefix, no payload
    #expect(encoded == Data([0, 0, 0, 0]))
    #expect(try WireCodec.decode(encoded) == .keepAlive)
}

@Test func testPiecePayload() throws {
    let data = Data("hello".utf8) // 5 bytes
    let encoded = WireCodec.encode(.piece(index: 3, begin: 16_384, data: data))
    // 4-byte prefix + (id 1 + index 4 + begin 4 + data n) => 4 + 9 + n.
    #expect(encoded.count == 4 + 9 + data.count)
    #expect(Data(encoded[0..<4]) == Data([0, 0, 0, 14])) // length == 9 + 5
    #expect(try WireCodec.decode(encoded) == .piece(index: 3, begin: 16_384, data: data))
}

@Test func testFraming() throws {
    let a = WireCodec.encode(.choke)
    let b = WireCodec.encode(.have(piece: 7))
    let stream = a + b
    #expect(stream.count == a.count + b.count)

    // Split the concatenated stream using each frame's length prefix.
    let lenA = (Int(stream[0]) << 24) | (Int(stream[1]) << 16) | (Int(stream[2]) << 8) | Int(stream[3])
    #expect(lenA == 1) // choke payload
    let frameA = stream.prefix(4 + lenA)
    let frameB = stream.dropFirst(4 + lenA)
    #expect(try WireCodec.decode(Data(frameA)) == .choke)
    #expect(try WireCodec.decode(Data(frameB)) == .have(piece: 7))
}

@Test func testUnknownIDThrows() {
    // id 9 with a 1-byte payload: unknown message id.
    #expect(throws: WireCodecError.unknownID(9)) {
        try WireCodec.decode(Data([0, 0, 0, 1, 9]))
    }
}

@Test func testOversizedLengthThrows() {
    // Length prefix 0x02000000 (32 MiB) — far over the 2 MiB cap.
    #expect(throws: WireCodecError.payloadTooLarge(0x02000000)) {
        try WireCodec.decode(Data([0x02, 0, 0, 0, 0]))
    }
    // Exactly one byte over the 2 MiB cap (2,097,153).
    #expect(throws: WireCodecError.payloadTooLarge(2_097_153)) {
        try WireCodec.decode(Data([0, 0x20, 0, 1, 0]))
    }
}

@Test func testMalformedFrameThrows() {
    // Truncated: fewer than 4 bytes.
    #expect(throws: WireCodecError.self) { try WireCodec.decode(Data([0, 0])) }
    // Declared length doesn't match payload size.
    #expect(throws: WireCodecError.self) { try WireCodec.decode(Data([0, 0, 0, 5, 0])) }
    // keepAlive with trailing bytes.
    #expect(throws: WireCodecError.self) { try WireCodec.decode(Data([0, 0, 0, 0, 1])) }
    // Fixed-size message with wrong payload length (choke with 2 bytes).
    #expect(throws: WireCodecError.self) { try WireCodec.decode(Data([0, 0, 0, 2, 0, 1])) }
}
