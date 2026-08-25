import Foundation

/// BitTorrent wire protocol messages (the payload inside the 4-byte length framing,
/// and the RC4-encrypted stream once MSE completes).
public enum WireMessage: Sendable, Equatable {
  case keepAlive
  case choke
  case unchoke
  case interested
  case notInterested
  case have(piece: Int)
  case bitfield(Data)  // raw bits, big-endian per spec
  case request(index: Int, begin: Int, length: Int)
  case piece(index: Int, begin: Int, data: Data)
  case cancel(index: Int, begin: Int, length: Int)
  /// BEP 10 extended message (id 20): a 1-byte sub-id followed by a body.
  /// Sub-id 0 is the extended handshake; others are negotiated extensions
  /// (e.g. ut_pex under the id advertised in the handshake).
  case extended(id: UInt8, payload: Data)
}

public enum WireCodecError: Error, Equatable, Sendable {
  case malformed(String)
  case unknownID(UInt8)
  case payloadTooLarge(Int)
}

/// Length-prefixed wire codec. Every message is framed as a 4-byte big-endian
/// length (payload bytes, including the message id) followed by the payload;
/// a zero length is a keep-alive.
public enum WireCodec {
  /// Hard cap on a single frame's payload, guarding against malicious length
  /// prefixes from peers (2 MiB covers the largest legit message: a 16 KiB block).
  public static let maxPayloadLength = 2 * 1024 * 1024

  public static func encode(_ m: WireMessage) -> Data {
    var payload = Data()
    switch m {
    case .keepAlive: break
    case .choke: payload.append(0)
    case .unchoke: payload.append(1)
    case .interested: payload.append(2)
    case .notInterested: payload.append(3)
    case .have(let piece):
      payload.append(4)
      appendUInt32(piece, to: &payload)
    case .bitfield(let bits):
      payload.append(5)
      payload.append(bits)
    case .request(let index, let begin, let length):
      payload.append(6)
      appendUInt32(index, to: &payload)
      appendUInt32(begin, to: &payload)
      appendUInt32(length, to: &payload)
    case .piece(let index, let begin, let data):
      payload.append(7)
      appendUInt32(index, to: &payload)
      appendUInt32(begin, to: &payload)
      payload.append(data)
    case .cancel(let index, let begin, let length):
      payload.append(8)
      appendUInt32(index, to: &payload)
      appendUInt32(begin, to: &payload)
      appendUInt32(length, to: &payload)
    case .extended(let id, let body):
      payload.append(20)
      payload.append(id)
      payload.append(body)
    }

    var framed = Data()
    appendUInt32(UInt32(truncatingIfNeeded: payload.count), to: &framed)
    framed.append(payload)
    return framed
  }

  /// Decode one complete frame (4-byte length prefix + payload).
  /// Throws `WireCodecError.payloadTooLarge` for lengths > 2 MiB,
  /// `WireCodecError.unknownID` for ids outside 0...8, and
  /// `WireCodecError.malformed` for any other framing violation.
  public static func decode(_ framed: Data) throws -> WireMessage {
    guard framed.count >= 4 else {
      throw WireCodecError.malformed("frame shorter than 4-byte length prefix")
    }
    let length = readUInt32(framed, at: 0)
    guard length <= maxPayloadLength else { throw WireCodecError.payloadTooLarge(length) }
    guard framed.count == 4 + length else {
      throw WireCodecError.malformed(
        "declared length \(length) does not match payload \(framed.count - 4)")
    }
    guard length > 0 else { return .keepAlive }

    let payload = framed.dropFirst(4)
    let id = payload[payload.startIndex]
    switch id {
    case 0:
      guard payload.count == 1 else { throw WireCodecError.malformed("choke carries a payload") }
      return .choke
    case 1:
      guard payload.count == 1 else { throw WireCodecError.malformed("unchoke carries a payload") }
      return .unchoke
    case 2:
      guard payload.count == 1 else {
        throw WireCodecError.malformed("interested carries a payload")
      }
      return .interested
    case 3:
      guard payload.count == 1 else {
        throw WireCodecError.malformed("notInterested carries a payload")
      }
      return .notInterested
    case 4:
      guard payload.count == 5 else {
        throw WireCodecError.malformed("have must be 5 bytes (id + 4)")
      }
      return .have(piece: readUInt32(payload, at: 1))
    case 5: return .bitfield(Data(payload.dropFirst(1)))
    case 6:
      guard payload.count == 13 else {
        throw WireCodecError.malformed("request must be 13 bytes (id + 12)")
      }
      return .request(
        index: readUInt32(payload, at: 1), begin: readUInt32(payload, at: 5),
        length: readUInt32(payload, at: 9))
    case 7:
      guard payload.count >= 9 else {
        throw WireCodecError.malformed("piece must be at least 9 bytes (id + 8)")
      }
      return .piece(
        index: readUInt32(payload, at: 1), begin: readUInt32(payload, at: 5),
        data: Data(payload.dropFirst(9)))
    case 8:
      guard payload.count == 13 else {
        throw WireCodecError.malformed("cancel must be 13 bytes (id + 12)")
      }
      return .cancel(
        index: readUInt32(payload, at: 1), begin: readUInt32(payload, at: 5),
        length: readUInt32(payload, at: 9))
    case 20:
      guard payload.count >= 2 else {
        throw WireCodecError.malformed("extended must carry a sub-id")
      }
      return .extended(id: payload[payload.startIndex + 1], payload: Data(payload.dropFirst(2)))
    default: throw WireCodecError.unknownID(id)
    }
  }

  // MARK: - Helpers

  private static func appendUInt32(_ value: UInt32, to data: inout Data) {
    data.append(contentsOf: [
      UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF),
      UInt8(value & 0xFF),
    ])
  }

  private static func appendUInt32(_ value: Int, to data: inout Data) {
    appendUInt32(UInt32(truncatingIfNeeded: value), to: &data)
  }

  /// Reads a big-endian UInt32. Offsets are relative to `data.startIndex`
  /// (Data slices from `dropFirst` keep a non-zero startIndex, so absolute
  /// offsets would trap).
  private static func readUInt32(_ data: Data, at offset: Int) -> Int {
    let start = data.startIndex
    return (Int(data[start + offset]) << 24) | (Int(data[start + offset + 1]) << 16)
      | (Int(data[start + offset + 2]) << 8) | Int(data[start + offset + 3])
  }
}
