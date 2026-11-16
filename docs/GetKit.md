# GetKit

What a download looks like while it runs: its progress, its time left and its speed. Part of [Get](README.md).

<!-- platforms: macos linux windows -->

## Purpose

`GetKit` holds the two pieces Get's [Torrent](Torrent.md) and [URLDownload](URLDownload.md) libraries share with
the app. `DownloadProgress` turns a download's bytes into a progress bar and a time left that learn from earlier
downloads of the same kind (the same server and file type, or the same tracker), through Code's
[CodeProgress](../../Code/docs/CodeProgress.md). `SpeedMeter` averages the speed over a few seconds, so a torrent
that counts a whole piece at once doesn't jump between zero and full speed.

It doesn't download anything itself.

## Getting started

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/v57/Get.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "GetKit", package: "Get")]),
]
```

`GetKit` depends on Code's `CodeProgress` from GitHub's `main`; with `V57_LOCAL=1` it builds against a `../Code`
checkout instead.

```swift
import GetKit

let progress = DownloadProgress(
  transferID: DownloadProgress.transferID(url: url),          // "download example.com iso"
  checkID: DownloadProgress.checkID(algorithm: "SHA-256"))    // the check after the transfer

// As bytes arrive:
progress.transfer(received: received, of: total)
// When the transfer is over and the file is checked:
progress.checking(DownloadProgress.checkID(algorithm: "SHA-256"), bytes: total)
progress.finish()

// On a timer while progress.isRunning:
let reading = progress.reading()   // reading.fraction 0...1, reading.remaining in seconds (nil while unknown)
```

## Main API

### DownloadProgress

A class; one per download. Each stretch of moving work is a run: pausing or failing ends it, resuming starts a new
one for the bytes still to fetch, and the bar continues from where it stopped.

- `init(transferID:checkID:history:now:)`: `history` defaults to `ProgressHistory.standard`, kept in
  `ProgressHistory.json` in the app's Application Support folder.
- Stage ids: `transferID(url:)` (the server and the file type, such as `download deb.debian.org iso`),
  `torrentTransferID(announce:)` (the tracker's host, `dht` without one) and `checkID(algorithm:)`.
- Reporting: `transfer(received:of:)` while bytes move, `idle(received:of:)` while paused (the bar shows the bytes
  on disk), `checking(_:bytes:)` for the check after the transfer, `planCheck(_:)` when a check is learned after
  the start (a server's digest), `stop()` when paused or failed, `finish()` when done.
- `reading()` → `Reading` (`fraction`, `remaining`); `isRunning`.

A transfer whose size is unknown isn't timed, so it doesn't teach the history a wrong size.

### SpeedMeter

- `SpeedMeter(window:)`: the averaging window in seconds (default 5).
- `record(totalBytes:at:)`: feed the running byte total, get bytes per second over the window. The first sample, or
  a total that went down, returns 0.
- `reset()`: forget every sample (after a pause or a restart).

## Testing

```bash
swift test --filter GetKitTests
```

## Related

- [CodeProgress](../../Code/docs/CodeProgress.md): the estimates and the history behind `DownloadProgress`.
- [Torrent](Torrent.md) and [URLDownload](URLDownload.md) report their speed with `SpeedMeter`.
