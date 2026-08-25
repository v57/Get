import CryptoKit
import Foundation
import Torrent

/// Builds valid in-memory `.torrent` documents for tests.
///
/// Self-contained: only depends on `Bencode` and `TorrentFile` from the
/// `Torrent` module. Later tasks (fake seeder, file-layout tests) can reuse
/// it as-is.
enum SyntheticTorrent {
  /// Builds a torrent for `data` split into `pieceLength`-byte pieces.
  ///
  /// - Parameters:
  ///   - data: single-file content (used when `files` is nil), or ignored
  ///     when `files` is provided.
  ///   - pieceLength: piece size in bytes.
  ///   - name: torrent name / single-file file name.
  ///   - files: when nil a single-file torrent (`length` in info) is produced;
  ///     otherwise a multi-file torrent (`files` in info). The per-file data
  ///     is concatenated in order to form the content stream, and piece
  ///     hashes are computed over that concatenation.
  ///   - announce: tracker announce URL.
  /// - Returns: the raw encoded `.torrent` bytes, the parsed `TorrentFile`,
  ///   and the concatenated content stream. `torrent` is derived by parsing
  ///   the bytes we just encoded (never constructed by hand).
  static func make(
    data: Data, pieceLength: Int = 16 * 1024, name: String = "synthetic.bin",
    files: [(path: [String], data: Data)]? = nil,
    announce: String = "http://127.0.0.1:6969/announce"
  ) throws -> (data: Data, torrent: TorrentFile, content: Data) {
    let content: Data
    if let files {
      content = files.reduce(into: Data()) { $0.append($1.data) }
    } else {
      content = data
    }

    // SHA-1 per piece over the concatenated content stream. An empty
    // content produces an empty (0-piece) hash string.
    var pieces = Data()
    var offset = 0
    while offset < content.count {
      let end = min(offset + pieceLength, content.count)
      pieces.append(Data(Insecure.SHA1.hash(data: content[offset..<end])))
      offset = end
    }

    var info: [Data: BencodeValue] = [
      Data("name".utf8): .string(Data(name.utf8)),
      Data("piece length".utf8): .int(Int64(pieceLength)), Data("pieces".utf8): .string(pieces),
    ]
    if let files {
      let fileDicts: [BencodeValue] = files.map { file in
        .dict([
          Data("length".utf8): .int(Int64(file.data.count)),
          Data("path".utf8): .list(file.path.map { .string(Data($0.utf8)) }),
        ])
      }
      info[Data("files".utf8)] = .list(fileDicts)
    } else {
      info[Data("length".utf8)] = .int(Int64(data.count))
    }

    let root: BencodeValue = .dict([
      Data("announce".utf8): .string(Data(announce.utf8)), Data("info".utf8): .dict(info),
    ])
    let encoded = Bencode.encode(root)
    return (encoded, try TorrentFile.parse(encoded), content)
  }
}
