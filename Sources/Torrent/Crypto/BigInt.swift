// BigInt.swift
//
// 768-bit modular exponentiation for the MSE (Message Stream Encryption)
// Diffie-Hellman key exchange. Swift has no bignum, so this file implements a
// small limb-based arithmetic core: 12 x UInt64 limbs, little-endian.
//
// The public API is wire-shaped: every value is a big-endian byte array of up
// to 96 bytes (768 bits), and the result is zero-padded to exactly 96 bytes.
//
// Odd moduli (the MSE prime, and every DH modulus used in practice) go through
// Montgomery multiplication (Handbook of Applied Cryptography §14.3.2) with
// R = 2^768; even moduli fall back to a plain shift-subtract square-and-multiply
// so the function is total over non-zero 96-byte moduli.
//
// Correctness is cross-validated against Python's pow() in BigIntTests.swift.

/// The fixed 768-bit prime from the MSE spec (bittorrent.org / Vuze wiki),
/// used for the MSE Diffie-Hellman exchange. Big-endian, 96 bytes.
public enum MSEPrime: Sendable {
    /// The 768-bit prime as 96 big-endian bytes.
    public static let bytes: [UInt8] = hexDecode(
        "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD1"
        + "29024E088A67CC74020BBEA63B139B22514A08798E3404DD"
        + "EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245"
        + "E485B576625E7EC6F44C42E9A63A3620FFFFFFFFFFFFFFFF"
    )
}

/// Returns `base^exponent mod modulus`.
///
/// All inputs are big-endian byte arrays of at most 96 bytes (768-bit values
/// as they appear on the wire); the result is always exactly 96 bytes.
///
/// - Precondition: `modulus` is non-zero and no input exceeds 96 bytes.
public func modPow(_ base: [UInt8], _ exponent: [UInt8], _ modulus: [UInt8]) -> [UInt8] {
    precondition(modulus.count <= 96, "modulus must be at most 96 bytes")
    precondition(base.count <= 96, "base must be at most 96 bytes")
    precondition(exponent.count <= 96, "exponent must be at most 96 bytes")

    let n = toLimbs(modulus)
    precondition(!isZero(n), "modulus must be non-zero")

    let b = toLimbs(base)
    let e = toLimbs(exponent)

    // Python semantics: pow(x, y, 1) == 0, pow(x, 0, m) == 1 % m.
    if isOne(n) { return [UInt8](repeating: 0, count: 96) }
    if isZero(e) { return toBytes([1] + [UInt64](repeating: 0, count: limbCount - 1)) }

    // Reduce the base first so all internal values stay below the modulus.
    let baseReduced = reduce(b, mod: n)
    if isZero(baseReduced) { return [UInt8](repeating: 0, count: 96) }

    let result: [UInt64]
    if n[0] & 1 == 1 {
        result = modPowMontgomery(baseReduced, e, n)
    } else {
        result = modPowPlain(baseReduced, e, n)
    }
    return toBytes(result)
}

// MARK: - Limb representation

private let limbCount = 12  // 96 bytes = 768 bits = 12 x UInt64

/// Big-endian bytes -> little-endian limbs, zero-padded to 12 limbs.
private func toLimbs(_ bytes: [UInt8]) -> [UInt64] {
    var limbs = [UInt64](repeating: 0, count: limbCount)
    for (i, byte) in bytes.enumerated() {
        let position = bytes.count - 1 - i
        limbs[position / 8] |= UInt64(byte) << UInt64((position % 8) * 8)
    }
    return limbs
}

/// Little-endian limbs -> 96 big-endian bytes.
private func toBytes(_ limbs: [UInt64]) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 96)
    for (limbIndex, limb) in limbs.enumerated() {
        var v = limb
        for byteInLimb in 0..<8 {
            bytes[(limbCount - 1 - limbIndex) * 8 + (7 - byteInLimb)] = UInt8(v & 0xFF)
            v >>= 8
        }
    }
    return bytes
}

private func isZero(_ a: [UInt64]) -> Bool { a.allSatisfy { $0 == 0 } }

private func isOne(_ a: [UInt64]) -> Bool { a[0] == 1 && a.dropFirst().allSatisfy { $0 == 0 } }

