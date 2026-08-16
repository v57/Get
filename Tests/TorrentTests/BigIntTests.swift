import Testing
import Torrent

/// Hex decode helper: "deadbeef" -> [0xde, 0xad, 0xbe, 0xef].
func bytesFromHex(_ hex: String) -> [UInt8] {
    var result: [UInt8] = []
    result.reserveCapacity(hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        result.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return result
}

/// The 96-byte big-endian MSE prime (canonical, one line).
let canonicalMSEPrimeHex =
    "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD1"
    + "29024E088A67CC74020BBEA63B139B22514A08798E3404DD"
    + "EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245"
    + "E485B576625E7EC6F44C42E9A63A3620FFFFFFFFFFFFFFFF"

@Suite("768-bit modular exponentiation")
struct BigIntTests {

    /// MSEPrime.bytes must be exactly 96 bytes and equal the canonical hex.
    @Test("MSEPrime.bytes is the canonical 96-byte prime")
    func testMSEPrimeConstant() {
        let prime = MSEPrime.bytes
        #expect(prime.count == 96)
        #expect(prime == bytesFromHex(canonicalMSEPrimeHex))
    }

    /// Five (plus two extra) random 96-byte base/exponent vectors generated with
    /// python3: pow(int(base, 16), int(exp, 16), p) — the acceptance bar.
    @Test("modPow matches python pow() on generated vectors", arguments: [
        (
            // vector 0
            base: "12fd20923d8f4d7244b69ffef8bc6e03280a7f59324c47a738bad9caa128ca5ba9964d6238fb368ce7ee21441f31ab86448bf771a8228db61b2daf9c20890523dd016f4f20c297769b61bacc52ba473eb7e5ec9b456bea06ac952e709480899c",
            exp: "4e4cf8e9f9c16e8e7ed9010be52f8dc46002c4ab2678457a53221550ea1b21e906778627456859d021aeef452dd41ccbb0c19bc16995282459fe53d0f748df503ca7bb81f0705a0b7a01dfdfeee3f159b01e9b3e99ff9439f3673147cfd18317",
            want: "b71304eefb09a6d5e790ea0584ae2d980b41627333835648d84296130c05da1d564ab4ccc39856ced6f89a25069a086646d939ee92f90e14a70fbedc768e04fa00e9d7d67a62e0bfbb8d36d4e550052db1a71ee07eb765ec43dc7531a8b8aceb"
        ),
        (
            // vector 1
            base: "ad1fcee3fe197998713461f90e0c1926c64a399abbb23f210e073159a96596c9e4853702a0b063d3d0d1e24f2d5ea6d536cb2d2517f09422e72ea1ebb6c27f804c2b0c1be6e9b94a6a72138897670cbb20bfd89af10ed2a44208a9254c207b54",
            exp: "b6eb097b7f7d2de3d794d474fa87380e433fa8c70db9e36e74474243daf660a2ea564a716a9bba9fad5c1716d5e9327afb5da727cd9170d207a22fcc033251356e2a1b50aeae199c438c293ab42274857962118411fb3b7381c619bd2f8ce7d0",
            want: "df9eb1987bfda530977870ba6d6fa7701a1c245e1f6bddf652bba54cb549fe6a7f6abf924f1ce26cef5ad0a16136a3ac9d68a77245d7988e87ec07aeb93b39661d35516d01a8bc46d48b5aa045bc18cdb2228f0c0ce1ef54ce02a7f0841a9f52"
        ),
        (
            // vector 2
            base: "b256ee390a65793928b28d96cfa4239f6951ac443436c064499213f05ad098aec2c058242056283acd95fa284ac552dc53590a63b52e491a58ed0a77b6f3228b64af1b6285c8612f4e03cc5a66fc26b62e7370bedee1f6148a6ee87ad9433f02",
            exp: "29dbe5d419e39cdb90c357b0e30141ce957477f3414ee743bc21a3f2d12ac14fa80992f232e52baff1cbb5e150b6a432171bd7d976fd9f8e0933f848a21db9a550f2dbc09d8ad86c5dde4b1092eaf00b9fecd913559d06210cd78cd457e81c6b",
            want: "36a50f5ef3208f178b2f41e3ec0e2633fa9bdaceb3279a7a424a62fbfa7765d506ade9a293d7610c0a619937e465b333420fbd5f2bef9203b332165f869708a05028cf69f5890957ddce7aa46754e2c72e59990238a638be30867c2838b36462"
        ),
        (
            // vector 3
            base: "97ccc219e9afb1a98ce3924781c09f3e7d15223a5a8e516823bea227f806a5bd3cf3b2b679bfbe422a007e9c29bbe052ef7011074594d494c58596093e4967f3e43fcc85177a1e8825e717e46ab9f841e87bc55af20f9acd6c2f87299029341c",
            exp: "dd1ff34ca4b0f00541ea30b147db2a514b65eb770643ccf7b2c1d76d20e759c9ba97b4d8e45741e6eab280021e63bb776d4a43f55310e27d26003787dae2210cb2b971c7de329d82fee79f054469f7315104defccfa9295b985efc73a2fb3803",
            want: "5ec43104215e5f88050e5a81efa41cd91637537da1b08dff402e5c0583be1eb73ef54e0aac670f54829c3c26a1a5896bf1dafd3d2acf6e71f26d8d581fb94c5125dc2ec448d8788cf9fa298afdd58e2fa71b24440be9c5c07cbe2495650a9d54"
        ),
        (
            // vector 4
            base: "885f74d5bdafd264bf2a187245ccbef488dcb29a691a407436cb7c07ab8ed81bfa9c143c584bfd6b25a282551fe7d6cf065bca0e95a6bc0e4488300f3d418f423d8800bcf0976a1df7becabd227bbc15e20084394d9e00ff320a03eb17d30034",
            exp: "32d2141219e9489ae1e8360e748ec476bb71e9a8f5d4dae992cd824e13736e8a50e57c1b90fe64d6d502d8c2cd5a0cac2694391b21c9f3e64185f2dce88fd110d734588518aa3d664fa3a17f9296b4faf0d3b7ee6243a54ff9c31d22eccc0ee0",
            want: "f59b901cd9fc2e03e7c038c3f084e681e4d991fbd87db07fc8f972d8c5ecc270ac3d8e30af3b9eadfc24eca55bce49a4a8028f2eb993eb8d319aa8b9d8a1b537fee6f39e658f276847b32271a923b5dd35978bcbba57a55f30fcbcb2857cebe7"
        ),
        (
            // vector 5 (extra random)
            base: "c643e653ad689cf88759f153b7785728f2655b19153d3a3f56bc09cb91215785d99773382dd301c8a91afa5c7623c4dd26fb984f366c5acdaeafb905dc8ac0bb635b4c41d283eb3a5fbd238ec9cf158de6e96d45cae8c077377925b396a1da2c",
            exp: "210f4d0c5b86c0ef0d2329d9fa09ca46767389669b02a56d32b55d35e67646f184c69290764b501814b062ae88c88ad1eee1f220fd5475125ccedc773429e79c6cda4ccb01f35efe8ed5f03644f758cd0aeb34f96712489050fe32817812f171",
            want: "7fc29fc4ccb1c729401c3819701c464954657eef8c7e1c166df91307102bcb68d944c56a6e7b5b330216d9c5a0924f3be2b796b8368e06063beb8b248161522d93cafd85e8353e068d1cd771f6e42f09da0531d55eae950e018a3dff2fbc89f9"
        ),
        (
            // vector 6 (extra random)
            base: "6b451936d1d5c42faf11c1e779462a342bd2ed1c05f73dba1c1b5b32097ce80c2d0fd6d9a90965f580d16aaff1a41fe52d78dc4bfb9e8ddaecc2c55e986d484271143591cab5f7c4bf5cb443292af8f3b713b4c7ebb7344df3d2273a37403227",
            exp: "6770fa788ba3fb8041f089dc7166a9f536209dbca3f3760f0e2eb028f94cf6b0c986fa9fe66471833367433467c3b9fe85fdadc422c4d84f5467115b618d3f430173745f9e0d54254f4f81b02495da1716055583a1cbb7236ce8571befca6c3b",
            want: "e7944bfb0f535f50570b507da126b9764b5579ce42c364d0b369a51c674772f4557b85752093fc0141abc6e3e507d80df0302f0b2dcb2c27a5cfb210d5250d8539c804051096398fccb139de67763367ef077b00bc1502a203d702ba3e03bfc0"
        ),
    ])
    func testModPowKnownVectors(base: String, exp: String, want: String) {
        let p = MSEPrime.bytes
        let result = modPow(bytesFromHex(base), bytesFromHex(exp), p)
        #expect(result == bytesFromHex(want))
    }

    /// g^1: modPow(2, 1, p) == 2 (the MSE DH base case: pubkey = 2^priv).
    @Test("modPow(2, 1, p) == 2")
    func testGToTheOne() {
        let p = MSEPrime.bytes
        let g = bytesFromHex(String(repeating: "0", count: 191) + "2")
        let one = bytesFromHex(String(repeating: "0", count: 191) + "1")
        let result = modPow(g, one, p)
        #expect(result == g)
        #expect(result == bytesFromHex(String(repeating: "0", count: 191) + "2"))
    }

    /// 1^huge == 1.
    @Test("modPow(1, 0xFF…FF, p) == 1")
    func testOneToHugePower() {
        let p = MSEPrime.bytes
        let one = bytesFromHex(String(repeating: "0", count: 191) + "1")
        let huge = bytesFromHex(String(repeating: "f", count: 192))
        #expect(modPow(one, huge, p) == one)
    }

    /// 0^e == 0.
    @Test("modPow(0, e, p) == 0")
    func testZeroToPower() {
        let p = MSEPrime.bytes
        let zero = [UInt8](repeating: 0, count: 96)
        let e = bytesFromHex(
            "d1b93ed486b81816126b01e815db2c6d4a8143a1f980857d9c7d7e7126e0cfb9"
            + "4ec35ebe94fc3ddbe4e1f786aa188b09938e29864a6db1a81d9b19feb41616ad"
            + "cd6426e9c93c9c53c178c1fcedf888c0ed6e9908444f7a229426cfc70828ad72")
        #expect(modPow(zero, e, p) == zero)
    }

    /// Base >= modulus must be reduced first (base = 2^768 - 1).
    @Test("modPow reduces base >= modulus (2^768-1)")
    func testBaseGreaterThanModulus() {
        let p = MSEPrime.bytes
        let base = [UInt8](repeating: 0xFF, count: 96)
        let exp = bytesFromHex(
            "eafd0ab418bab9bfb41700374e04ac9443164bf18b234fe095b527af36e9cfe6"
            + "cd4a9a5d98ae81fc54a3b39cb7023d43589634ff23503726c3246cdf381c3d00"
            + "f96a7e76db8123a0d23cb934b9af2cb9742bf3ca520363aca01be8809a14d159")
        let want = bytesFromHex(
            "50edd660d18bf986bd7e859dc62910ae02685ccb59a4048822d5853113173be2"
            + "d7658f085798e66b6d8c38f035645a1e05e11c10788ea129dd8f978368b724f4"
            + "c9009c4e642d852977ada4e7784974d1d0f7c7a8010234c38c28180d0e5188d6")
        #expect(modPow(base, exp, p) == want)
    }

    /// Base == modulus means the result is 0 for e > 0.
    @Test("modPow(p, e, p) == 0")
    func testBaseEqualsModulus() {
        let p = MSEPrime.bytes
        let e = bytesFromHex(
            "2c244c2efb08c12802671b4b20e98c4c2c6a4fcdf512becd0136f3dbc55d826f"
            + "9750e167bc8b5589746af8bd695a4c1a067a2f1a880b018c56a97d4697cfed0e"
            + "1a14f0946cad6f4a6aa1e24307dd21462aebb03c3672f572c208deb551c43c8e")
        #expect(modPow(p, e, p) == [UInt8](repeating: 0, count: 96))
    }

    /// Small odd moduli exercise the same Montgomery path at reduced size.
    @Test("modPow on small odd moduli")
    func testSmallOddModuli() {
        func bytes(_ n: UInt64) -> [UInt8] {
            var b = [UInt8](repeating: 0, count: 96)
            b[95] = UInt8(n & 0xFF)
            b[94] = UInt8((n >> 8) & 0xFF)
            b[93] = UInt8((n >> 16) & 0xFF)
            b[92] = UInt8((n >> 24) & 0xFF)
            b[91] = UInt8((n >> 32) & 0xFF)
            b[90] = UInt8((n >> 40) & 0xFF)
            b[89] = UInt8((n >> 48) & 0xFF)
            b[88] = UInt8((n >> 56) & 0xFF)
            return b
        }
        // 3^5 mod 7 == 5
        #expect(modPow(bytes(3), bytes(5), bytes(7)) == bytes(5))
        // 2^10 mod 12345 == 1024 (python: pow(2, 10, 12345) == 1024)
        #expect(modPow(bytes(2), bytes(10), bytes(12345)) == bytes(1024))
        // 123^77 mod 999983 == 726833 (python3 pow())
        #expect(modPow(bytes(123), bytes(77), bytes(999_983)) == bytes(726_833))
    }

    /// Even moduli must not trap (plain shift-subtract fallback): 3^5 mod 8 == 3.
    @Test("modPow on an even modulus")
    func testEvenModulus() {
        func bytes(_ n: UInt64) -> [UInt8] {
            var b = [UInt8](repeating: 0, count: 96)
            for i in 0..<8 { b[95 - i] = UInt8((n >> (i * 8)) & 0xFF) }
            return b
        }
        #expect(modPow(bytes(3), bytes(5), bytes(8)) == bytes(3))
        // 7^13 mod 1000 == 407 (python3 pow())
        #expect(modPow(bytes(7), bytes(13), bytes(1000)) == bytes(407))
    }

    /// x^0 == 1 (python: pow(b, 0, m) == 1 % m).
    @Test("modPow(b, 0, p) == 1")
    func testZeroExponent() {
        let p = MSEPrime.bytes
        let zeroExp = [UInt8](repeating: 0, count: 96)
        let base = bytesFromHex(
            "1f9a6f9be5dcaa867851fe93c884f9ee77b93d18e2fe3a30f611cc2eb60de1b7"
            + "c3f632e7a2f410417e4abee029c5506fea7870c72be6a2d54bfdf3b94a8158ea"
            + "9d940e4de8e027aa0f0fdaa837f95ced8c3a7e41905ba3f87de43dc60d8e3d40")
        let one = bytesFromHex(String(repeating: "0", count: 191) + "1")
        #expect(modPow(base, zeroExp, p) == one)
    }
}
