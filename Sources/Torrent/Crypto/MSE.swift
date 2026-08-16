import CryptoKit
import Foundation

/// Message Stream Encryption (MSE): constants, key derivation, and the
/// plaintext sync-section helpers for the obfuscated handshake.
///
/// Wire format (verified against libtorrent-rasterbar `bt_peer_connection.cpp`
/// and Transmission `handshake.cc`; this client is always the initiator):
///   1. clear:   [Ya 96-byte pubkey][PadA 0-512]
///   2. clear:   [SHA1("req1" || S) 20][SHA1("req2" || SKEY) xor SHA1("req3" || S) 20]
///   3. rc4:     [VC 8][crypto_provide 4][len(PadC) 2][PadC][len(IA) 2][IA 68]
///   4. rc4 recv:[VC 8][crypto_select 4][len(PadD) 2][PadD][handshake 68]
///
/// Keys: initiator send key = SHA1("keyA" || S || SKEY),
///       initiator recv key = SHA1("keyB" || S || SKEY)   (responder mirrors).
/// Both RC4 streams drop the first 1024 keystream bytes before use.
/// S = DH shared secret (96 bytes), SKEY = torrent infohash (20 bytes).
public enum MSE {
    /// Verification constant: 8 zero bytes. (libtorrent: `sh_vc[] = {0,0,0,0,0,0,0,0}`;
    /// Transmission comment: "VC is a String of 8 bytes set to 0x00".)
    public static let vc: [UInt8] = [UInt8](repeating: 0, count: 8)

    /// `crypto_provide` / `crypto_select` values. This client only offers RC4.
    public static let cryptoProvidePlaintext: UInt32 = 0x01
    public static let cryptoProvideRC4: UInt32 = 0x02

    /// Derive the two 20-byte RC4 keys from the DH shared secret and the
    /// torrent's infohash (the "stream key").
    ///   send = SHA1("keyA" || S || SKEY)   — what the initiator encrypts with
    ///   recv = SHA1("keyB" || S || SKEY)   — what the initiator decrypts with
    public static func deriveKeys(secret: [UInt8], streamKey: [UInt8]) -> (send: [UInt8], recv: [UInt8]) {
        (sha1(Array("keyA".utf8), secret, streamKey),
         sha1(Array("keyB".utf8), secret, streamKey))
    }

    /// SHA1("req1" || S) — the 20-byte sync hash sent in the clear so the
    /// responder can verify it derived the same DH secret.
    public static func syncHash(secret: [UInt8]) -> [UInt8] {
        sha1(Array("req1".utf8), secret)
    }

    /// SHA1("req2" || SKEY) XOR SHA1("req3" || S) — the 20-byte obfuscated
    /// infohash sent in the clear; the responder recovers SHA1("req2" || SKEY)
    /// and matches it against its torrents without exposing the infohash on
    /// the wire.
    public static func obfuscatedInfoHash(streamKey: [UInt8], secret: [UInt8]) -> [UInt8] {
        zip(sha1(Array("req2".utf8), streamKey),
            sha1(Array("req3".utf8), secret)).map(^)
    }

    private static func sha1(_ parts: [UInt8]...) -> [UInt8] {
        var data = Data()
        for part in parts { data.append(contentsOf: part) }
        return Array(Insecure.SHA1.hash(data: data))
    }
}
