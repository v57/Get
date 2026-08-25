import Testing
@testable import Torrent
import Foundation

@Suite("BEP 10/11 PEX: extended messages + ut_pex")
struct PEXTests {
    func id(_ byte: UInt8) -> Data { Data(repeating: byte, count: 20) }

    @Test("extended wire message round-trips")
    func extendedRoundTrip() throws {
        let m = WireMessage.extended(id: 0, payload: Data("hello".utf8))
        let decoded = try WireCodec.decode(WireCodec.encode(m))
        #expect(decoded == m)
    }

    @Test("extended handshake advertises ut_pex")
    func handshakeBuild() {
        let body = PEX.handshake()
        // body is a bencoded dict with m: {ut_pex: 1}
        let parsed = try? Bencode.parse(body)
        guard case .dict(let dict) = parsed else {
            Issue.record("handshake not a dict"); return
        }
        guard case .dict(let m)? = dict[Data("m".utf8)] else {
            Issue.record("no m dict"); return
        }
        guard case .int(let id)? = m[Data("ut_pex".utf8)] else {
            Issue.record("no ut_pex"); return
        }
        #expect(id == Int64(PEX.pexExtendedID))
        // And parsing our own handshake returns our id.
        #expect(PEX.parseHandshake(body) == PEX.pexExtendedID)
    }

    @Test("parse peer handshake ut_pex id, nil when absent")
    func parseHandshake() {
        let withPEX = Bencode.encode(.dict([Data("m".utf8): .dict([Data("ut_pex".utf8): .int(3)])]))
        #expect(PEX.parseHandshake(withPEX) == 3)
        let noPEX = Bencode.encode(.dict([Data("m".utf8): .dict([Data("ut_metadata".utf8): .int(2)])]))
        #expect(PEX.parseHandshake(noPEX) == nil)
    }

    @Test("ut_pex body round-trips added peers")
    func pexRoundTrip() {
        let peers: [(String, UInt16)] = [("203.0.113.1", 6881), ("198.51.100.2", 51413)]
        let body = PEX.pexBody(added: peers)
        let decoded = PEX.parsePEX(body)
        #expect(decoded.count == 2)
        #expect(decoded[0] == peers[0])
        #expect(decoded[1] == peers[1])
    }

    @Test("ut_pex body ignores non-IPv4 hosts")
    func pexSkipsInvalid() {
        let body = PEX.pexBody(added: [("not-an-ip", 5), ("10.0.0.1", 200)])
        let decoded = PEX.parsePEX(body)
        #expect(decoded.count == 1)
        #expect(decoded[0] == ("10.0.0.1", 200))
    }
}
