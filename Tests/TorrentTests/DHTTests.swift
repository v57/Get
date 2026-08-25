import Testing
@testable import Torrent
import Foundation

@Suite("BEP 5 DHT: KRPC codec")
struct KRPCCodecTests {
    func id(_ byte: UInt8) -> Data { Data(repeating: byte, count: 20) }

    @Test("ping query round-trips")
    func pingRoundTrip() throws {
        let msg = KRPCMessage.query(transaction: "ab", method: "ping",
                                    arguments: KRPC.args(id: id(0x01), [:]))
        let data = KRPC.encode(msg)
        let decoded = try KRPC.decode(data)
        #expect(decoded == msg)
    }

    @Test("get_peers query round-trips with info_hash")
    func getPeersRoundTrip() throws {
        var args = KRPC.args(id: id(0xAB), ["info_hash": .string(id(0x7C))])
        _ = args
        let msg = KRPCMessage.query(transaction: "11", method: "get_peers",
                                    arguments: KRPC.args(id: id(0xAB), ["info_hash": .string(id(0x7C))]))
        let decoded = try KRPC.decode(KRPC.encode(msg))
        #expect(decoded == msg)
    }

    @Test("response round-trips values dict")
    func responseRoundTrip() throws {
        let msg = KRPCMessage.response(transaction: "cd", values: [
            "id": .string(id(0x02)),
            "token": .string(Data("tok".utf8)),
            "values": .list([.string(Data(repeating: 1, count: 6))]),
        ])
        #expect(try KRPC.decode(KRPC.encode(msg)) == msg)
    }

    @Test("error round-trips")
    func errorRoundTrip() throws {
        let msg = KRPCMessage.error(transaction: "ef", code: 201, message: "generic error")
        #expect(try KRPC.decode(KRPC.encode(msg)) == msg)
    }

    @Test("rejects non-dict top-level")
    func rejectsNonDict() {
        #expect(throws: (any Error).self) {
            _ = try KRPC.decode(Data("i42e".utf8))
        }
    }
}

@Suite("BEP 5 DHT: routing table")
struct RoutingTableTests {
    func id(_ byte: UInt8) -> Data { Data(repeating: byte, count: 20) }

    @Test("bucket index is first differing bit from MSB")
    func bucketIndex() {
        // distance all zeros → 0
        #expect(RoutingTable.bucketIndex(forDistance: Data(repeating: 0, count: 20)) == 0)
        // distance where bit 159 (MSB of first byte) set → bucket 0
        var d0 = Data(repeating: 0, count: 20)
        d0[0] = 0x80
        #expect(RoutingTable.bucketIndex(forDistance: d0) == 0)
        // distance where bit 152 set (byte 0 bit 7) → bucket 7
        var d7 = Data(repeating: 0, count: 20)
        d7[0] = 0x01
        #expect(RoutingTable.bucketIndex(forDistance: d7) == 7)
        // byte 1 bit 0 → bucket 8
        var d8 = Data(repeating: 0, count: 20)
        d8[1] = 0x80
        #expect(RoutingTable.bucketIndex(forDistance: d8) == 8)
    }

    @Test("insert and findClosest return nearest nodes")
    func findClosest() {
        let own = Data(repeating: 0, count: 20)
        let rt = RoutingTable(ownID: own)
        // node A distance 1 (target == own^A)
        var aID = Data(repeating: 0, count: 20); aID[19] = 0x01
        // node B closer: distance with high bit set at byte 0
        var bID = Data(repeating: 0, count: 20); bID[0] = 0x80
        // node C very far: flip many high bits
        var cID = Data(repeating: 0, count: 20); cID[0] = 0xFF
        rt.insert(DHTNodeInfo(id: aID, ip: "10.0.0.1", port: 1))
        rt.insert(DHTNodeInfo(id: bID, ip: "10.0.0.2", port: 2))
        rt.insert(DHTNodeInfo(id: cID, ip: "10.0.0.3", port: 3))
        #expect(rt.size == 3)
        // nearest to `own` = smallest XOR distance
        let nearest = rt.findClosest(to: own, count: 2)
        #expect(nearest.count == 2)
        #expect(nearest[0].id == aID) // distance 1
        #expect(nearest[1].id == bID)
    }
}

@Suite("BEP 5 DHT: compact node info")
struct CompactNodeTests {
    @Test("parses IPv4 and IPv6 compact nodes")
    func compact() {
        // IPv4 "nodes" blob (26-byte entries)
        var v4 = Data()
        let ipv4id = Data(repeating: 7, count: 20)
        v4.append(ipv4id)
        v4.append(contentsOf: [192, 0, 2, 1])
        v4.append(contentsOf: [0x1F, 0x90]) // 8080
        let v4nodes = DHTNodeInfo.nodes(from: v4, ipv6: false)
        #expect(v4nodes.count == 1)
        #expect(v4nodes[0].id == ipv4id)
        #expect(v4nodes[0].ip == "192.0.2.1")
        #expect(v4nodes[0].port == 8080)

        // IPv6 "nodes6" blob (38-byte entries)
        var v6 = Data()
        let ipv6id = Data(repeating: 9, count: 20)
        v6.append(ipv6id)
        v6.append(contentsOf: DHTNodeInfo.expandV6("2001:db8::1"))
        v6.append(contentsOf: [0x00, 0x50]) // 80
        let v6nodes = DHTNodeInfo.nodes(from: v6, ipv6: true)
        #expect(v6nodes.count == 1)
        #expect(v6nodes[0].id == ipv6id)
        #expect(v6nodes[0].ip == "2001:db8::1")
        #expect(v6nodes[0].port == 80)
    }

    @Test("IPv6 format matches RFC 5952 examples")
    func v6Format() {
        #expect(DHTNodeInfo.expandV6("::").count == 16)
        let allZeros = Data(repeating: 0, count: 16)
        #expect(DHTNodeInfo.formatV6(allZeros) == "::")
        let v6 = DHTNodeInfo.expandV6("2001:db8::1")
        #expect(v6.count == 16)
        #expect(DHTNodeInfo.formatV6(v6) == "2001:db8::1")
    }
}
