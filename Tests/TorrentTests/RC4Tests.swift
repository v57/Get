import Testing
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

/// Produce 16 keystream bytes for `key`, optionally discarding the first
/// `dropCount` bytes first (matching the RFC 6229 "offset" semantics).
private func keystream(_ key: [UInt8], dropCount: Int = 0) -> [UInt8] {
    var rc4 = RC4(key: key)
    if dropCount > 0 { rc4.drop(dropCount) }
    var out = [UInt8](repeating: 0, count: 16)
    rc4.stream(&out)
    return out
}

// MARK: - RFC 6229 test vectors (section 2, offset 0)

@Test func rfc6229Key0102030405() {
    #expect(keystream(hex("0102030405")) == hex("b2396305f03dc027ccc3524a0a1118a8"))
}

@Test func rfc6229Key0102030405060708() {
    #expect(keystream(hex("0102030405060708")) == hex("97ab8a1bf0afb96132f2f67258da15a8"))
}

@Test func rfc6229Key0102030405060708090a() {
    #expect(keystream(hex("0102030405060708090a")) == hex("ede3b04643e586cc907dc21851709902"))
}

@Test func rfc6229Key0102030405060708090a0b0c0d0e0f10() {
    #expect(keystream(hex("0102030405060708090a0b0c0d0e0f10")) == hex("9ac7cc9a609d1ef7b2932899cde41b97"))
}

// MARK: - drop(1024): keystream must match the RFC 6229 offset-1024 vectors

@Test func drop1024Key0102030405() {
    #expect(keystream(hex("0102030405"), dropCount: 1024) == hex("30abbcc7c20b01609f23ee2d5f6bb7df"))
}

@Test func drop1024Key0102030405060708() {
    #expect(keystream(hex("0102030405060708"), dropCount: 1024) == hex("c6d0e7b226259fa9023490b26167ad1d"))
}

// MARK: - stream() mutates the input in place (XOR)

@Test func streamMutatesInputInPlace() {
    let key = hex("0102030405060708")
    var data: [UInt8] = Array("The quick brown fox jumps over the lazy dog".utf8)
    let original = data

    var rc4 = RC4(key: key)
    rc4.stream(&data)

    // First pass: ciphertext differs from the plaintext…
    #expect(data != original)

    // …and equals the plaintext XORed with the raw keystream.
    var keystreamBytes = [UInt8](repeating: 0, count: data.count)
    var reference = RC4(key: key)
    reference.stream(&keystreamBytes)
    #expect(data == zip(original, keystreamBytes).map(^))

    // Decryption is the same operation with a fresh cipher for the same key:
    // XORing the same keystream again restores the original plaintext.
    var decryptor = RC4(key: key)
    decryptor.stream(&data)
    #expect(data == original)
}

@Test func emptyKeyIsSafe() {
    // Empty keys are not used in practice (MSE keys are 20 bytes), but init
    // must not trap; the cipher still produces a deterministic stream.
    var rc4 = RC4(key: [])
    var out = [UInt8](repeating: 0, count: 16)
    rc4.drop(1024)
    rc4.stream(&out)
    #expect(out != [UInt8](repeating: 0, count: 16))
}
