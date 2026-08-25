import Foundation

/// BEP 5 KRPC message model. A message is a bencoded dictionary; the query
/// type (`y`) is `q` (query), `r` (response) or `e` (error). Payload dicts use
/// String keys for ergonomics and are converted to/from `[Data:...]` at the
/// bencode boundary.
public enum KRPCMessage: Equatable, Sendable {
    case query(transaction: String, method: String, arguments: [String: BencodeValue])
    case response(transaction: String, values: [String: BencodeValue])
    case error(transaction: String, code: Int, message: String)
}

public enum KRPCError: Error, Equatable {
    case malformed(String)
    case protocolError(Int, String)
}

/// Encode/decode KRPC messages (BEP 5) using the shared strict bencode codec.
public enum KRPC {
    public static func encode(_ message: KRPCMessage) -> Data {
        var dict: [Data: BencodeValue] = [:]
        switch message {
        case .query(let t, let q, let args):
            dict[Data("t".utf8)] = .string(Data(t.utf8))
            dict[Data("y".utf8)] = .string(Data("q".utf8))
            dict[Data("q".utf8)] = .string(Data(q.utf8))
            dict[Data("a".utf8)] = .dict(args.mapKeys { Data($0.utf8) })
        case .response(let t, let values):
            dict[Data("t".utf8)] = .string(Data(t.utf8))
            dict[Data("y".utf8)] = .string(Data("r".utf8))
            dict[Data("r".utf8)] = .dict(values.mapKeys { Data($0.utf8) })
        case .error(let t, let code, let msg):
            dict[Data("t".utf8)] = .string(Data(t.utf8))
            dict[Data("y".utf8)] = .string(Data("e".utf8))
            dict[Data("e".utf8)] = .list([.int(Int64(code)), .string(Data(msg.utf8))])
        }
        return Bencode.encode(.dict(dict))
    }

    public static func decode(_ data: Data) throws -> KRPCMessage {
        guard case .dict(let dict) = try Bencode.parse(data) else {
            throw KRPCError.malformed("top-level value is not a dict")
        }
        guard let t = string(dict, "t") else {
            throw KRPCError.malformed("missing transaction id 't'")
        }
        guard let y = string(dict, "y") else {
            throw KRPCError.malformed("missing message type 'y'")
        }
        switch y {
        case "q":
            guard let q = string(dict, "q") else {
                throw KRPCError.malformed("query missing method 'q'")
            }
            guard let a = dict[Data("a".utf8)], case .dict(let args) = a else {
                throw KRPCError.malformed("query missing dict 'a'")
            }
            return .query(transaction: t, method: q, arguments: args.mapKeys { String(decoding: $0, as: UTF8.self) })
        case "r":
            guard let r = dict[Data("r".utf8)], case .dict(let values) = r else {
                throw KRPCError.malformed("response missing dict 'r'")
            }
            return .response(transaction: t, values: values.mapKeys { String(decoding: $0, as: UTF8.self) })
        case "e":
            guard let e = dict[Data("e".utf8)], case .list(let list) = e, list.count == 2,
                  case .int(let code) = list[0], case .string(let msg) = list[1] else {
                throw KRPCError.malformed("malformed error 'e'")
            }
            return .error(transaction: t, code: Int(code), message: String(decoding: msg, as: UTF8.self))
        default:
            throw KRPCError.malformed("unknown message type 'y': \(y)")
        }
    }

    static func string(_ dict: [Data: BencodeValue], _ key: String) -> String? {
        guard let v = dict[Data(key.utf8)], case .string(let s) = v else { return nil }
        return String(decoding: s, as: UTF8.self)
    }

    /// Build a query's `a` dict from a node id plus extra pairs.
    static func args(id: Data, _ extra: [String: BencodeValue]) -> [String: BencodeValue] {
        var a = extra
        a["id"] = .string(id)
        return a
    }
}

private extension Dictionary {
    func mapKeys<NewKey>(_ transform: (Key) -> NewKey) -> [NewKey: Value] {
        var out: [NewKey: Value] = [:]
        for (k, v) in self { out[transform(k)] = v }
        return out
    }
}
