import Foundation

/// A node in the DHT: a 20-byte node id plus an IPv4/IPv6 endpoint.
/// Also used for "compact peer info" (BEP 5) when a 20-byte id is absent.
public struct DHTNodeInfo: Equatable, Sendable {
    public let id: Data            // 20 bytes
    public let ip: String
    public let port: UInt16

    public init(id: Data, ip: String, port: UInt16) {
        self.id = id
        self.ip = ip
        self.port = port
    }

    /// Compact form: IPv4 = 26 bytes (id 20 + ip 4 + port 2);
    /// IPv6 = 38 bytes (id 20 + ip 16 + port 2).
    public func toCompact(ipv6: Bool) -> Data {
        var out = Data()
        out.append(id)
        out.append(contentsOf: Self.packedIP(ip, ipv6: ipv6))
        out.append(UInt8(port >> 8))
        out.append(UInt8(port & 0xFF))
        return out
    }

    /// Parse a compact node-info blob for one address family:
    /// IPv4 entries are 26 bytes (id 20 + ip 4 + port 2), IPv6 entries 38 bytes
    /// (id 20 + ip 16 + port 2). BEP 5 keeps families separate (`nodes` vs
    /// `nodes6`), so a blob is homogeneous. Partial trailing entries are ignored.
    public static func nodes(from compact: Data, ipv6: Bool = false) -> [DHTNodeInfo] {
        let entrySize = ipv6 ? 38 : 26
        var result: [DHTNodeInfo] = []
        var i = compact.startIndex
        let end = compact.endIndex
        while end - i >= entrySize {
            let id = compact.subdata(in: i..<(i + 20))
            let ip: String
            if ipv6 {
                ip = Self.formatV6(compact.subdata(in: (i + 20)..<(i + 36)))
            } else {
                ip = Self.formatV4(compact.subdata(in: (i + 20)..<(i + 24)))
            }
            let port = (UInt16(compact[i + entrySize - 2]) << 8) | UInt16(compact[i + entrySize - 1])
            result.append(DHTNodeInfo(id: id, ip: ip, port: port))
            i += entrySize
        }
        return result
    }

    public static func packedIP(_ ip: String, ipv6: Bool) -> Data {
        guard ipv6 else {
            var octets = Data()
            for part in ip.split(separator: ".") {
                octets.append(UInt8(String(part)) ?? 0)
            }
            return octets
        }
        // RFC 5952 compressed IPv6 -> 16 raw bytes.
        return expandV6(ip)
    }

    public static func formatV4(_ raw: Data) -> String {
        raw.map { String($0) }.joined(separator: ".")
    }

    /// Expand an RFC 5952 (possibly ::-compressed) IPv6 string to 16 bytes.
    public static func expandV6(_ s: String) -> Data {
        let groupStrings = s.components(separatedBy: "::")
        var head: [String] = [], tail: [String] = []
        if groupStrings.count == 2 {
            head = groupStrings[0].isEmpty ? [] : groupStrings[0].split(separator: ":").map(String.init)
            tail = groupStrings[1].isEmpty ? [] : groupStrings[1].split(separator: ":").map(String.init)
        } else if groupStrings.count == 1 {
            head = s.split(separator: ":").map(String.init)
        }
        let missing = 8 - head.count - tail.count
        var groups = head
        groups.append(contentsOf: Array(repeating: "0", count: max(0, missing)))
        groups.append(contentsOf: tail)
        var out = Data()
        for g in groups.prefix(8) {
            let v = UInt16(g, radix: 16) ?? 0
            out.append(UInt8(v >> 8))
            out.append(UInt8(v & 0xFF))
        }
        return out
    }

    public static func formatV6(_ raw: Data) -> String {
        guard raw.count == 16 else { return "" }
        func group(_ i: Int) -> String {
            String(format: "%x", (UInt16(raw[i * 2]) << 8) | UInt16(raw[i * 2 + 1]))
        }
        // Find the longest run of zero groups for :: compression.
        var bestStart = -1, bestLen = 0
        var i = 0
        while i < 8 {
            if raw[i * 2] == 0 && raw[i * 2 + 1] == 0 {
                var j = i
                while j < 8 && raw[j * 2] == 0 && raw[j * 2 + 1] == 0 { j += 1 }
                if j - i > bestLen { bestLen = j - i; bestStart = i }
                i = j
            } else { i += 1 }
        }
        // Entirely zero → just "::".
        if bestLen == 8 { return "::" }
        var parts: [String] = []
        for g in 0..<8 {
            if bestLen >= 2 && g >= bestStart && g < bestStart + bestLen {
                if g == bestStart { parts.append("") }
                continue
            }
            parts.append(group(g))
        }
        return parts.joined(separator: ":")
    }
}
