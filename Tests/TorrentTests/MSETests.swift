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

private let exampleInfoHash = hex("9fbb17d030f7f5c51310fa49319eb28a30eb3329")

@Test func testKeyDerivationMatchesPythonVectors() {
    // Vectors produced with python3 for each fixed 96-byte secret S and
    // SKEY = 9fbb17d030f7f5c51310fa49319eb28a30eb3329:
    //   send = hashlib.sha1(b"keyA" + S + SKEY).digest()
    //   recv = hashlib.sha1(b"keyB" + S + SKEY).digest()

    // Secret 1: all zeros.
    let (send1, recv1) = MSE.deriveKeys(secret: hex(String(repeating: "00", count: 96)), streamKey: exampleInfoHash)
    #expect(send1 == hex("da88b2b2977d69ad53130312ce060f1a5917faad"))
    #expect(recv1 == hex("39c30e972ac514f9c09ba3b46a7b8bfb1a06f3b0"))

    // Secret 2: all ones.
    let (send2, recv2) = MSE.deriveKeys(secret: hex(String(repeating: "01", count: 96)), streamKey: exampleInfoHash)
    #expect(send2 == hex("1969da82a2563775e85709120995a8f09dd15777"))
    #expect(recv2 == hex("4962abec49ab4d2b4a8e67a8fa58867b1c55dd99"))

    // Secret 3: 0x00…0x5f (all 96 byte values in order).
    let secret3 = hex(
        "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        + "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"
        + "404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f"
    )
    let (send3, recv3) = MSE.deriveKeys(secret: secret3, streamKey: exampleInfoHash)
    #expect(send3 == hex("c41e8f5ce3753e1f7f03a6e40f6ebcb6e20859b5"))
    #expect(recv3 == hex("e30023f8a73eeb4c16092f9e01fd41dd1e5d99a2"))

    // Every derived key is exactly 20 bytes.
    #expect(send1.count == 20 && recv1.count == 20 && send2.count == 20 && recv3.count == 20)
}

@Test func testKeyDerivationZeroStreamKey() {
    // Same derivation with a zero infohash — keys must differ from the
    // example-infohash vectors (stream key is part of the hash input).
    let zeros = hex(String(repeating: "00", count: 96))
    let zeroSKEY = hex(String(repeating: "00", count: 20))
    let (send, recv) = MSE.deriveKeys(secret: zeros, streamKey: zeroSKEY)
    #expect(send == hex("3c40e353550d292107334c64298ad190be48e885"))
    #expect(recv == hex("654248c291321c7d7ec43d6562d6bf5868324654"))
}

// MARK: - Sync hash

@Test func testSyncHashPythonVectors() {
    // SHA1(b"req1" + S) — python3-generated.
    #expect(MSE.syncHash(secret: hex(String(repeating: "00", count: 96)))
            == hex("4537f2615276f60fb7b87299df4aef4a6ff144ae"))
    #expect(MSE.syncHash(secret: hex(String(repeating: "01", count: 96)))
            == hex("9ccfd0c27d80ebf95c871922da64f88a8a2faddd"))
}

@Test func testSyncHashArithmetic() {
    // Independent computation with CryptoKit directly.
    let secret = hex(String(repeating: "ab", count: 96))
    let expected = Array(Insecure.SHA1.hash(data: Data("req1".utf8) + Data(secret)))
    #expect(MSE.syncHash(secret: secret) == expected)
}

// MARK: - Obfuscated infohash

@Test func testObfuscatedInfoHashPythonVectors() {
    // SHA1(b"req2" + SKEY) xor SHA1(b"req3" + S) — python3-generated.
    let zeros = hex(String(repeating: "00", count: 96))
    #expect(MSE.obfuscatedInfoHash(streamKey: exampleInfoHash, secret: zeros)
            == hex("366aac2d22ce47ff24f432909c8b40e28e616a95"))
    #expect(MSE.obfuscatedInfoHash(streamKey: exampleInfoHash, secret: hex(String(repeating: "01", count: 96)))
            == hex("b1f27cbce0b26653bc06a136396887f51b38f952"))
}

@Test func testObfuscatedInfoHashArithmetic() {
    // Independent computation with CryptoKit directly.
    let secret = hex(String(repeating: "cd", count: 96))
    let req2 = Array(Insecure.SHA1.hash(data: Data("req2".utf8) + Data(exampleInfoHash)))
    let req3 = Array(Insecure.SHA1.hash(data: Data("req3".utf8) + Data(secret)))
    let expected = zip(req2, req3).map(^)
    #expect(MSE.obfuscatedInfoHash(streamKey: exampleInfoHash, secret: secret) == expected)
}

// MARK: - Constants

@Test func testVCConstant() {
    // Spec: 8 bytes set to 0x00 (libtorrent sh_vc, Transmission VC).
    #expect(MSE.vc == [UInt8](repeating: 0, count: 8))
    #expect(MSE.vc.count == 8)
}

@Test func testCryptoProvideValues() {
    #expect(MSE.cryptoProvideRC4 == 0x02)
    #expect(MSE.cryptoProvidePlaintext == 0x01)
}
