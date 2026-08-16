import Testing
import Foundation
@testable import Torrent

// MARK: - Parsing

@Test func testParseInteger() throws {
    #expect(try Bencode.parse(Data("i42e".utf8)) == .int(42))
    #expect(try Bencode.parse(Data("i-7e".utf8)) == .int(-7))
    #expect(try Bencode.parse(Data("i0e".utf8)) == .int(0))
    #expect(try Bencode.parse(Data("i9223372036854775807e".utf8)) == .int(Int64.max))
    #expect(try Bencode.parse(Data("i-9223372036854775808e".utf8)) == .int(Int64.min))
}

@Test func testParseString() throws {
    #expect(try Bencode.parse(Data("4:spam".utf8)) == .string(Data("spam".utf8)))
    #expect(try Bencode.parse(Data("0:".utf8)) == .string(Data()))
    // Binary payloads (e.g. concatenated SHA-1 piece hashes) are raw bytes.
    let binary = Data([0x00, 0xFF, 0x10])
    #expect(try Bencode.parse(Data("3:".utf8) + binary) == .string(binary))
}

@Test func testParseList() throws {
    #expect(try Bencode.parse(Data("l4:spami42ee".utf8)) == .list([.string(Data("spam".utf8)), .int(42)]))
    #expect(try Bencode.parse(Data("le".utf8)) == .list([]))
    #expect(try Bencode.parse(Data("li1eli2eee".utf8)) == .list([.int(1), .list([.int(2)])]))
}

@Test func testParseDict() throws {
    #expect(try Bencode.parse(Data("d3:foo3:bare".utf8)) == .dict([Data("foo".utf8): .string(Data("bar".utf8))]))
    #expect(try Bencode.parse(Data("de".utf8)) == .dict([:]))
}

// MARK: - Encoding / roundtrip

@Test func testRoundTrip() throws {
    // Nested structure: encode(parse(x)) == x, and re-encoding is byte-identical (canonical).
    let nested = BencodeValue.dict([
        Data("announce".utf8): .string(Data("http://tracker.example/announce".utf8)),
        Data("info".utf8): .dict([
            Data("name".utf8): .string(Data("synthetic.bin".utf8)),
            Data("piece length".utf8): .int(16 * 1024),
            Data("length".utf8): .int(100_000),
            Data("pieces".utf8): .string(Data(repeating: 0xAA, count: 40)),
        ]),
        Data("list".utf8): .list([.int(1), .string(Data("x".utf8)), .list([.int(-3)]), .dict([Data("k".utf8): .int(0)])]),
    ])
    let encoded = Bencode.encode(nested)
    let parsed = try Bencode.parse(encoded)
    #expect(parsed == nested)
    #expect(Bencode.encode(parsed) == encoded)

    // Raw roundtrip on an already-canonical document (keys already sorted).
    let raw = Data("d4:infod6:lengthi5ee4:name4:teste".utf8)
    #expect(Bencode.encode(try Bencode.parse(raw)) == raw)
}

@Test func testEncodeSortsDictKeys() throws {
    let value = BencodeValue.dict([
        Data("z".utf8): .int(1),
        Data("a".utf8): .int(2),
        Data("aa".utf8): .int(3),
    ])
    #expect(Bencode.encode(value) == Data("d1:ai2e2:aai3e1:zi1ee".utf8))
}

// MARK: - Malformed input

@Test func testMalformed() {
    #expect(throws: BencodeError.self) { try Bencode.parse(Data()) }                          // empty
    #expect(throws: BencodeError.self) { try Bencode.parse(Data("x".utf8)) }                  // unexpected byte
    #expect(throws: BencodeError.self) { try Bencode.parse(Data("i42".utf8)) }                // truncated int
    #expect(throws: BencodeError.self) { try Bencode.parse(Data("i-42".utf8)) }               // truncated negative int
    #expect(throws: BencodeError.self) { try Bencode.parse(Data("i42x".utf8)) }               // int missing 'e'
    #expect(throws: BencodeError.self) { try Bencode.parse(Data("i042e".utf8)) }              // leading zeros
    #expect(throws: BencodeError.self) { try Bencode.parse(Data("i-0e".utf8)) }               // negative zero
    #expect(throws: BencodeError.self) { try Bencode.parse(Data("i9223372036854775808e".utf8)) } // Int64 overflow
    #expect(throws: BencodeError.self) { try Bencode.parse(Data("4:".utf8)) }                 // truncated string
    #expect(throws: BencodeError.self) { try Bencode.parse(Data("4:spa".utf8)) }              // string length exceeds data
    #expect(throws: BencodeError.self) { try Bencode.parse(Data("l4:spam".utf8)) }            // truncated list
    #expect(throws: BencodeError.self) { try Bencode.parse(Data("d3:foo".utf8)) }             // truncated dict
    #expect(throws: BencodeError.self) { try Bencode.parse(Data("di42ee".utf8)) }             // non-string dict key
    #expect(throws: BencodeError.self) { try Bencode.parse(Data("i1ei2e".utf8)) }             // trailing garbage
    #expect(throws: BencodeError.self) { try Bencode.parse(Data("4:spamx".utf8)) }            // trailing garbage after string
}

// MARK: - Raw value byte range (for the SHA-1 infohash)

@Test func testInfoDictByteRange() throws {
    // Top-level dict whose "info" value is itself a nested dict.
    let raw = Data("d4:infod6:lengthi5ee4:name4:teste".utf8)
    let result = try Bencode.parseWithRawValue(raw, key: Data("info".utf8))
    #expect(result.value == .dict([Data("length".utf8): .int(5)]))
    // Exact raw byte range of the info VALUE, including its 'd...e' wrapper.
    #expect(result.rawRange == 7..<20)
    #expect(raw[result.rawRange] == Data("d6:lengthi5ee".utf8))
    // Parsing the raw slice yields the same value — the infohash must hash data[rawRange],
    // never a re-encode.
    #expect(try Bencode.parse(raw[result.rawRange]) == result.value)
}

@Test func testParseWithRawValueOtherTypesAndErrors() throws {
    // The value for the key can be any bencode type; the range still covers its raw bytes.
    let rawInt = Data("d3:fooi42e4:name4:teste".utf8)
    let intResult = try Bencode.parseWithRawValue(rawInt, key: Data("foo".utf8))
    #expect(intResult.value == .int(42))
    #expect(intResult.rawRange == 6..<10)
    #expect(rawInt[intResult.rawRange] == Data("i42e".utf8))

    // Missing key and non-dict top level both throw.
    #expect(throws: BencodeError.self) {
        try Bencode.parseWithRawValue(Data("d3:foo3:bare".utf8), key: Data("info".utf8))
    }
    #expect(throws: BencodeError.self) {
        try Bencode.parseWithRawValue(Data("l4:spame".utf8), key: Data("info".utf8))
    }
}
