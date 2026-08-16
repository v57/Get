import Foundation

/// The 68-byte BitTorrent peer handshake (the plaintext one, also carried
/// inside the MSE encrypted stream).
public struct Handshake: Sendable, Equatable {
    public let infoHash: Data   // 20 bytes
    public let peerID: Data     // 20 bytes

    public static let pstr = "BitTorrent protocol"
    public static let length = 68

    public init(infoHash: Data, peerID: Data) {
        self.infoHash = infoHash
        self.peerID = peerID
    }

    /// Layout: pstrlen(1) + pstr(19) + reserved(8, all zero) + infoHash(20) + peerID(20) = 68 bytes.
    /// Reserved bytes are all zero (no extension protocol in v1).
    public static func encode(infoHash: Data, peerID: Data) -> Data {
        var out = Data()
        out.append(UInt8(Self.pstr.utf8.count))
        out.append(contentsOf: Self.pstr.utf8)
        out.append(contentsOf: [UInt8](repeating: 0, count: 8))
        out.append(infoHash)
        out.append(peerID)
        return out
    }

    /// Validates length == 68, pstrlen == 19 and the pstr bytes.
    /// Reserved bytes are deliberately not validated (extension bits are legal in the wild).
    public static func decode(_ data: Data) throws -> Handshake {
        guard data.count == Self.length,
              data[data.startIndex] == UInt8(Self.pstr.utf8.count),
              Data(data.dropFirst(1).prefix(Self.pstr.utf8.count)) == Data(Self.pstr.utf8)
        else {
            throw HandshakeError.malformed
        }
        let infoHash = data.subdata(in: 28..<48)
        let peerID = data.subdata(in: 48..<68)
        return Handshake(infoHash: infoHash, peerID: peerID)
    }
}

public enum HandshakeError: Error, Equatable, Sendable {
    case malformed
}
