# URLDownload

Get's http and https downloads: several connections at once, resume after a pause or a relaunch, and checksums.
Part of [Get](README.md).

<!-- platforms: macos linux windows -->

## Purpose

`URLDownloadSession` downloads one link into a folder. When the server takes range requests, it splits the file into
up to four segments fetched in parallel, and a connection that finishes early takes half of the largest segment
left. Progress is saved per segment in a `URLDownloadRecord`, so a paused, failed or relaunched download continues
with `Range` and `If-Range` requests; if the file changed on the server meanwhile, it starts over rather than mix
two versions. A finished file is checked against a checksum when one is known: the one the user gave, else a digest
the server sent.

`RemoteDownload` is the same job on another device: the shell command that fetches a link there with curl or wget,
and the parser of its output. How the command reaches the device (SSH, for Get) is up to the app.

It is not a general networking library: one plain GET per file, no uploads, no FTP, no torrents (see
[Torrent](Torrent.md)).

## Getting started

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/v57/Get.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "URLDownload", package: "Get")]),
]
```

```swift
import Foundation
import URLDownload

let url = URL(string: "https://example.com/file.iso")!
let record = URLDownloadRecord(url: url, checksum: Checksum("<sha-256 hex>"))
let session = URLDownloadSession(
  record: record, saveDirectory: downloads, recordURL: downloads.appendingPathComponent("file.iso.download"))

Task {
  for await event in session.events {
    switch event {
    case .stats(let stats): print("\(Int(stats.progress * 100))% over \(stats.connections) connections")
    case .verified(let checksum): print("matches \(checksum.algorithm.rawValue)")
    case .state(.completed): print("done")
    case .state(.failed(let reason)): print("failed: \(reason)")
    default: break
    }
  }
}
await session.start()
```

To continue later, load the record from `recordURL` (`URLDownloadRecord.load(from:)`) and pass it to a new session.

## Main API

### URLDownloadSession

An actor.

- `init(record:saveDirectory:recordURL:maxConnections:minSegmentSize:configuration:retryDelay:maxRetries:)`:
  `maxConnections` defaults to 4, `minSegmentSize` to 1 MiB, `retryDelay` to 1 second and `maxRetries` to 10. A
  `recordURL` of nil saves no progress. `configuration` is the `URLSessionConfiguration` (caching is turned off on
  it).
- `start(initiallyPaused:)`, `pause()`, `resume()`, `cancel()` (stops for good, keeping the partial file and the
  record).
- `fileURL`: where the file is written, once the first response named it: the name from `Content-Disposition`,
  else the link's, made unique in the folder (`name (1).ext`, `name (2).ext`…).
- `currentRecord()`: the record as it stands.
- `events`: an `AsyncStream<URLDownloadEvent>`: `.state(URLDownloadState)`, `.stats(URLDownloadStats)`,
  `.file(URL)`, `.verified(Checksum)`, and `.error(String)` for a problem it retries on its own (with a delay that
  doubles each time).
- `URLDownloadState`: `.stopped`, `.downloading`, `.paused`, `.verifying` (checking the finished file),
  `.completed`, `.failed(String)`.
- `URLDownloadStats`: `receivedBytes`, `totalBytes` (when the server said), `progress`, `downloadSpeed` (bytes per
  second over the last 5 seconds), `connections`, `resumable` (the server takes ranges), `checksum`.

### URLDownloadRecord

`Codable`: the link, the checksum, the file name, the size, the server's validator (ETag or Last-Modified), whether
it takes ranges, the server's checksum and the segments. `init(url:checksum:)`, `receivedBytes`,
`load(from:)`, `save(to:)`.

### Checksum

- `Checksum(_:)` reads what a user pastes: a hex digest alone, `sha256sum` output (`<hex>  file.iso`) or BSD style
  (`SHA256 (file.iso) = <hex>`). The algorithm follows from the length: MD5, SHA-1, SHA-256 or SHA-512. Nil when
  there's no digest.
- `Checksum(digestHeader:)`: the strongest digest in a `Repr-Digest` or `Digest` header.
- `Checksum(algorithm:hex:)`, `digest(ofFileAt:)`.

### RemoteDownload

- `RemoteDownload(url:fileName:checksum:)`: `fileName` defaults to the link's last path component (or its host),
  reduced to one plain file name.
- `command`: a POSIX `sh` command for the device's login shell. It downloads into `~/Downloads` as
  `<name>.get-part` with curl (else wget), continues a partial file left by an earlier attempt, renames the file when
  complete (`<name> (2)` when the name is taken), and prints the checksum when one was given.
- `RemoteDownload.Parser`: `consume(_:)` turns the command's output into `Event`s: `.progress(Double)`,
  `.saved(path:)`, `.checksum(String)` (the digest computed on the device) and `.failed(String)`.

## Testing

```bash
swift test --filter URLDownloadTests
```

## Related

- [GetKit](GetKit.md): progress and time left for the app's rows.
- [Torrent](Torrent.md): Get's torrent engine.
