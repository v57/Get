import Foundation

/// Errors thrown by `MagnetLink.parse`.
public enum MagnetError: Error, Equatable {
    /// The string does not start with `magnet:`.
    case notAMagnetURI
    /// No `xt=urn:btih:` parameter (or a non-btih xt, e.g. a v2 `btmh`) was present.
    case missingInfoHash
    /// An `xt=urn:btih:` value was not a 40-char hex or 32-char RFC 4648 base32
    /// representation of a 20-byte SHA-1. Carries the offending value.
    case invalidInfoHash(String)
}

/// A parsed magnet link (BEP 9): `magnet:?xt=urn:btih:<infohash>&tr=<url>&dn=<name>`.
///
/// Only `xt` (btih), `tr`, and `dn` are understood; all other query parameters
/// (e.g. `xs`, `so`, `kt`, `x.pe`) are ignored.
public struct MagnetLink: Sendable, Equatable {
    /// 20-byte SHA-1 infohash, decoded from hex or base32.
    public let infohash: Data
    /// Every `tr=` tracker announce URL, percent-decoded, in URI order.
    public let trackers: [String]
    /// The percent-decoded `dn=` display name, if present.
    public let displayName: String?

    /// Parse a magnet URI string.
    ///
    /// - Throws: `MagnetError.notAMagnetURI` if the string has no `magnet:` scheme,
    ///   `MagnetError.missingInfoHash` if no `urn:btih:` xt is present, and
    ///   `MagnetError.invalidInfoHash` if the btih value is neither 40-char hex
    ///   nor 32-char base32.
    public static func parse(_ uri: String) throws -> MagnetLink {
        guard let scheme = uri.range(of: "magnet:", options: [.caseInsensitive, .anchored]) else {
            throw MagnetError.notAMagnetURI
        }
        var query = String(uri[scheme.upperBound...])
        if query.hasPrefix("?") {
            query.removeFirst()
        }

        var xtValue: String?
        var trackers: [String] = []
        var displayName: String?

        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue } // stray component without '=', ignore
            let key = String(parts[0])
            let rawValue = String(parts[1])
            let value = rawValue.removingPercentEncoding ?? rawValue // invalid %-sequences stay raw
            switch key {
            case "xt":
                xtValue = value
            case "tr":
                trackers.append(value)
            case "dn":
                if displayName == nil { displayName = value }
            default:
                break // unknown param, ignored
            }
        }

        guard let xtValue else { throw MagnetError.missingInfoHash }
        let infoHash = try infoHash(fromXt: xtValue)
        return MagnetLink(infohash: infoHash, trackers: trackers, displayName: displayName)
    }

    /// Decode the payload of an `xt=` value: `urn:btih:` prefix (case-insensitive),
    /// then either 40 hex chars or 32 RFC 4648 base32 chars, both case-insensitive.
    private static func infoHash(fromXt value: String) throws -> Data {
        guard let btih = value.range(of: "urn:btih:", options: [.caseInsensitive, .anchored]) else {
            throw MagnetError.missingInfoHash
        }
        let encoded = String(value[btih.upperBound...]).uppercased()
        switch encoded.count {
        case 40:
            guard let data = hexDecode(encoded) else { throw MagnetError.invalidInfoHash(value) }
            return data
        case 32:
            guard let data = base32Decode(encoded) else { throw MagnetError.invalidInfoHash(value) }
            return data
        default:
            throw MagnetError.invalidInfoHash(value)
        }
    }

    private static func hexDecode(_ hex: String) -> Data? {
        guard hex.count == 40, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        var data = Data(capacity: 20)
        var index = hex.startIndex
        while index < hex.endIndex {
            let hi = hex[index].hexDigitValue!
            let lo = hex[hex.index(after: index)].hexDigitValue!
            data.append(UInt8(hi * 16 + lo))
            index = hex.index(index, offsetBy: 2)
        }
        return data
    }

    private static let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    /// RFC 4648 base32 decode (no padding). `encoded` must be the 32 chars of a
    /// 20-byte value; 32 × 5 bits == 160 bits == 20 bytes, so no padding is legal.
    private static func base32Decode(_ encoded: String) -> Data? {
        guard encoded.count == 32 else { return nil }
        var buffer: UInt64 = 0
        var bitsInBuffer = 0
        var out = Data(capacity: 20)
        for c in encoded {
            guard let v = base32Alphabet.firstIndex(of: c) else { return nil }
            buffer = (buffer << 5) | UInt64(v)
            bitsInBuffer += 5
            if bitsInBuffer >= 8 {
                bitsInBuffer -= 8
                out.append(UInt8((buffer >> bitsInBuffer) & 0xFF))
            }
        }
        return out.count == 20 ? out : nil
    }
}