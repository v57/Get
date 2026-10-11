import CryptoKit
import Foundation

/// An expected file digest: what a finished URL download is checked against.
public struct Checksum: Sendable, Codable, Equatable, Hashable {
  public enum Algorithm: String, Sendable, Codable, CaseIterable {
    case md5 = "MD5"
    case sha1 = "SHA-1"
    case sha256 = "SHA-256"
    case sha512 = "SHA-512"

    /// Length of the digest in hex characters.
    public var hexLength: Int {
      switch self {
      case .md5: 32
      case .sha1: 40
      case .sha256: 64
      case .sha512: 128
      }
    }
  }

  public let algorithm: Algorithm
  /// Expected digest, lowercase hex.
  public let hex: String

  public init(algorithm: Algorithm, hex: String) {
    self.algorithm = algorithm
    self.hex = hex.lowercased()
  }

  /// Parse a checksum the user pasted: a hex digest on its own or inside a
  /// line such as `sha256sum` output (`<hex>  file.iso`) or BSD style
  /// (`SHA256 (file.iso) = <hex>`). The algorithm follows from the digest's
  /// length (MD5, SHA-1, SHA-256 or SHA-512). Nil when no digest is found.
  public init?(_ text: String) {
    let tokens = text.split { $0.isWhitespace || "():=,".contains($0) }
    for token in tokens.reversed() {
      guard token.allSatisfy(\.isHexDigit),
        let algorithm = Algorithm.allCases.first(where: { $0.hexLength == token.count })
      else { continue }
      self.init(algorithm: algorithm, hex: String(token))
      return
    }
    return nil
  }

  /// The strongest digest in a `Repr-Digest` (RFC 9530, `sha-256=:base64:`)
  /// or `Digest` (RFC 3230, `SHA-256=base64`) header value. Nil when the
  /// header names no algorithm this type supports.
  public init?(digestHeader: String) {
    let names: [String: Algorithm] = [
      "md5": .md5, "sha": .sha1, "sha-1": .sha1, "sha-256": .sha256, "sha-512": .sha512,
    ]
    var best: Checksum?
    for entry in digestHeader.split(separator: ",") {
      guard let equals = entry.firstIndex(of: "=") else { continue }
      let name = entry[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
      var value = entry[entry.index(after: equals)...].trimmingCharacters(in: .whitespaces)
      if value.hasPrefix(":"), value.hasSuffix(":"), value.count >= 2 {
        value = String(value.dropFirst().dropLast())
      }
      guard let algorithm = names[name], let bytes = Data(base64Encoded: value) else { continue }
      let checksum = Checksum(
        algorithm: algorithm, hex: bytes.map { String(format: "%02x", $0) }.joined())
      guard checksum.hex.count == algorithm.hexLength else { continue }
      let order = Algorithm.allCases
      if best == nil || order.firstIndex(of: algorithm)! > order.firstIndex(of: best!.algorithm)! {
        best = checksum
      }
    }
    guard let best else { return nil }
    self = best
  }

  /// The digest of the file at `url` with this checksum's algorithm, as
  /// lowercase hex. Reads the file in 1 MiB chunks (constant memory).
  public func digest(ofFileAt url: URL) throws -> String {
    switch algorithm {
    case .md5: try Self.hexDigest(Insecure.MD5(), url: url)
    case .sha1: try Self.hexDigest(Insecure.SHA1(), url: url)
    case .sha256: try Self.hexDigest(SHA256(), url: url)
    case .sha512: try Self.hexDigest(SHA512(), url: url)
    }
  }

  private static func hexDigest<H: HashFunction>(_ hasher: H, url: URL) throws -> String {
    var hasher = hasher
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
