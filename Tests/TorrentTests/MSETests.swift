import Testing
import CryptoKit
import Foundation
@testable import Torrent

/// Decode a hex string (e.g. "b2396305") into bytes.
private func hex(_ s: String) -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(s.count / 2)
    var i = s.startIndex
    while i < s.endIndex {
        let pair = String(s[i...s.index(after: i)])
        bytes.append(UInt8(pair, radix: 16)!)
        i = s.index(i, offsetBy: 2)
    }
    return bytes
}

// MARK: - Key derivation

@Test func testKeyDerivationMatchesPythonVectors() {
    // Vectors produced with python3 for each fixed 96-byte secret:
    //   h = hashlib.sha1(secret).digest()
    //   X = hashlib.sha1(bytes(a ^ b for a, b in zip(h, b"keyA" * 5))).digest()
    //   Y = hashlib.sha1(bytes(a ^ b for a, b in zip(h, b"keyB" * 5))).digest()

    // Secret 1: all zeros.
    let (x1, y1) = MSE.deriveKeys(secret: hex(String(repeating: "00", count: 96)))
    #expect(x1 == hex("7067df6aa693e1b74d175e357bc7c556ee9ec698"))
    #expect(y1 == hex("15b8a325e964789139b1c5181fe9fe80efdbc261"))

    // Secret 2: all ones.
    let (x2, y2) = MSE.deriveKeys(secret: hex(String(repeating: "01", count: 96)))
    #expect(x2 == hex("c6907fd9ccd3cdfa0f5b92c1126e34092cfa4e12"))
    #expect(y2 == hex("8fae9b5a2fc5c397bf1d88bd8b9550d648cb49dd"))

    // Secret 3: 0x00…0x5f (all 96 byte values in order).
    let secret3 = hex(
        "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        + "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"
        + "404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f"
    )
    let (x3, y3) = MSE.deriveKeys(secret: secret3)
    #expect(x3 == hex("77ae3ec937dfdc8fd56e5a745ff386876a8f8f07"))
    #expect(y3 == hex("d544b0bbc1c14b6d4a04a2af703e22200abb3af8"))

    // Every derived key is exactly 20 bytes.
    #expect(x1.count == 20 && y1.count == 20 && y2.count == 20 && x3.count == 20)
}

// MARK: - Sync point

@Test func testSyncPointArithmetic() {
    // syncPoint(req, ks4) must equal SHA1(req)[0..<4] XOR ks4, computed
    // independently here with CryptoKit.
    let ksA = hex("deadbeef")
    let ksB = hex("001122ff")
    for req in ["req2", "req3"] {
        let h = Array(Insecure.SHA1.hash(data: Data(req.utf8)))
        #expect(MSE.syncPoint(req, keystreamFirst4: ksA) == zip(h.prefix(4), ksA).map(^))
        #expect(MSE.syncPoint(req, keystreamFirst4: ksB) == zip(h.prefix(4), ksB).map(^))
        #expect(MSE.syncPoint(req, keystreamFirst4: ksA).count == 4)
    }
}

@Test func testSyncPointPythonVectors() {
    // Hardcoded values from python3 (hashlib.sha1), fully independent of the
    // CryptoKit code path:
    //   SHA1(b"req2")[0..<4] == 19934d2c   SHA1(b"req3")[0..<4] == d779a86a
    #expect(MSE.syncPoint("req2", keystreamFirst4: hex("deadbeef")) == hex("c73ef3c3"))
    #expect(MSE.syncPoint("req2", keystreamFirst4: hex("001122ff")) == hex("19826fd3"))
    #expect(MSE.syncPoint("req3", keystreamFirst4: hex("deadbeef")) == hex("09d41685"))
    #expect(MSE.syncPoint("req3", keystreamFirst4: hex("001122ff")) == hex("d7688a95"))
}

// MARK: - Constants

@Test func testVCConstant() {
    // Spec: 0x00000401 followed by eleven repetitions of 0x00000100
    // (4 + 11 * 4 = 48 bytes).
    let expected: [UInt8] = [0x00, 0x00, 0x04, 0x01]
        + Array(repeating: [0x00, 0x00, 0x01, 0x00], count: 11).flatMap { $0 }
    #expect(MSE.vc == expected)
    #expect(MSE.vc.count == 48)

    // Structure checks.
    #expect(Array(MSE.vc[0..<4]) == [0x00, 0x00, 0x04, 0x01])
    for i in 0..<11 {
        let start = 4 + i * 4
        #expect(Array(MSE.vc[start..<start + 4]) == [0x00, 0x00, 0x01, 0x00])
    }
}

@Test func testCryptoProvideRC4() {
    #expect(MSE.cryptoProvideRC4 == 0x02)
}