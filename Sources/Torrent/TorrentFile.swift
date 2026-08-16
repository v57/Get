import Foundation
import CryptoKit

/// A decoded `.torrent` metainfo file (BEP 3).
///
/// All fields are derived at parse time; `infoHash` is the SHA-1 of the RAW
/// info-dict bytes as they appear in the document (via
/// `Bencode.parseWithRawValue`) — never a re-encode, since key order in the
/// original document is part of the infohash.
public struct TorrentFile: Sendable, Equatable {
    /// Primary announce URL, if present (`announce` key).
    public let announce: String?
    /// Tracker tiers from `announce-list`; empty when absent. Tiers are
    /// flattened by the tracker loop later.
    public let announceList: [[String]]
    /// 20 bytes: SHA-1 of the raw `info` dict bytes.
    public let infoHash: Data
    /// Decoded with UTF-8 replacement fallback (never throws on bad bytes).
    public let name: String
    /// Piece size in bytes.
    public let pieceLength: Int
    /// One 20-byte SHA-1 per piece, in piece order.
    public let pieceHashes: [Data]
    /// Every file in the torrent. Single-file torrents synthesize one entry
    /// whose path is `[name]` (the file lives directly in the save directory);
    /// multi-file entries are path components under the `<name>/` directory.
    public let files: [FileEntry]
    /// Sum of all file lengths in bytes.
    public let totalSize: Int64

    public struct FileEntry: Sendable, Equatable {
        /// Path components relative to the download base directory.
        public let path: [String]
        /// File size in bytes.
        public let length: Int64
    }

    public init(announce: String?, announceList: [[String]], infoHash: Data,
                name: String, pieceLength: Int, pieceHashes: [Data],
                files: [FileEntry], totalSize: Int64) {
        self.announce = announce
        self.announceList = announceList
        self.infoHash = infoHash
        self.name = name
        self.pieceLength = pieceLength
        self.pieceHashes = pieceHashes
        self.files = files
        self.totalSize = totalSize
    }

    /// Parse metainfo from raw `.torrent` bytes.
    public static func parse(_ data: Data) throws -> TorrentFile {
        guard case .dict(let root) = try Bencode.parse(data) else {
            throw BencodeError.malformed("top-level value is not a dict")
        }

        // Infohash over the RAW info bytes in the document, never a re-encode.
        let (_, infoRange) = try Bencode.parseWithRawValue(data, key: Data("info".utf8))
        let infoHash = Data(Insecure.SHA1.hash(data: data[infoRange]))

        // announce
        let announce: String?
        if let value = root[Data("announce".utf8)] {
            announce = try decodeString(value, name: "announce")
        } else {
            announce = nil
        }

        // announce-list (optional tiers)
        var announceList: [[String]] = []
        if let value = root[Data("announce-list".utf8)] {
            guard case .list(let tiers) = value else {
                throw BencodeError.malformed("announce-list is not a list")
            }
            for tier in tiers {
                guard case .list(let urls) = tier else {
                    throw BencodeError.malformed("announce-list tier is not a list")
                }
                announceList.append(try urls.map { try decodeString($0, name: "announce-list URL") })
            }
        }

        // info dict
        guard case .dict(let info) = root[Data("info".utf8)] else {
            throw BencodeError.malformed("info is not a dict")
        }

        let name: String
        if let value = info[Data("name".utf8)] {
            name = try decodeString(value, name: "name")
        } else {
            name = ""
        }

        guard let pieceLengthValue = info[Data("piece length".utf8)] else {
            throw BencodeError.malformed("info missing 'piece length'")
        }
        guard case .int(let pieceLength64) = pieceLengthValue, pieceLength64 > 0 else {
            throw BencodeError.malformed("'piece length' is not a positive integer")
        }
        let pieceLength = Int(pieceLength64)

        guard let piecesValue = info[Data("pieces".utf8)] else {
            throw BencodeError.malformed("info missing 'pieces'")
        }
        guard case .string(let piecesBytes) = piecesValue, piecesBytes.count % 20 == 0 else {
            throw BencodeError.malformed("'pieces' is not a multiple of 20 bytes")
        }
        var pieceHashes: [Data] = []
        pieceHashes.reserveCapacity(piecesBytes.count / 20)
        var hashOffset = 0
        while hashOffset < piecesBytes.count {
            pieceHashes.append(piecesBytes.subdata(in: hashOffset..<(hashOffset + 20)))
            hashOffset += 20
        }

        // Single-file (`length`) vs multi-file (`files`)
        let files: [FileEntry]
        let totalSize: Int64
        if let lengthValue = info[Data("length".utf8)] {
            let length = try decodeNonNegativeInt(lengthValue, name: "length")
            files = [FileEntry(path: [name], length: length)]
            totalSize = length
        } else if let filesValue = info[Data("files".utf8)] {
            guard case .list(let fileList) = filesValue else {
                throw BencodeError.malformed("'files' is not a list")
            }
            var entries: [FileEntry] = []
            var sum: Int64 = 0
            for file in fileList {
                guard case .dict(let fileDict) = file else {
                    throw BencodeError.malformed("file entry is not a dict")
                }
                let length = try decodeNonNegativeInt(fileDict[Data("length".utf8)], name: "file length")
                guard let pathValue = fileDict[Data("path".utf8)] else {
                    throw BencodeError.malformed("file entry missing 'path'")
                }
                guard case .list(let pathItems) = pathValue else {
                    throw BencodeError.malformed("file 'path' is not a list")
                }
                let path = try pathItems.map { try decodeString($0, name: "path component") }
                entries.append(FileEntry(path: path, length: length))
                sum += length
            }
            files = entries
            totalSize = sum
        } else {
            throw BencodeError.malformed("info has neither 'length' nor 'files'")
        }

        return TorrentFile(announce: announce, announceList: announceList,
                           infoHash: infoHash, name: name, pieceLength: pieceLength,
                           pieceHashes: pieceHashes, files: files, totalSize: totalSize)
    }

    /// Read and parse a `.torrent` file.
    public static func parse(url: URL) throws -> TorrentFile {
        try parse(Data(contentsOf: url))
    }

    // MARK: - Helpers

    /// UTF-8 decode with U+FFFD replacement for invalid sequences — never throws.
    private static func decodeString(_ value: BencodeValue, name: String) throws -> String {
        guard case .string(let bytes) = value else {
            throw BencodeError.malformed("'\(name)' is not a string")
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func decodeNonNegativeInt(_ value: BencodeValue?, name: String) throws -> Int64 {
        guard case .int(let n)? = value, n >= 0 else {
            throw BencodeError.malformed("'\(name)' is not a non-negative integer")
        }
        return n
    }
}