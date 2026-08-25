import Foundation

/// A decoded bencode value (BEP 3).
public enum BencodeValue: Equatable, Sendable {
  case int(Int64)
  case string(Data)
  case list([BencodeValue])
  case dict([Data: BencodeValue])
}

public enum BencodeError: Error, Equatable { case malformed(String) }

/// Strict bencode parser and canonical encoder.
public struct Bencode: Sendable {
  /// Parse a complete bencode document.
  public static func parse(_ data: Data) throws -> BencodeValue {
    var p = Parser(data: data)
    let value = try p.parseValue()
    guard p.index == data.count else {
      throw BencodeError.malformed("trailing bytes after value at index \(p.index)")
    }
    return value
  }

  /// Parse a complete bencode document and also return the raw byte range of the
  /// top-level dict's value for `key`. Used to capture the exact `info` bytes for
  /// the SHA-1 infohash: the caller must hash `data[rawRange]` — never a re-encode.
  ///
  /// The top-level value must be a dict and the key must be present, otherwise
  /// `BencodeError.malformed` is thrown. If the key occurs multiple times, the
  /// last occurrence wins (matching dictionary semantics).
  public static func parseWithRawValue(_ data: Data, key: Data) throws -> (
    value: BencodeValue, rawRange: Range<Int>
  ) {
    var p = Parser(data: data)
    guard p.peek() == UInt8(ascii: "d") else {
      throw BencodeError.malformed("top-level value is not a dict")
    }
    p.index += 1  // consume 'd'
    var match: (value: BencodeValue, rawRange: Range<Int>)?
    while true {
      guard p.index < data.count else { throw BencodeError.malformed("dict truncated") }
      if data[p.index] == UInt8(ascii: "e") {
        p.index += 1
        guard p.index == data.count else {
          throw BencodeError.malformed("trailing bytes after value at index \(p.index)")
        }
        guard let match else {
          throw BencodeError.malformed("key not found: \(String(decoding: key, as: UTF8.self))")
        }
        return match
      }
      guard data[p.index].isASCIIDigit else {
        throw BencodeError.malformed("dict key is not a string at index \(p.index)")
      }
      let parsedKey = try p.parseString()
      let valueStart = p.index
      let value = try p.parseValue()
      let valueEnd = p.index
      if parsedKey == key { match = (value, valueStart..<valueEnd) }
    }
  }

  /// Encode a value in canonical form: dict keys sorted lexicographically by raw bytes.
  public static func encode(_ value: BencodeValue) -> Data {
    var out = Data()
    write(value, to: &out)
    return out
  }

  private static func write(_ value: BencodeValue, to out: inout Data) {
    switch value {
    case .int(let n): out.append(contentsOf: "i\(n)e".utf8)
    case .string(let s):
      out.append(contentsOf: "\(s.count):".utf8)
      out.append(s)
    case .list(let items):
      out.append(UInt8(ascii: "l"))
      for item in items { write(item, to: &out) }
      out.append(UInt8(ascii: "e"))
    case .dict(let pairs):
      out.append(UInt8(ascii: "d"))
      let sorted = pairs.sorted { $0.key.lexicographicallyPrecedes($1.key) }
      for (k, v) in sorted {
        out.append(contentsOf: "\(k.count):".utf8)
        out.append(k)
        write(v, to: &out)
      }
      out.append(UInt8(ascii: "e"))
    }
  }
}

/// Recursive-descent parser state over `Data`.
private struct Parser {
  let data: Data
  var index: Int = 0

  init(data: Data) {
    // Normalize so the parser always sees 0-based indices, even if the caller
    // passes a non-contiguous slice (e.g. `whole[range]`), whose indices are offset.
    self.data = Data(data)
  }

  func peek() -> UInt8? {
    guard index < data.count else { return nil }
    return data[index]
  }

