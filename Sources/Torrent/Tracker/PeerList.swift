import Foundation

/// A peer endpoint returned by a tracker.
public struct TrackerPeer: Sendable, Equatable, Hashable {
    /// Host as a string: dotted-quad IPv4 or compressed (RFC 5952) IPv6.
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

/// Decoding of compact tracker peer lists (BEP 23).
public enum PeerList {
    /// Decode a compact IPv4 peer list: 6 bytes per entry
    /// (4-byte big-endian IPv4 address + 2-byte big-endian port).
    /// A trailing partial entry is ignored.
    public static func decode(compact: Data) -> [TrackerPeer] {
        let bytes = [UInt8](compact)
        var peers: [TrackerPeer] = []
        peers.reserveCapacity(bytes.count / 6)
        var index = 0
        while index + 6 <= bytes.count {
            let host = "\(bytes[index]).\(bytes[index + 1]).\(bytes[index + 2]).\(bytes[index + 3])"
            let port = UInt16(bytes[index + 4]) << 8 | UInt16(bytes[index + 5])
            peers.append(TrackerPeer(host: host, port: port))
            index += 6
        }
        return peers
    }

    /// Decode a compact IPv6 peer list: 18 bytes per entry
    /// (16-byte big-endian IPv6 address + 2-byte big-endian port).
    /// A trailing partial entry is ignored.
    public static func decodeV6(compact: Data) -> [TrackerPeer] {
        let bytes = [UInt8](compact)
        var peers: [TrackerPeer] = []
        peers.reserveCapacity(bytes.count / 18)
        var index = 0
        while index + 18 <= bytes.count {
            let host = ipv6String(Array(bytes[index..<(index + 16)]))
            let port = UInt16(bytes[index + 16]) << 8 | UInt16(bytes[index + 17])
            peers.append(TrackerPeer(host: host, port: port))
            index += 18
        }
        return peers
    }

    /// Format a 16-byte IPv6 address as a compressed RFC 5952 string
    /// (e.g. `2001:db8::1`, `::ffff:192.0.2.1` for v4-mapped addresses).
    private static func ipv6String(_ address: [UInt8]) -> String {
        let hextets = (0..<8).map { i -> UInt16 in
            UInt16(address[i * 2]) << 8 | UInt16(address[i * 2 + 1])
        }
        // IPv4-mapped addresses (::ffff:0:0/96) use dotted-quad form.
        if hextets[0...4].allSatisfy({ $0 == 0 }), hextets[5] == 0xFFFF {
            let a = UInt16(hextets[6] >> 8), b = UInt16(hextets[6] & 0xFF)
            let c = UInt16(hextets[7] >> 8), d = UInt16(hextets[7] & 0xFF)
            return "::ffff:\(a).\(b).\(c).\(d)"
        }
        // Longest run of ≥2 zero hextets; leftmost wins ties.
        var bestStart = -1, bestLen = 0
        var runStart = -1, runLen = 0
        for (i, h) in hextets.enumerated() {
            if h == 0 {
                if runStart < 0 { runStart = i; runLen = 1 } else { runLen += 1 }
            } else {
                if runLen >= 2 && runLen > bestLen { bestStart = runStart; bestLen = runLen }
                runStart = -1; runLen = 0
            }
        }
        if runLen >= 2 && runLen > bestLen { bestStart = runStart; bestLen = runLen }
        if bestLen >= 2 {
            let before = hextets[0..<bestStart].map { String($0, radix: 16) }
            let after = hextets[(bestStart + bestLen)...].map { String($0, radix: 16) }
            if bestStart == 0 && bestStart + bestLen == hextets.count {
                return "::"                                  // entire address is zeros
            }
            if bestStart == 0 {
                return "::" + after.joined(separator: ":")   // run touches the start
            }
            if bestStart + bestLen == hextets.count {
                return before.joined(separator: ":") + "::"  // run touches the end
            }
            var parts = before
            parts.append("")
            parts.append(contentsOf: after)
            return parts.joined(separator: ":")              // run in the middle
        } else {
            return hextets.map { String($0, radix: 16) }.joined(separator: ":")
        }
    }
}