/// Three-way comparison of equal-length little-endian arrays: -1, 0, or 1.
private func compare(_ a: [UInt64], _ b: [UInt64]) -> Int {
    for i in stride(from: a.count - 1, through: 0, by: -1) {
        if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
    }
    return 0
}

/// `(a - b) mod 2^(64·count)` — works for a < b too (modular borrow).
private func subtractMod(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
    var result = a
    var borrow: UInt64 = 0
    for i in 0..<a.count {
        let (d1, o1) = result[i].subtractingReportingOverflow(b[i])
        let (d2, o2) = d1.subtractingReportingOverflow(borrow)
        result[i] = d2
        borrow = (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
    }
    return result
}

/// `t[pos] += lo`, `t[pos+1] += hi` (a 128-bit contribution) with full carry
/// propagation. Exact: no intermediate addition can lose a carry bit.
/// `t` must have at least `pos + 3` limbs (headroom for the final carry).
private func add128(_ t: inout [UInt64], _ pos: Int, _ hi: UInt64, _ lo: UInt64) {
    var carry: UInt64 = 0
    let (s1, o1) = t[pos].addingReportingOverflow(lo)
    t[pos] = s1
    carry = o1 ? 1 : 0
    let (s2, o2) = t[pos + 1].addingReportingOverflow(hi)
    let (s3, o3) = s2.addingReportingOverflow(carry)
    t[pos + 1] = s3
    carry = (o2 ? 1 : 0) &+ (o3 ? 1 : 0)
    var p = pos + 2
    while carry != 0 {
        let (sum, overflow) = t[p].addingReportingOverflow(carry)
        t[p] = sum
        carry = overflow ? 1 : 0
        p += 1
    }
}

/// `x mod n` for x < 2^(64·limbCount), n non-zero, via bit-by-bit shift-subtract.
private func reduce(_ x: [UInt64], mod n: [UInt64]) -> [UInt64] {
    var r = [UInt64](repeating: 0, count: limbCount)
    for bit in stride(from: 64 * limbCount - 1, through: 0, by: -1) {
        var overflow = false
        for i in 0..<limbCount {
            let (s, o) = r[i].multipliedReportingOverflow(by: 2)
            r[i] = s &+ (overflow ? 1 : 0)
            overflow = o
        }
        r[0] |= (x[bit / 64] >> UInt64(bit % 64)) & 1
        if overflow || compare(r, n) >= 0 {
            r = subtractMod(r, n)  // r < n -> 2r + bit < 2n, one subtraction suffices
        }
    }
    return r
}

// MARK: - Montgomery multiplication (HAC 14.3.2)

/// Montgomery reduction of a 2n-limb value: returns `t * R^-1 mod n` (n odd).
/// The low n limbs of the result are proven zero by the construction of m'.
private func montgomeryReduce(_ t0: [UInt64], _ n: [UInt64], _ mPrime: UInt64) -> [UInt64] {
    var t = t0 + [UInt64](repeating: 0, count: 2)  // 2n + 2 limbs of headroom
    for i in 0..<limbCount {
        let u = t[i] &* mPrime  // chosen so t[i] + u·n ≡ 0 (mod 2^64)
        for j in 0..<limbCount {
            let (hi, lo) = u.multipliedFullWidth(by: n[j])  // returns (high, low)
            add128(&t, i + j, hi, lo)
        }
        assert(t[i] == 0, "Montgomery reduction failed to zero limb \(i)")
    }
    // t + m·n < 2·n·R, so the top n+1 limbs are < 2n: one subtraction suffices.
    let top = Array(t[limbCount...])            // n + 2 limbs
    let nPadded = n + [UInt64](repeating: 0, count: 2)
    var result = top
    if compare(result, nPadded) >= 0 {
        result = subtractMod(result, nPadded)
    }
    return Array(result.prefix(limbCount))
}

/// Montgomery multiplication: `a·b·R^-1 mod n`, requires a, b < n, n odd.
private func montMul(_ a: [UInt64], _ b: [UInt64], _ n: [UInt64], _ mPrime: UInt64) -> [UInt64] {
    var t = [UInt64](repeating: 0, count: 2 * limbCount + 2)  // headroom for carries
    for i in 0..<limbCount {
        for j in 0..<limbCount {
            let (hi, lo) = a[i].multipliedFullWidth(by: b[j])  // returns (high, low)
            add128(&t, i + j, hi, lo)
        }
    }
    return montgomeryReduce(Array(t.prefix(2 * limbCount)), n, mPrime)
}

/// `R^2 mod n` with R = 2^768, by doubling from 1 (1536 times).
private func rSquaredMod(_ n: [UInt64]) -> [UInt64] {
    var r2 = [UInt64](repeating: 0, count: limbCount)
    r2[0] = 1
    for _ in 0..<(2 * 64 * limbCount) {
        var overflow = false
        for i in 0..<limbCount {
            let (s, o) = r2[i].multipliedReportingOverflow(by: 2)
            r2[i] = s &+ (overflow ? 1 : 0)
            overflow = o
        }
        if overflow || compare(r2, n) >= 0 {
            r2 = subtractMod(r2, n)
        }
    }
    return r2
}

/// Binary square-and-multiply over the 768-bit exponent using Montgomery
/// multiplication. Requires base < n, n odd.
private func modPowMontgomery(_ base: [UInt64], _ exponent: [UInt64], _ n: [UInt64]) -> [UInt64] {
    // m' = -n^-1 mod 2^64 via Newton iteration (n odd => inverse exists).
    var inv = n[0]
    for _ in 0..<6 {
        inv = inv &* (2 &- n[0] &* inv)
    }
    let mPrime = 0 &- inv

    let r2 = rSquaredMod(n)
    let oneMontgomery = montMul([1] + [UInt64](repeating: 0, count: limbCount - 1), r2, n, mPrime)
    let baseMontgomery = montMul(base, r2, n, mPrime)

    var result = oneMontgomery
    for bit in stride(from: 64 * limbCount - 1, through: 0, by: -1) {
        result = montMul(result, result, n, mPrime)
        if ((exponent[bit / 64] >> UInt64(bit % 64)) & 1) == 1 {
            result = montMul(result, baseMontgomery, n, mPrime)
        }
    }
    // Back to normal representation: result·R^-1 mod n = REDC(result).
    return montgomeryReduce(result + [UInt64](repeating: 0, count: limbCount), n, mPrime)
}

// MARK: - Plain path (even moduli)

/// Plain modular multiplication: schoolbook 24-limb product + shift-subtract
/// reduction. Used only when the modulus is even (Montgomery requires odd).
private func mulModPlain(_ a: [UInt64], _ b: [UInt64], _ n: [UInt64]) -> [UInt64] {
    var t = [UInt64](repeating: 0, count: 2 * limbCount + 2)  // headroom for carries
    for i in 0..<limbCount {
        for j in 0..<limbCount {
            let (hi, lo) = a[i].multipliedFullWidth(by: b[j])  // returns (high, low)
            add128(&t, i + j, hi, lo)
        }
    }
    var r = [UInt64](repeating: 0, count: limbCount)
    for bit in stride(from: 2 * 64 * limbCount - 1, through: 0, by: -1) {
        var overflow = false
        for i in 0..<limbCount {
            let (s, o) = r[i].multipliedReportingOverflow(by: 2)
            r[i] = s &+ (overflow ? 1 : 0)
            overflow = o
        }
        r[0] |= (t[bit / 64] >> UInt64(bit % 64)) & 1
        if overflow || compare(r, n) >= 0 {
            r = subtractMod(r, n)
        }
    }
    return r
}

/// Binary square-and-multiply over the 768-bit exponent, plain arithmetic.
private func modPowPlain(_ base: [UInt64], _ exponent: [UInt64], _ n: [UInt64]) -> [UInt64] {
    var result = [UInt64](repeating: 0, count: limbCount)
    result[0] = 1
    var b = base
    for bit in stride(from: 64 * limbCount - 1, through: 0, by: -1) {
        result = mulModPlain(result, result, n)
        if ((exponent[bit / 64] >> UInt64(bit % 64)) & 1) == 1 {
            result = mulModPlain(result, b, n)
        }
    }
    return result
}

// MARK: - Hex

private func hexDecode(_ hex: String) -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        bytes.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}
