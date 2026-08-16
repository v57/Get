# Get — Torrent Engine KANBAN

Status: [ ] todo   [~] in progress   [x] done
Plan: .hermes/plans/2026-08-16_174727-torrent-download-engine.md

## Phase 0 — Scaffolding
- [x] T1  Add Torrent target + product (Package.swift)  — commit 8553430
- [x] T2  Link Torrent product into app target (Get.xcodeproj)  — done with "Package: Removed Get target" (app now links Torrent only)
- [x] T3  Gitignore example.torrent (private passkey)  — commit 8553430
- [x] Get stub package target removed (Package.swift + Sources/Get + Tests/GetTests)

## Phase 1 — Metadata
- [x] T4  Bencode value + parser + encoder  — commit ddcbdef (9 tests)
- [x] T5  TorrentFile metadata model (+ SyntheticTorrent test helper)  — commit 217721f (8 tests, example.torrent infohash verified)
- [x] T6  Magnet URI parsing  — commit da49480 (11 tests)

## Phase 2 — Crypto
- [x] T7  RC4 stream cipher (RFC 6229)  — commit a33ee5f (8 tests)
- [x] T8  768-bit modpow for MSE DH (BigInt)  — commit 2ca71b8 (10 tests, +32 python cross-checks)
- [x] T9  MSE key derivation + sync point  — commit b38d18f, CORRECTED 99ac36b (VC=8 zeros, SHA1("keyA/B"‖S‖SKEY); full suite 54+1 green)
- [x] T10 MSE initiator handshake (+ FakeMSEPeer responder)  — commit 0b1456e (14 tests; fixed consume bug + test deadlocks + cancellation-cooperative pipe)

## Phase 3 — Wire protocol
- [x] T11 Wire message codec + handshake  — commit c7bcb4c (10 tests)
- [x] T12 PeerConnection actor (MSE + RC4 + NWConnection)  — commit 28d738f (4 tests; real-TCP MSE + wire exchange)

## Phase 4 — Trackers
- [x] T13 HTTP(S) tracker announce (+ FakeTracker)  — commit 0999b9b (13 tests; FakeTracker on POSIX sockets — NWListener broken on this macOS 27/Xcode 27 beta, EINVAL on every bind; PeerList V6 edge-compression fixed)
- [x] T14 UDP tracker announce (+ FakeUDPTracker)  — commit 321b9d3 (5 tests, POSIX UDP fake)

## Phase 5 — Engine
- [x] T15 Sequential piece picker  — commit bf65d57 (9 behaviors via harness)
- [x] T16 FileLayout + DiskWriter  — commit c8bb69d (9 + 8 tests)
- [x] T17 TorrentSession engine (hermetic E2E: FakeSeeder)  — commits 021e59e + d7c0a58 (4 E2E tests; full sequential download byte-identical, no-upload, plaintext-drop, placement, cancel). NOTE: canonical suite runs SERIAL: `swift test --no-parallel` (parallel socket tests flake on this macOS 27 beta)
- [x] T18 Resume state (stretch)  — commit f9eaaf7 (+29f9618: seed before disk prepare). 5 ResumeTests: roundtrip, hex-named file URL, missing/corrupt → nil, session-level resume skips verified prefix

## Phase 6 — App UI
- [x] T19 DownloadStore + TorrentView (ContentView rewrite)  — commit bbfa914. @Observable DownloadStore, NavigationStack list with progress, fileImporter; xcodebuild BUILD SUCCEEDED

## Done — 21 commits, full suite 127/127 (`swift test --no-parallel`), app builds
