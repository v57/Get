import CryptoKit
import Foundation

/// Message Stream Encryption (MSE): key derivation and sync-point helpers.
///
/// MSE wraps the BitTorrent wire protocol in RC4 (obfuscation, not
/// authentication). This file only covers the key-derivation part of the
/// handshake; the actual preamble exchange lives in `MSEHandshake`
/// (Task 10) and `PeerConnection` (Task 12).
public enum MSE {
    /// Verification constant (VC): `0x00000401` followed by eleven
    /// repetitions of `0x00000100` (4 + 11 * 4 = 48 bytes).
    public static let vc: [UInt8] = {
        var bytes: [UInt8] = [0x00, 0x00, 0x04, 0x01]
        for _ in 0..<11 {
            bytes += [0x00, 0x00, 0x01, 0x00]
        }
        return bytes
    }()

    /// `crypto_provide` value meaning "RC4 allowed" (the only cipher MSE
    /// supports; plaintext `0x01` is never offered by this client).
    public static let cryptoProvideRC4: UInt32 = 0x02

    /// Derive the two 20-byte RC4 keys from the DH shared secret.
    ///
    /// Per the MSE spec:
    ///   h    = SHA1(secret)
    ///   rep  = the 20-byte repetition of the ASCII string ("keyA" / "keyB")
    ///   mix  = h XOR rep
    ///   X    = SHA1(mix for "keyA")   — the initiator SEND key
    ///   Y    = SHA1(mix for "keyB")   — the initiator RECEIVE key
    /// The responder mirrors both. Returning a labeled tuple plus this doc
    /// comment is the authoritative mapping; callers must not swap the pair.
    public static func deriveKeys(secret: [UInt8]) -> (x: [UInt8], y: [UInt8]) {
        let h = Array(Insecure.SHA1.hash(data: Data(secret)))
        func rep(_ s: String) -> [UInt8] {
            let b = Array(s.utf8)
            return (0..<20).map { b[$0 % b.count] }
        }
        func mix(_ s: String) -> [UInt8] { zip(h, rep(s)).map(^) }
        return (Array(Insecure.SHA1.hash(data: Data(mix("keyA")))),
                Array(Insecure.SHA1.hash(data: Data(mix("keyB")))))
    }

    /// The 4 sync bytes a side sends: `SHA1(req)[0..<4] XOR` the first 4 raw
    /// keystream bytes of the stream it encrypts with (`"req3"` for the
    /// initiator's send stream, `"req2"` for the responder's).
    /// The receiver decrypts incoming sync bytes with its receive stream and
    /// gets the plain hash back iff the streams are aligned.
    public static func syncPoint(_ req: String, keystreamFirst4: [UInt8]) -> [UInt8] {
        let h = Array(Insecure.SHA1.hash(data: Data(req.utf8)))
        return zip(keystreamFirst4, h).map(^)
    }
}