# Torrent

Get's BitTorrent engine, written in Swift: `.torrent` files, trackers, the DHT, encrypted peer connections and piece
verification. Part of [Get](README.md).

<!-- platforms: macos linux windows -->

## Purpose

`Torrent` downloads one torrent per `TorrentSession`. It reads the `.torrent` file, finds peers through the
trackers (HTTP and UDP), the DHT and peer exchange, downloads pieces in order (each file from its start, files in
natural name order), checks each piece's SHA-1 and writes it into place. It keeps enough state to continue after a
relaunch, and lets the app pause, prioritize or remove single files.

It downloads only. It never uploads a piece: requests from peers are ignored, during and after a download, so it
can't seed. It doesn't fetch a torrent's metadata from peers, so a magnet link alone can't start a download
(`MagnetLink` only parses one). There's no UPnP, NAT-PMP or local peer discovery.

## Getting started

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/v57/Get.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "Torrent", package: "Get")]),
]
```

The package declares macOS 14. On Linux and Windows it takes CryptoKit, Network and `os` from
[v57/SwiftUI](https://github.com/v57/SwiftUI)'s stand-ins, which its manifest adds there by itself.

```swift
import Foundation
import Torrent

let torrent = try TorrentFile.parse(url: URL(fileURLWithPath: "/path/to/file.torrent"))

var settings = TorrentSettings()            // saves to ~/Downloads
settings.useDHT = true                      // off by default: tests stay off the network
settings.usePEX = true

let session = TorrentSession(torrent: torrent, settings: settings)
Task {
  for await event in session.events {
    switch event {
    case .stats(let stats): print("\(Int(stats.progress * 100))%, \(stats.peersConnected) peers")
    case .state(.completed): print("done")
    case .state(.failed(let reason)): print("failed: \(reason)")
    default: break
    }
  }
}
try await session.start()
```

## Main API

### Reading a torrent

- `TorrentFile.parse(_:)` (`Data`) and `TorrentFile.parse(url:)`: `announce`, `announceList` (tiers),
  `infoHash`, `name`, `pieceLength`, `pieceHashes`, `files` (`FileEntry`: `path` components, `length`) and
  `totalSize`. `naturalFileOrder` gives the file indices sorted the way people read names ("Episode 2" before
  "Episode 10").
- `MagnetLink.parse(_:)`: the info hash, trackers and display name of a `magnet:` URI.
- `Bencode.parse(_:)` and `Bencode.encode(_:)` over `BencodeValue`.

### Settings

`TorrentSettings` (all `var`s):

| Setting | Default | |
|---|---|---|
| `saveDirectory` | `~/Downloads` | a single-file torrent becomes a file here, a multi-file one a folder named after the torrent |
| `useDHT` | `false` | run a DHT node to find peers beyond the trackers |
| `usePEX` | `false` | exchange peer lists with peers that support it |
| `useInbound` | `false` | listen on `listenPort` so other clients can connect (they still get no pieces) |
| `listenPort` | `6881` | the port announced to trackers, and listened on with `useInbound` |
| `encryptedPeersOnly` | `true` | talk only to peers that complete the encrypted (MSE) handshake |
| `maxPeers` | `80` | connections at once |
| `blockSize` | 16 KiB | the size of each request |
| `pipelinePerPeer`, `maxPipelinePerPeer` | `64`, `250` | requests in flight per peer: the start, and the ceiling as it adapts to the peer's measured speed |

Get's app turns on `useDHT`, `usePEX` and `useInbound`.

### Running a download

`TorrentSession` is an actor:

- `init(torrent:settings:)`, then `start(initiallyPaused:)`. Start first checks what's on disk (`.checking`), using
  the saved resume state, then connects to the swarm. Started paused, it connects only on `resume()`.
- `pause()` drops queued requests and closes the peers; `resume()` reconnects. `cancel()` saves the progress and
  stops for good.
- `reannounce()`: asks the trackers again now.
- `currentState()` (`TorrentState`: `.stopped`, `.checking`, `.downloading`, `.paused`, `.completed`,
  `.failed(String)`), `dataRootURL()` (the file or folder the download owns on disk).
- `events`: an `AsyncStream<TorrentEvent>`: `.state`, `.stats(TorrentStats)`, `.pieceVerified(Int)`,
  `.peer(PeerEvent)` (`.connected`, `.disconnected`, `.dropped`, with the peer's id) and `.error(String)` for a
  problem it recovers from.
- `TorrentStats`: `verifiedBytes`, `totalBytes`, `progress`, `downloadSpeed` (bytes per second), `peersConnected`,
  `peersSeen`, `seedersConnected`, `trackerSeeders` and `trackerLeechers` (from the last announce, when the tracker
  says), and per file `fileVerifiedBytes` and `fileSequentialBytes` (the playable part from the file's start).

### Choosing files

These apply to a running download at once and are kept in the resume state:

- `setFilePriorities(_:)`: file index → priority 1…4. Priority 1 files come first, then 2, 3, 4, then the rest.
- `setFilePaused(_:fileIndex:)`: nothing more is fetched for a paused file.
- `setFileRemoved(_:fileIndex:)`: removing deletes the file's data and leaves it out of the download; restoring
  downloads it again from scratch.

### Resume state

`ResumeState` is the verified pieces and the per-file choices, saved as JSON at
`~/Library/Application Support/Get/<info hash in hex>.state` (`ResumeState.fileURL(infoHash:)`). A session loads it
by itself; when it starts unpaused, the pieces the state claims are hashed again before they're trusted.

### Lower level

The parts the session is built from are public too: `HTTPTracker.announce(url:params:timeout:)` and
`UDPTracker.announce`, `DHTNode` (`bootstrap`, `getPeers(infoHash:)`, `announcePeer`), `PEX`, `PeerConnection`,
`Handshake`, `WireCodec` and `WireMessage`, `MSEHandshake`, `PiecePicker`, `FileLayout` and `DiskWriter`.

## Testing

```bash
swift test --filter TorrentTests
# without the suites that open sockets:
swift test --filter TorrentTests --skip HTTPTrackerTests --skip UDPTrackerTests \
  --skip SessionIntegrationTests --skip PeerConnectionTests
```

## Related

- [GetKit](GetKit.md): progress and time left for the app's rows.
- [URLDownload](URLDownload.md): Get's http and https downloads.