  mutating func parseValue() throws -> BencodeValue {
    guard let byte = peek() else { throw BencodeError.malformed("unexpected end of data") }
    switch byte {
    case UInt8(ascii: "i"): return .int(try parseInt())
    case UInt8(ascii: "l"): return .list(try parseList())
    case UInt8(ascii: "d"): return .dict(try parseDict())
    default:
      if byte.isASCIIDigit { return .string(try parseString()) }
      throw BencodeError.malformed("unexpected byte \(byte) at index \(index)")
    }
  }

  /// Parse `i<digits>e`, rejecting leading zeros, `-0`, missing digits/terminator,
  /// and Int64 overflow.
  mutating func parseInt() throws -> Int64 {
    index += 1  // consume 'i'
    var negative = false
    if let b = peek(), b == UInt8(ascii: "-") {
      negative = true
      index += 1
    }
    let digitsStart = index
    while let b = peek(), b.isASCIIDigit { index += 1 }
    let digits = data[digitsStart..<index]
    guard !digits.isEmpty else {
      throw BencodeError.malformed("integer missing digits at index \(digitsStart)")
    }
    if digits.count > 1 && data[digitsStart] == UInt8(ascii: "0") {
      throw BencodeError.malformed("integer has leading zeros at index \(digitsStart)")
    }
    if negative && digits.count == 1 && data[digitsStart] == UInt8(ascii: "0") {
      throw BencodeError.malformed("negative zero at index \(digitsStart)")
    }
    guard let byte = peek(), byte == UInt8(ascii: "e") else {
      throw BencodeError.malformed("integer missing 'e' terminator at index \(index)")
    }
    index += 1
    let text = String(decoding: digits, as: UTF8.self)
    if negative {
      // Magnitudes up to 2^63 are legal so that Int64.min parses.
      guard let magnitude = UInt64(text), magnitude <= 9_223_372_036_854_775_808 else {
        throw BencodeError.malformed("integer out of range: \(text)")
      }
      if magnitude == 9_223_372_036_854_775_808 { return Int64.min }
      return -Int64(magnitude)
    }
    guard let value = Int64(text) else {
      throw BencodeError.malformed("integer out of range: \(text)")
    }
    return value
  }

  /// Parse `<digits>:<bytes>`.
  mutating func parseString() throws -> Data {
    let lengthStart = index
    while let b = peek(), b.isASCIIDigit { index += 1 }
    let lengthDigits = data[lengthStart..<index]
    guard !lengthDigits.isEmpty else {
      throw BencodeError.malformed("string missing length at index \(lengthStart)")
    }
    guard let byte = peek(), byte == UInt8(ascii: ":") else {
      throw BencodeError.malformed("string missing ':' at index \(index)")
    }
    index += 1
    guard let length = Int(String(decoding: lengthDigits, as: UTF8.self)) else {
      throw BencodeError.malformed(
        "string length out of range: \(String(decoding: lengthDigits, as: UTF8.self))")
    }
    let end = index + length
    guard end <= data.count else {
      throw BencodeError.malformed("string truncated at index \(index)")
    }
    defer { index = end }
    return data.subdata(in: index..<end)
  }

  mutating func parseList() throws -> [BencodeValue] {
    index += 1  // consume 'l'
    var items: [BencodeValue] = []
    while true {
      guard let byte = peek() else { throw BencodeError.malformed("list truncated") }
      if byte == UInt8(ascii: "e") {
        index += 1
        return items
      }
      items.append(try parseValue())
    }
  }

  /// Dict keys must be strings. Duplicate keys: last wins. Key order not enforced.
  mutating func parseDict() throws -> [Data: BencodeValue] {
    index += 1  // consume 'd'
    var pairs: [Data: BencodeValue] = [:]
    while true {
      guard let byte = peek() else { throw BencodeError.malformed("dict truncated") }
      if byte == UInt8(ascii: "e") {
        index += 1
        return pairs
      }
      guard byte.isASCIIDigit else {
        throw BencodeError.malformed("dict key is not a string at index \(index)")
      }
      let key = try parseString()
      pairs[key] = try parseValue()
    }
  }
}

extension UInt8 {
  fileprivate var isASCIIDigit: Bool { self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9") }
}
