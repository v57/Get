/// RC4 stream cipher as used by BitTorrent's Message Stream Encryption (MSE).
///
/// MSE uses RC4 as an obfuscation layer with 20-byte keys derived from the
/// Diffie-Hellman shared secret, and requires the first 1024 keystream bytes
/// to be discarded (`drop(1024)`).
public struct RC4: Sendable {
    private var s: [UInt8] = Array(0...255)
    private var i: UInt8 = 0, j: UInt8 = 0

    public init(key: [UInt8]) {
        // Empty keys are not used in practice (MSE keys are 20 bytes), but
        // keep init total to avoid a modulo-by-zero trap.
        guard !key.isEmpty else { return }
        var j: UInt8 = 0
        for i in 0..<256 {
            j &+= s[i] &+ key[Int(i) % key.count]
            s.swapAt(i, Int(j))
        }
    }

    /// XOR `data` in place with the keystream.
    public mutating func stream(_ data: inout [UInt8]) {
        for k in data.indices {
            i &+= 1; j &+= s[Int(i)]
            s.swapAt(Int(i), Int(j))
            data[k] ^= s[Int(s[Int(i)] &+ s[Int(j)])]
        }
    }

    /// Discard `count` keystream bytes (MSE requires 1024).
    public mutating func drop(_ count: Int) {
        var junk = [UInt8](repeating: 0, count: count)
        stream(&junk)
    }
}
