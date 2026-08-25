import Foundation

/// BEP 10 extended-message + BEP 11 PEX (ut_pex) codec.
///
/// Extended messages are wire id 20 with a 1-byte sub-id prefix:
///   - sub-id 0: the extended handshake, a bencoded dict `{m: {<name>: <id>}}`
///     announcing which extensions we support.
///   - any other sub-id (negotiated): the named extension's payload.
/// ut_pex (BEP 11) bodies are bencoded dicts with `added` / (optionally)
/// `dropped` compact-peer blobs (6-byte IPv4, 18-byte IPv6 entries).
public enum PEX {
    /// Our extended-message sub-id for ut_pex.
    public static let pexExtendedID: UInt8 = 1

    /// The extended handshake we send: advertise `ut_pex` under `pexExtendedID`.
    public static func handshake() -> Data {
        Bencode.encode(.dict([
            Data("m".utf8): .dict([
                Data("ut_pex".utf8): .int(Int64(pexExtendedID)),
            ]),
        ]))
    }

    /// Parse a peer's extended handshake and return its advertised ut_pex id,
    /// or nil if it doesn't support ut_pex.
    public static func parseHandshake(_ payload: Data) -> UInt8? {
        guard case .dict(let dict) = try? Bencode.parse(payload) else { return nil }
        guard case .dict(let m)? = dict[Data("m".utf8)] else { return nil }
        guard case .int(let id)? = m[Data("ut_pex".utf8)] else { return nil }
        return UInt8(clamping: id)
    }

    /// Build a ut_pex message body: `{added: <compact peers>}`. Sends the
    /// 6-byte compact IPv4 form for each peer.
    public static func pexBody(added: [(String, UInt16)]) -> Data {
        var compact = Data()
        for (host, port) in added {
            guard let bytes = packedV4(host) else { continue }
            compact.append(contentsOf: bytes)
            compact.append(UInt8(port >> 8))
            compact.append(UInt8(port & 0xFF))
        }
        return Bencode.encode(.dict([Data("added".utf8): .string(compact)]))
    }

    /// Parse a ut_pex body and return the added peers (as host/port).
    public static func parsePEX(_ payload: Data) -> [(String, UInt16)] {
        guard case .dict(let dict) = try? Bencode.parse(payload) else { return [] }
        guard case .string(let added)? = dict[Data("added".utf8)] else { return [] }
        return decodeCompactPeers(added)
    }

    /// 6-byte compact IPv4 (4-byte ip + 2-byte port); nil for non-IPv4 hosts.
    static func packedV4(_ host: String) -> Data? {
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }
        return Data(parts)
    }

    static func decodeCompactPeers(_ data: Data) -> [(String, UInt16)] {
        var out: [(String, UInt16)] = []
        var i = 0
        while i + 6 <= data.count {
            let ip = "\(data[i]).\(data[i + 1]).\(data[i + 2]).\(data[i + 3])"
            let port = (UInt16(data[i + 4]) << 8) | UInt16(data[i + 5])
            out.append((ip, port))
            i += 6
        }
        return out
    }
}
