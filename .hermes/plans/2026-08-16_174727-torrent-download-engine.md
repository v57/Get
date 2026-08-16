# Get: Torrent Download Engine — Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Add torrent downloading to the Get macOS app: parse `.torrent` files, discover peers via trackers, download with **sequential piece order**, **MSE-encrypted peers only**, **zero upload**, saving files into `~/Downloads`.

**Architecture:** All torrent logic lives in a new `Torrent` target of the existing local Swift package (pure Swift, no C/C++ deps, Network.framework for all sockets). The Xcode app target keeps the UI and talks to the package through a small public API (`TorrentSession`, events as `AsyncStream`). Engine choice: **custom pure-Swift implementation** (recommended) — rationale in "Decision" below.

**Tech Stack:** Swift 6.4 / swift-tools 6.4, Swift Testing (`@Test`/`#expect`), Network.framework (`NWConnection`/`NWListener`, TCP+UDP+TLS), CryptoKit (`Insecure.SHA1`), Xcode 27 / macOS 27 target, SwiftUI (`@Observable`).

---

## Decision: libtorrent vs. own implementation

**Recommendation: own pure-Swift implementation in `Sources/Torrent`.**

Why not libtorrent-rasterbar (the C++ lib used by qBittorrent/Deluge):
- It is GPL-2.0 licensed — a distribution constraint for the app.
- Linking it into this SwiftPM package requires Homebrew install + `cxxSettings`/`linkerSettings` unsafe flags + Swift C++ interop — machine-dependent (Intel vs Apple Silicon paths) and fragile across Xcode versions.
- Its alert/callback threading model fights Swift 6 strict concurrency (alerts arrive on a background thread; everything needs Sendable marshalling).
- The requested feature set is a narrow, leecher-only profile: sequential download, MSE-only, no upload. That maps onto a lean native client (~2,500 lines) with no dependencies and no license baggage, consistent with the project's clean SwiftPM layout.

What we must implement ourselves: bencode, torrent metadata, HTTP+UDP trackers, peer wire protocol, sequential piece picker, disk writer, MSE (RC4 + 768-bit DH) — each is small and unit-testable. The only genuinely tricky part is MSE's DH, which needs a custom modular-exponentiation over the fixed 768-bit prime (Swift has no bignum); it is ~150 lines and cross-validated against Python `pow()` in tests.

Fallback: if MSE interop turns out to be a blocker during Phase 2, switch to libtorrent-rasterbar via Homebrew (see appendix at the end). Everything before Phase 2 (bencode, metadata, wire codec) is reused either way.

---

## Current context & assumptions

- Repo: `/Users/v57/Projects/Get`. Xcode 27.0, Swift 6.4, deployment target macOS 27.0. App scheme name: `Get`.
- The app target `Get` (module name also `Get`) uses `PBXFileSystemSynchronizedRootGroup` for the `Get/` folder — new UI files dropped into `Get/` are automatically part of the target. It links the local package product `Get` (stub `hello()`), sandbox disabled (`ENABLE_APP_SANDBOX = NO`), so writing to `~/Downloads` works with no entitlements.
- `Package.swift`: swift-tools 6.4, package name `Get`, library product `Get` → target `Get` (`Sources/Get/Get.swift` stub), test target `GetTests`, `ApproachableConcurrency` upcoming feature.
- **Module-name collision:** the app's own module is `Get` and the package product is also `Get`. The app cannot `import Get` (self-import). Therefore the app links and imports the new **`Torrent`** product only. The stub `Get` product stays linked but unused (harmless).
- `example.torrent` (untracked) is a RuTracker multi-file torrent — Silo S01, 20 files, 8,877,892,204 bytes total, piece length 4 MiB, 2117 pieces, infohash `9fbb17d030f7f5c51310fa49319eb28a30eb3329`. **Its announce URL contains a private-tracker passkey (`pk=56cbbad8…`) — never commit this file.** Add it to `.gitignore`. All automated tests use synthetic torrents generated in-test.
- Network access is available; Homebrew works. `transmission-cli` (4.1.3) is in Homebrew (optional live test). `opentracker` is NOT in Homebrew → the test tracker is a tiny in-process HTTP tracker in the test target.

## Target layout

Package (`/Users/v57/Projects/Get/Package.swift`):

```
Sources/Torrent/
  Bencode.swift              — BencodeValue + parser (raw info-dict byte-range capture) + encoder
  TorrentFile.swift          — decoded .torrent: announce(s), info, infohash, piece hashes, files, layout
  Magnet.swift               — magnet URI parse (xt=urn:btih:, tr=)
  Crypto/BigInt.swift        — 768-bit modpow (limb-based, Montgomery) for MSE DH
  Crypto/RC4.swift           — RC4 + keystream drop
  Crypto/MSE.swift           — Message Stream Encryption: initiator handshake, key derivation, sync
  Tracker/HTTPTracker.swift  — HTTP(S) announce over NWConnection (no ATS issues)
  Tracker/UDPTracker.swift   — UDP tracker connect/announce
  Tracker/PeerList.swift     — compact peers decode (IPv4 6B, IPv6 18B)
  Wire/Handshake.swift       — 68-byte BT handshake encode/decode
  Wire/Messages.swift        — wire message codec (length-prefixed, all 9 ids + keepalive)
  Wire/PeerConnection.swift  — actor wrapping NWConnection: connect, framed read/write, MSE + RC4
  Engine/PiecePicker.swift   — sequential picker, per-peer pipeline, availability
  Engine/FileLayout.swift    — piece byte-range → (file, offset) spans; path sanitization
  Engine/DiskWriter.swift    — preallocation + verified piece writes
  Engine/TorrentSession.swift— public API actor: lifecycle, tracker loop, peer manager, events
Tests/TorrentTests/
  BencodeTests.swift, TorrentFileTests.swift, MagnetTests.swift,
  RC4Tests.swift, BigIntTests.swift, MSETests.swift,
  WireTests.swift, PeerConnectionTests.swift,
  HTTPTrackerTests.swift, UDPTrackerTests.swift,
  PiecePickerTests.swift, FileLayoutTests.swift, DiskWriterTests.swift,
  SessionIntegrationTests.swift,
  Support/FakeTracker.swift, Support/FakeSeeder.swift, Support/SyntheticTorrent.swift
```

App target (kept in the Xcode project, `Get/` folder):
- `Get/DownloadStore.swift` — `@Observable @MainActor` store bridging `TorrentSession` events to UI state
- `Get/TorrentView.swift` — download list + progress + "Add torrent…" file picker
- `Get/ContentView.swift` — replace hello-world with `TorrentView`

Modified: `Package.swift`, `Get.xcodeproj/project.pbxproj` (link `Torrent` product), `.gitignore` (example.torrent).

---

## Architecture

### Feature → design mapping

| Requirement | Design |
|---|---|
| Sequential download | `SequentialPicker` assigns pieces in strictly ascending order; per-peer pipeline window of 4 blocks × 16 KiB; never skips ahead |
| Encrypted peers only | Every peer connection starts with the MSE handshake (`crypto_provide = 0x02` RC4-only). Any plaintext response → connection dropped. (Note: MSE is RC4 **obfuscation**, the BT-standard "encryption"; it defeats DPI, not an authenticated cipher.) |
| No uploads | The client never emits `piece`, `have`, or non-empty `bitfield` messages; all-zero `bitfield` sent only in reply to a peer's bitfield (politeness); outbound-only connections |
| Save to ~/Downloads | `Settings.saveDirectory` defaults to `~/Downloads`; single-file torrent → `Downloads/<name>`; multi-file → `Downloads/<name>/<path…>`; path components sanitized against traversal |

### Concurrency model (Swift 6 strict)

- `TorrentSession` is the public actor (one per download). It owns the tracker loop, peer manager, picker, and disk writer.
- `PeerConnection` is a small actor wrapping `NWConnection`; all callbacks hop onto the actor (continuation-based `send`/`receive`), so no data races.
- Every message crossing the session boundary is `Sendable`; UI observes via `AsyncStream<TorrentEvent>`.
- All sockets via Network.framework: TCP for peers, TCP(+TLS) for HTTP trackers, UDP for UDP trackers. No URLSession → no App Transport Security issues, works identically in tests and app.

### Public API (`TorrentSession.swift`)

```swift
public struct TorrentSettings: Sendable, Equatable {
    public var saveDirectory: URL            // default: ~/Downloads
    public var sequential: Bool              // default true
    public var encryptedPeersOnly: Bool      // default true (MSE-only)
    public var allowUpload: Bool             // default false
    public var maxPeers: Int                 // default 30
    public var pipelinePerPeer: Int          // default 4
    public var blockSize: Int                // default 16 * 1024
    public init() // sets defaults
}

public enum TorrentState: Sendable, Equatable {
    case stopped, checking, downloading, paused, completed, failed(String)
}

public struct TorrentStats: Sendable, Equatable {
    public var verifiedBytes: Int64, totalBytes: Int64
    public var peersConnected: Int, peersSeen: Int
    public var downloadSpeed: Double         // bytes/sec EWMA
    public var progress: Double              // verifiedBytes / totalBytes
}

public enum TorrentEvent: Sendable {
    case state(TorrentState)
    case stats(TorrentStats)                 // emitted ~1/s
    case pieceVerified(Int)
    case peer(PeerEvent)                     // connected/disconnected/dropped(reason)
    case error(String)
}
public enum PeerEvent: Sendable { case connected(String), disconnected(String), dropped(String) }

public actor TorrentSession {
    public init(torrent: TorrentFile, settings: TorrentSettings)
    public static func parse(url: URL) throws -> TorrentFile   // reads + parses .torrent
    public var events: AsyncStream<TorrentEvent>               // set up before start()
    public func start() async throws
    public func pause() async
    public func resume() async
    public func cancel() async                                 // announces `stopped`, closes peers
    public func currentState() -> TorrentState
}
```

The app's `DownloadStore` keeps `[TorrentSession]` directly (no separate client object in v1).

---

## Tasks

### Phase 0 — Scaffolding

**Task 1: Add Torrent target and product to Package.swift**

**Files:** Modify: `Package.swift`

**Step 1:** Add the `Torrent` library product and target, plus `TorrentTests`; keep existing `Get`/`GetTests` untouched:

```swift
let package = Package(
    name: "Get",
    products: [
        .library(name: "Get", targets: ["Get"]),
        .library(name: "Torrent", targets: ["Torrent"]),
    ],
    targets: [
        .target(name: "Get", swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
        .target(name: "Torrent", swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
        .testTarget(name: "GetTests", dependencies: ["Get"], swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
        .testTarget(name: "TorrentTests", dependencies: ["Torrent"], swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")]),
    ]
)
```

**Step 2:** Create `Sources/Torrent/Placeholder.swift` with `public enum Torrent {}` so the target compiles.

**Step 3:** Verify — run: `swift build` → expected: BUILD SUCCESSFUL. Run: `swift test` → expected: 1 test (stub) passes.

**Step 4: Commit** — `git add Package.swift Sources/Torrent/Placeholder.swift && git commit -m "Added Torrent package target"`

**Task 2: Link the Torrent product into the app target**

**Files:** Modify: `Get.xcodeproj/project.pbxproj`

Do this in Xcode UI (safest): open `Get.xcodeproj` → app target `Get` → General → "Frameworks, Libraries, and Embedded Content" → `+` → under "Get" local package pick product **Torrent**. Then verify: `xcodebuild -project Get.xcodeproj -scheme Get build` succeeds.

Headless alternative (exact pbxproj edits, mirroring the existing `Get` product entries):
- `PBXBuildFile` section: add `263FBE523031C505008DB220 /* Torrent in Frameworks */ = {isa = PBXBuildFile; productRef = 263FBE513031C505008DB220 /* Torrent */; };`
- `PBXFrameworksBuildPhase` files: add `263FBE523031C505008DB220 /* Torrent in Frameworks */,`
- `XCSwiftPackageProductDependency` section: add `263FBE513031C505008DB220 /* Torrent */ = {isa = XCSwiftPackageProductDependency; productName = Torrent; };`
- `packageProductDependencies` of the app target: add `263FBE513031C505008DB220 /* Torrent */,`

Verify: `xcodebuild -project Get.xcodeproj -scheme Get build` succeeds.

**Step: Commit** — `git add Get.xcodeproj && git commit -m "GetApp: Linked Torrent product"`

**Task 3: Gitignore the passkey-bearing example torrent**

**Files:** Modify: `.gitignore` — append a line `example.torrent` plus comment `# private-tracker passkey in announce URL — use synthetic torrents in tests`.

**Step: Commit** — `git add .gitignore && git commit -m "Added example.torrent to gitignore"`

---

### Phase 1 — Metadata: bencode, torrent file, magnet

**Task 4: Bencode value type + parser (TDD)**

**Files:** Create: `Sources/Torrent/Bencode.swift`, `Tests/TorrentTests/BencodeTests.swift`

**Step 1 (failing test):** `BencodeTests.swift`:
- `testParseInteger`: `i42e` → `.int(42)`; `i-7e` → -7
- `testParseString`: `4:spam` → `.string("spam")`
- `testParseList`: `l4:spami42ee` → `[.string("spam"), .int(42)]`
- `testParseDict`: `d3:foo3:bare` → `[Data("foo"): .string("bar")]`
- `testRoundTrip` (encode(parse(x)) == x) for a nested structure
- `testMalformed`: `i42`, `4:`, `d3:foo` → throws `BencodeError`
- `testInfoDictByteRange`: `parseWithPositions` of a dict containing `info` returns the raw byte range of the info **value** (needed for infohash)

**Step 2:** Run: `swift test --filter BencodeTests` → expected FAIL.

**Step 3 (implement):** `Bencode.swift`:

```swift
public enum BencodeValue: Equatable, Sendable {
    case int(Int64)
    case string(Data)
    case list([BencodeValue])
    case dict([Data: BencodeValue])
}
public enum BencodeError: Error, Equatable { case malformed(String) }

public struct Bencode: Sendable {
    /// Parse whole document.
    public static func parse(_ data: Data) throws -> BencodeValue
    /// Parse and also return the raw byte range of the top-level dict value for `key`
    /// (used to capture the exact `info` bytes for the SHA-1 infohash).
    public static func parseWithRawValue(_ data: Data, key: Data) throws -> (value: BencodeValue, rawRange: Range<Int>)
    public static func encode(_ value: BencodeValue) -> Data
}
```

Parser is recursive descent over `Data` with an index: `i…e` ints (reject leading zeros, `-0`), `n:…` strings (n digits, `:`), `l…e` lists, `d…e` dicts (keys must be strings, sorted order not enforced on parse). `parseWithRawValue` scans top-level keys and, for the target key, records the value's start index and computes its end by skipping the value (tracking `d`/`l`/`e` depth for containers, length prefix for strings). `encode` writes canonically sorted keys.

**Step 4:** Run: `swift test --filter BencodeTests` → expected PASS.

**Step 5: Commit** — `git add Sources/Torrent/Bencode.swift Tests/TorrentTests/BencodeTests.swift && git commit -m "Added bencode support"`

**Task 5: TorrentFile metadata model (TDD)**

**Files:** Create: `Sources/Torrent/TorrentFile.swift`, `Tests/TorrentTests/TorrentFileTests.swift`, `Tests/TorrentTests/Support/SyntheticTorrent.swift`

**Step 1 (test support first):** `SyntheticTorrent.swift` — helper that builds a valid `.torrent` in-memory:

```swift
enum SyntheticTorrent {
    /// Builds a torrent for `data` split into `pieceLength`-byte pieces.
    /// Returns (torrentData, torrentFile, contentData).
    static func make(data: Data, pieceLength: Int = 16 * 1024,
                     name: String = "synthetic.bin",
                     files: [(path: [String], data: Data)]? = nil,
                     announce: String = "http://127.0.0.1:6969/announce") throws
        -> (data: Data, torrent: TorrentFile, content: Data)
}
```
Uses `Bencode.encode` + `Insecure.SHA1` per piece. (Multi-file variant for file-layout tests.)

**Step 2 (failing tests):** `TorrentFileTests.swift`:
- `testParseSingleFile`: parse synthetic single-file torrent → announce, name, pieceLength, pieceHashes.count == pieces, totalSize, infohash matches SHA1 of raw info bytes
- `testParseMultiFile`: 2 files (one straddling a piece boundary) → files count, per-file path+length, totalSize
- `testInfoHashMatchesKnownVector`: `example.torrent` is NOT committed, so instead hardcode a small fixture: parse a hand-built bencode string and assert infohash equals a value precomputed with `python3 -c "import hashlib; print(hashlib.sha1(raw).hexdigest())"` (run once during implementation, paste as literal)
- `testUTF8NameFallback`: name with invalid UTF-8 bytes → decoded with `.replacement` fallback, never throws
- `testPieceHashesCount`: piece hashes count == ceil(totalSize / pieceLength)

**Step 3 (implement):** `TorrentFile.swift`:

```swift
public struct TorrentFile: Sendable, Equatable {
    public let announce: String?
    public let announceList: [[String]]
    public let infoHash: Data                    // 20 bytes, SHA1 of raw info dict bytes
    public let name: String
    public let pieceLength: Int
    public let pieceHashes: [Data]               // 20 bytes each
    public let files: [FileEntry]
    public let totalSize: Int64

    public struct FileEntry: Sendable, Equatable {
        public let path: [String]                // path components under name/
        public let length: Int64
    }

    public static func parse(_ data: Data) throws -> TorrentFile
    public static func parse(url: URL) throws -> TorrentFile
}
```
Notes: `infoHash` from `Bencode.parseWithRawValue(raw, key: Data("info".utf8))` → SHA1 of `raw[range]` — **never re-encode**. `name` decodes UTF-8 with `.replacement` fallback. `announceList` tiers flattened by the tracker loop later.

**Step 4:** Run: `swift test --filter TorrentFileTests` → PASS. Also sanity-check against the real file (not committed): `swift test` with a one-off `#if DEBUG` snippet reading `/Users/v57/Projects/Get/example.torrent` and printing infohash — must equal `9fbb17d030f7f5c51310fa49319eb28a30eb3329`.

**Step 5: Commit** — `git add Sources/Torrent/TorrentFile.swift Tests/TorrentTests/ && git commit -m "Added torrent metadata parsing"`

**Task 6: Magnet URI parsing (TDD)**

**Files:** Create: `Sources/Torrent/Magnet.swift`, `Tests/TorrentTests/MagnetTests.swift`

**Step 1 (failing tests):** `MagnetTests.swift`:
- `testParse`: `magnet:?xt=urn:btih:<hex>&tr=http%3A%2F%2Fx%2Fannounce&dn=name` → infohash bytes == hex-decoded, trackers == [decoded url], displayName == "name"
- `testBase32Xt`: `xt=urn:btih:<RFC4648-base32 32 chars>` (standard for magnets)
- `testNoTrackers`, `testMalformed` (no xt → throws)

**Step 2:** Run filter → FAIL. **Step 3 (implement):** parse query params; `xt=urn:btih:` prefix → hex or base32 → 20 bytes; collect all `tr=` (percent-decoded); `dn=` display name. **Step 4:** PASS. **Step 5: Commit** — `git commit -m "Added magnet link parsing"`.

### Phase 2 — Crypto: RC4, bigint, MSE

> **SPEC CORRECTION (verified 2026-08-16 against libtorrent-rasterbar `src/bt_peer_connection.cpp` and Transmission `libtransmission/handshake.cc` — the two interop camps):** the original draft of Tasks 9–10 described the wrong MSE wire format. The verified format (this client is always the INITIATOR):
> - Initial exchange is `[Ya 96-byte pubkey][PadA 0-512]` (key first, no VC/crypto_provide in the clear). Responder replies `[Yb 96][PadB 0-512]`.
> - Keys: initiator send = `SHA1("keyA" || S || SKEY)`, recv = `SHA1("keyB" || S || SKEY)` where S = DH secret (96 bytes), SKEY = infohash (20 bytes). Both RC4 streams drop 1024 bytes.
> - After DH: send in the CLEAR `[SHA1("req1"||S) 20][SHA1("req2"||SKEY) xor SHA1("req3"||S) 20]`.
> - Then ENCRYPTED: `[VC 8 zero bytes][crypto_provide 4][len(PadC) 2][PadC][len(IA) 2][68-byte handshake]`. Peer replies ENCRYPTED: `[VC 8][crypto_select 4][len(PadD) 2][PadD][68-byte handshake]` (no length prefix before the handshake). Continue the same RC4 streams for all wire messages.
> - VC = 8 zero bytes (`libtorrent sh_vc[] = {0,0,0,0,0,0,0,0}`; Transmission: "a String of 8 bytes set to 0x00"). crypto_provide/select: 0x01 plaintext, 0x02 RC4.
> - Plaintext-detect: if the peer answers our pubkey with a plaintext BT handshake (`0x13 "BitTorrent protocol"…`), drop the connection (encrypted-only).
> Implemented in commit 99ac36b (`MSE.swift`: `vc`, `cryptoProvideRC4`, `deriveKeys(secret:streamKey:) -> (send:recv:)`, `syncHash(secret:)`, `obfuscatedInfoHash(streamKey:secret:)`). Use THAT API; the code blocks below are superseded.

**Task 7: RC4 stream cipher (TDD)**

**Files:** Create: `Sources/Torrent/Crypto/RC4.swift`, `Tests/TorrentTests/RC4Tests.swift`

**Step 1 (failing tests):** `RC4Tests.swift`:
- RFC 6229 vectors: key `0102030405` → keystream offset 0 `b2396305f03dc027abce4f6b04e98c76`; key `0102030405060708` → offset 0 `293f02d47d1c8bf5a0b8c8a1b0a7b8b7` etc. (paste 3–4 full 6229 vectors)
- `testDrop`: after `drop(1024)` the next 16 bytes equal the RFC 6229 keystream at offset 1024 for the same key
- `testXOR`: `stream` mutates input in place (xor)

**Step 2:** `swift test --filter RC4Tests` → FAIL. **Step 3 (implement):** `RC4.swift`:

```swift
public struct RC4: Sendable {
    private var s: [UInt8] = Array(0...255)
    private var i: UInt8 = 0, j: UInt8 = 0
    public init(key: [UInt8]) {
        var j: UInt8 = 0
        for i in 0..<256 {
            j &+= s[i] &+ key[Int(i) % key.count]
            s.swapAt(i, Int(j))
        }
    }
    /// XOR `data` in place with the keystream.
    public mutating func stream(_ data: inout [UInt8]) {
        for k in data.indices {
            i &+= 1; j &+= s[Int(i)]
            s.swapAt(Int(i), Int(j))
            data[k] ^= s[Int(s[Int(i)] &+ s[Int(j)])]
        }
    }
    /// Discard `count` keystream bytes (MSE requires 1024).
    public mutating func drop(_ count: Int) {
        var junk = [UInt8](repeating: 0, count: count)
        stream(&junk)
    }
}
```

**Step 4:** PASS. **Step 5: Commit** — `git commit -m "Added RC4 support"`

**Task 8: 768-bit modular exponentiation (TDD)**

**Files:** Create: `Sources/Torrent/Crypto/BigInt.swift`, `Tests/TorrentTests/BigIntTests.swift`

Swift has no bignum; MSE's DH needs `g^a mod p` over the fixed 768-bit prime. Implement limb-based arithmetic (12 × `UInt64`, little-endian).

**Step 1 (failing tests):** `BigIntTests.swift`:
- `testModPowKnownVectors`: hardcode ≥5 vectors generated once via `python3 -c "print(pow(base, exp, p))"` for the MSE prime (random 96-byte base/exp), asserted as hex strings. Include `pow(g, 1, p) == g`, `pow(1, huge, p) == 1`, and a `base == 0` case.
- `testMSEPrimeConstant`: `MSEPrime.bytes` equals the spec prime (hex literal below).

**Step 2:** Run filter → FAIL. **Step 3 (implement):** `BigInt.swift`:

```swift
public enum MSEPrime {
    /// 768-bit prime from the MSE spec (bittorrent.org / Vuze wiki).
    public static let bytes: [UInt8] = hex("FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD1"
        + "29024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A4"
        + "31B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A6"
        + "3A3620FFFFFFFFFFFFFFFF")
}

/// Returns base^exponent mod modulus. All inputs/outputs are 96-byte big-endian
/// byte arrays (as they appear on the wire).
public func modPow(_ base: [UInt8], _ exponent: [UInt8], _ modulus: [UInt8]) -> [UInt8]
```

Algorithm: convert to 12-limb little-endian `[UInt64]`, binary square-and-multiply over the 768-bit exponent, Montgomery multiplication for `mulmod` (reference: Handbook of Applied Cryptography §14.3.2; modulus is odd, `R = 2^768`, precompute `R^2 mod p` once as a constant or at init). Constant-time not required (obfuscation layer only, no secrets beyond the DH private key; note: an active MITM defeats MSE anyway by design).

**Step 4:** PASS (all Python-generated vectors). **Step 5: Commit** — `git commit -m "Added 768-bit modular exponentiation"`

**Task 9: MSE key derivation + sync point (TDD)**

**Files:** Create: `Sources/Torrent/Crypto/MSE.swift` (key derivation part), `Tests/TorrentTests/MSETests.swift`

**Step 1 (failing tests):** `MSETests.swift` — hardcode vectors from a Python reference computed during implementation:
- `testKeyDerivation`: given fixed 96-byte `secret` → `X` and `Y` (20 bytes each) match Python: `hash = sha1(secret); X = sha1(bytes(a^b for a,b in zip(hash, (b"keyA"*5)))); Y = same with b"keyB"`
- `testSyncBytes`: `syncInitiator(keystream:)` and `syncResponder(keystream:)` produce keystream[0..<4] XOR SHA1("req3"/"req2")[0..<4]
- `testVCConstant`: 26-byte VC == `0x00 0x00 0x04 0x01` + eleven `0x00 0x00 0x01 0x00`

**Step 2:** FAIL. **Step 3 (implement):** in `MSE.swift`:

```swift
public enum MSE {
    public static let vc: [UInt8]   // 26 bytes as above
    public static let cryptoProvideRC4: UInt32 = 0x02

    /// Derive the two 20-byte RC4 keys from the DH shared secret.
    /// Initiator: send key = X, receive key = Y. Responder: mirrored.
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

    public static func syncPoint(_ req: String, keystreamFirst4: [UInt8]) -> [UInt8] {
        let h = Array(Insecure.SHA1.hash(data: Data(req.utf8)))
        return zip(keystreamFirst4, h).map(^)
    }
}
```

**Step 4:** PASS. **Step 5: Commit** — `git commit -m "Added MSE key derivation"`

**Task 10: MSE initiator handshake (TDD)**

**Files:** Modify: `Sources/Torrent/Crypto/MSE.swift`; Create: `Tests/TorrentTests/Support/FakeMSEPeer.swift`; extend `MSETests.swift`

**Step 1 (test support):** `FakeMSEPeer.swift` — an in-process **responder** used by tests: it receives the initiator's first message, verifies VC, generates its own 96-byte private key, replies `[96 pad][VC][crypto_select=0x02][2 len padD=0][pubD][2 len ib=0]`, derives keys mirrored (send=Y, recv=X), drops 1024, sends sync `SHA1("req2")`-based bytes, reads the initiator's sync (expects `SHA1("req3")`-based), then exchanges the obfuscated 68-byte handshake and returns the RC4-wrapped byte channel. (This doubles as an independent implementation to cross-check the client.)

**Step 2 (failing tests):** `MSETests.swift`:
- `testFullHandshakeAgainstFakePeer`: run initiator `MSEHandshake` against `FakeMSEPeer` over an in-memory pipe → both sides derive equal `(x, y)`, sync passes, both read each other's handshake with matching infohash
- `testPlaintextResponseDropped`: peer replies with a plaintext BT handshake (`0x13 "BitTorrent protocol"…`) → initiator throws `.peerDoesNotSupportEncryption`
- `testBadVC`: peer replies with wrong VC → throws `.handshakeFailed`
- `testCryptoSelectNotRC4`: peer selects `0x01` (plaintext only) → throws

**Step 3 (implement):** add to `MSE.swift`:

```swift
public struct MSEHandshake: Sendable {
    public enum MSEError: Error, Equatable {
        case peerDoesNotSupportEncryption, handshakeFailed, cryptoNotSelected, timedOut
    }
    /// Send the MSE initiator preamble and read the responder's reply.
    /// Returns the shared secret (96 bytes) and the responder's public key.
    public static func initiate(send: (Data) async throws -> Void,
                                receive: () async throws -> Data) async throws -> (secret: [UInt8], peerPublic: [UInt8])
}
```

Wire format (initiator sends, 226 bytes with empty pads): `[96 random pad][VC 26][crypto_provide 4 = 0x00000002][len padC 2 = 0][pubkey 96][len ia 2 = 0]`.
Responder reply: `[96 random pad][VC 26][crypto_select 4][len padD 2][padD][pubkey 96][len ib 2][ib]` — read at least 226 bytes first, then parse trailing padD/ib lengths (each ≤ 512). Steps in code:
1. Generate private key: 96 random bytes (big-endian int < p; retry if ≥ p or == 0).
2. `pubkey = modPow(2, privateKey, MSEPrime.bytes)`.
3. Send preamble. 4. Receive reply, verify VC, verify `crypto_select & 0x02 != 0`. 5. `secret = modPow(peerPub, privateKey, prime)`.

The rest of the flow lives in `PeerConnection` (Task 12): derive keys, build two `RC4` ciphers (initiator: enc=X/dec=Y), `drop(1024)` both, send sync (encrypt `X-stream[0..<4] ^ SHA1("req3")[0..<4]` — i.e. XOR the 4 raw keystream bytes with the hash), read 4 bytes, decrypt with dec cipher, verify == `SHA1("req2")[0..<4]` (this is the in-sync check: wire = keystream XOR hash, so decrypted == hash iff streams are aligned), then send obfuscated handshake `[2 len][68-byte handshake][2 len ia][ia]` encrypted, read responder's `[2 len][68][2 len ib][ib]` encrypted, verify pstr and infohash. **The same two RC4 ciphers then encrypt/decrypt every subsequent wire message.**

**Step 4:** PASS. **Step 5: Commit** — `git commit -m "Added MSE handshake support"`

---

### Phase 3 — Wire protocol and peer connections

**Task 11: Wire message codec + handshake (TDD)**

**Files:** Create: `Sources/Torrent/Wire/Handshake.swift`, `Sources/Torrent/Wire/Messages.swift`, `Tests/TorrentTests/WireTests.swift`

**Step 1 (failing tests):** `WireTests.swift`:
- `testHandshakeEncodeDecode`: roundtrip with fixed infohash/peerID; 68 bytes; pstr offset 0 == 19, bytes 1..20 == "BitTorrent protocol"; reserved == 0
- `testMessageRoundTrip` for every message type (choke/unchoke/interested/notInterested/have/bitfield/request/piece/cancel/keepAlive)
- `testKeepAliveIsZeroLength`
- `testPiecePayload`: piece(index: 3, begin: 16384, data: 5 bytes) encodes length 9+5
- `testFraming`: a stream of two concatenated messages decodes back into two

**Step 2:** FAIL. **Step 3 (implement):** `Handshake.swift`:

```swift
public struct Handshake: Sendable, Equatable {
    public let infoHash: Data   // 20
    public let peerID: Data     // 20
    public static let pstr = "BitTorrent protocol"
    public static let length = 68
    public static func encode(infoHash: Data, peerID: Data) -> Data
    public static func decode(_ data: Data) throws -> Handshake
    // reserved bytes: all zero (no extension protocol in v1)
}
```

`Messages.swift`:

```swift
public enum WireMessage: Sendable, Equatable {
    case keepAlive
    case choke, unchoke, interested, notInterested
    case have(piece: Int)
    case bitfield(Data)                    // raw bits, big-endian per spec
    case request(index: Int, begin: Int, length: Int)
    case piece(index: Int, begin: Int, data: Data)
    case cancel(index: Int, begin: Int, length: Int)
}
public enum WireCodec {
    public static func encode(_ m: WireMessage) -> Data    // 4-byte BE length + payload
    public static func decode(_ framed: Data) throws -> WireMessage  // id 0..8; length 0 → keepAlive
}
```

**Step 4:** PASS. **Step 5: Commit** — `git commit -m "Added wire protocol codec"`

**Task 12: PeerConnection actor (TDD)**

**Files:** Create: `Sources/Torrent/Wire/PeerConnection.swift`, `Tests/TorrentTests/PeerConnectionTests.swift`, `Tests/TorrentTests/Support/FakeWirePeer.swift`

`PeerConnection` wraps an `NWConnection` (TCP, outbound) and owns the MSE + RC4 layer. All reads/writes go through the ciphers once MSE completes.

```swift
public actor PeerConnection {
    public enum Error: Swift.Error, Equatable { case connectFailed(String), handshakeFailed, timedOut, closed }

    public init(host: String, port: UInt16, infoHash: Data, peerID: Data,
                encryptedOnly: Bool = true, connectTimeout: Duration = .seconds(20))
    public func start() async throws          // connect + MSE + obfuscated handshake
    public func send(_ m: WireMessage) async throws
    public func receiveMessage() async throws -> WireMessage   // framed, decrypted
    public func close() async
    public var peerID: Data { get }           // remote peer id after handshake
}
```

Implementation notes:
- Wrap `NWConnection` callbacks with `withCheckedThrowingContinuation` (state update → ready/failed; `send(content:completion:)`; `receiveMessage` loop with a small parser that accumulates into a buffer: 4-byte length → payload → decode; length must be ≤ 2 MiB guard against malicious length).
- MSE phase per Task 10; on any plaintext-looking first byte (`0x13`) → drop with `.peerDoesNotSupportEncryption` (encrypted-only mode).
- Keepalive: send an empty frame every 120 s (session-level timer in Task 18 instead if simpler — either is fine, must exist).
- Timeout on every receive: 90 s idle → close (peer gone).

**Step 1 (failing tests):** `PeerConnectionTests.swift` with `FakeWirePeer` (in-test TCP listener speaking MSE-responder + wire protocol):
- `testConnectAndExchange`: engine connects → MSE completes → both send/receive a `bitfield` + `request`/`piece` roundtrip
- `testPlaintextPeerRejected`: fake peer skips MSE → connection throws, engine logs "dropped"
- `testFrameOverLongRejected`: fake peer sends a 10 MB length prefix → error, connection closed

**Step 2:** FAIL → **Step 3 (implement)** → **Step 4:** PASS → **Step 5: Commit** — `git commit -m "Added peer connection support"`

### Phase 4 — Trackers

**Task 13: HTTP(S) tracker announce (TDD)**

**Files:** Create: `Sources/Torrent/Tracker/PeerList.swift`, `Sources/Torrent/Tracker/HTTPTracker.swift`, `Tests/TorrentTests/HTTPTrackerTests.swift`, `Tests/TorrentTests/Support/FakeTracker.swift`

**Step 1 (test support):** `FakeTracker.swift` — `NWListener` on 127.0.0.1:0 implementing the tracker subset over raw TCP: parse `GET /announce?…` (ignore headers), read the query params, return `d8:intervali60e5:peers<len>:<compact bytes>e` (compact = 6-byte `ip:port` entries). Exposes `lastAnnounce` (decoded params) for assertions.

**Step 2 (failing tests):** `HTTPTrackerTests.swift`:
- `testAnnounceBuildsQuery`: URL builder percent-encodes the 20-byte raw `info_hash`/`peer_id` byte-by-byte (`%XX` for non-alphanumerics), includes `port`, `uploaded=0`, `downloaded`, `left`, `compact=1`, `numwant`, `event` when given
- `testAnnounceReturnsPeers`: announce to `FakeTracker` → returns 2 compact peers + `interval`
- `testAnnounceListTierFallback`: given `[[url1], [url2]]`, tries url1 first, then url2 on failure
- `testFailureReason`: tracker returns `d14:failure reason9:bad ide` → throws `.trackerError("bad id")`
- `testPeerListDecode`: `PeerList.decode(compact:)` → 6-byte entries → (ip, port); 18-byte `peers6` → IPv6

**Step 3 (implement):** `PeerList.swift`:

```swift
public struct TrackerPeer: Sendable, Equatable, Hashable { public let host: String; public let port: UInt16 }
public enum PeerList {
    public static func decode(compact: Data) -> [TrackerPeer]     // 6-byte IPv4 entries
    public static func decodeV6(compact: Data) -> [TrackerPeer]   // 18-byte IPv6 entries
}
```

`HTTPTracker.swift` — announce over `NWConnection` with `NWParameters.tls` when the URL is `https:` (no URLSession → no ATS concerns; works from tests and app alike):

```swift
public struct TrackerAnnounceParams: Sendable {
    public var infoHash: Data, peerID: Data, port: UInt16
    public var uploaded: Int64 = 0, downloaded: Int64 = 0, left: Int64
    public var event: String?             // "started" | "completed" | "stopped" | nil
    public var numwant: Int = 50
}
public struct TrackerResponse: Sendable {
    public let interval: Int
    public let peers: [TrackerPeer]
    public let seeders: Int?
    public let leechers: Int?
}
public enum HTTPTracker {
    public static func announce(url: URL, params: TrackerAnnounceParams,
                                timeout: Duration = .seconds(30)) async throws -> TrackerResponse
}
```

HTTP/1.1 GET, parse status line + headers, body until Content-Length satisfied (no chunked support needed — trackers send Content-Length). Bencode-decode body; `failure reason` key → error; `peers` string → `PeerList.decode`.

**Step 4:** PASS. **Step 5: Commit** — `git commit -m "Added HTTP tracker support"`

**Task 14: UDP tracker announce (TDD)**

**Files:** Create: `Sources/Torrent/Tracker/UDPTracker.swift`, `Tests/TorrentTests/UDPTrackerTests.swift`, `Tests/TorrentTests/Support/FakeUDPTracker.swift`

**Step 1 (test support):** `FakeUDPTracker` — `NWListener` UDP on 127.0.0.1:0; protocol: connect request (`0x41727101980`, action 0, txid) → 16-byte response (action 0, txid, connection_id); announce request (98 bytes: conn_id, action 1, txid, infohash 20, peer_id 20, downloaded 8, left 8, uploaded 8, event 4, ip 4, key 4, numwant 4, port 2) → response (action 1, txid, interval 4, leechers 4, seeders 4, then 6-byte peers).

**Step 2 (failing tests):** `UDPTrackerTests.swift`:
- `testConnectThenAnnounce`: full flow → peers + interval returned
- `testTransactionMismatch`: response with wrong txid → throws `.transactionMismatch` (ignore and retry is also acceptable; must not return garbage)
- `testRetransmit`: fake drops the first connect request → client retransmits (same txid) and succeeds (timeout-based retransmit with 2× backoff, 3 attempts, 2 s initial — keep test fast by making timeout injectable)

**Step 3 (implement):** `UDPTracker.swift` — same public shape as `HTTPTracker` (`announce(url:params:)`), `NWConnection` with `.udp`, 16-byte connect, 98-byte announce, big-endian encoding, transaction-id validation, retransmit loop, `url.port ?? 80`-style default (UDP tracker default port 80 per spec, but parse from URL).

**Step 4:** PASS. **Step 5: Commit** — `git commit -m "Added UDP tracker support"`

---

### Phase 5 — Engine

**Task 15: Sequential piece picker (TDD)**

**Files:** Create: `Sources/Torrent/Engine/PiecePicker.swift`, `Tests/TorrentTests/PiecePickerTests.swift`

**Step 1 (failing tests):** `PiecePickerTests.swift`:
- `testStrictSequentialOrder`: 2 peers both have all 10 pieces → assigned pieces are 0,1,2,… with no skips
- `testSkipsUnavailablePieceOnlyIfNoPeerHasIt`…: actually sequential is strict — if piece 3 is on no peer, no assignment happens at all (test asserts `request` returns nil for every peer and cursor stays at 3)
- `testPipelineLimit`: peer with pipeline 2 gets ≤ 2 outstanding blocks
- `testBlockSizes`: last block of a piece is shorter (pieceLength % blockSize)
- `testNoDoubleAssignment`: block in flight on peer A is never assigned to peer B
- `testDisconnectReturnsBlocks`: after `disconnect(A)`, A's blocks become assignable again

**Step 2:** FAIL. **Step 3 (implement):** `PiecePicker.swift` (reference implementation):

```swift
public struct PiecePicker: Sendable {
    public let pieceCount: Int
    public let pieceLength: Int
    public let lastPieceLength: Int
    public let blockSize: Int
    public var cursor = 0                               // lowest unverified piece (never decreases)
    public private(set) var peerHas: [PeerID: Set<Int>] = [:]
    public private(set) var pending: [PeerID: Set<BlockKey>] = [:]
    public struct BlockKey: Hashable, Sendable { public let piece: Int; public let begin: Int }
    public struct Block: Equatable, Sendable { public let piece: Int; public let begin: Int; public let length: Int }

    public mutating func setAvailable(_ pieces: Set<Int>, on peer: PeerID)
    public mutating func setAllAvailable(on peer: PeerID)                    // peer's bitfield was all-ones or full-buffer peer
    public mutating func request(for peer: PeerID, pipeline: Int) -> Block? {
        guard pending[peer, default: []].count < pipeline else { return nil }
        var piece = cursor
        while piece < pieceCount {
            if peerHas[peer]?.contains(piece) == true {
                let blocks = blockCount(of: piece)
                var inflight = Set<BlockKey>()
                for set in pending.values { inflight.formUnion(set.filter { $0.piece == piece }) }
                for b in 0..<blocks {
                    let key = BlockKey(piece: piece, begin: b * blockSize)
                    if !inflight.contains(key) {
                        pending[peer, default: []].insert(key)
                        return Block(piece: piece, begin: key.begin,
                                     length: min(blockSize, pieceSize(of: piece) - key.begin))
                    }
                }
            }
            piece += 1
        }
        return nil
    }
    public mutating func complete(_ key: BlockKey, on peer: PeerID)          // block received
    public mutating func disconnect(_ peer: PeerID)                          // free its pending blocks
    public mutating func advancePast(_ piece: Int)                           // piece verified → cursor = piece + 1
    // helpers: blockCount(of:), pieceSize(of:)
}
```

**Step 4:** PASS. **Step 5: Commit** — `git commit -m "Added sequential piece picker"`

**Task 16: File layout + disk writer (TDD)**

**Files:** Create: `Sources/Torrent/Engine/FileLayout.swift`, `Sources/Torrent/Engine/DiskWriter.swift`, `Tests/TorrentTests/FileLayoutTests.swift`, `Tests/TorrentTests/DiskWriterTests.swift`

**Step 1 (failing tests):** `FileLayoutTests.swift`:
- `testSingleFileSpans`: piece 0 range maps to file 0 at its offset
- `testPieceStraddlesFiles`: a piece whose byte range crosses a file boundary → 2 spans
- `testSanitization`: path components with `..`, `/`, `\0`, empty, `.` → rejected/escaped; `name` is never trusted
- `testAbsolutePathRejected`

`DiskWriterTests.swift` (use `FileManager.default.temporaryDirectory` + unique subdir, cleaned up in `deinit`/teardown):
- `testPreallocateSingleFile`: `ftruncate` to total size, file exists with correct size
- `testPreallocateMultiFile`: dir `name/` created, each file at its length
- `testWritePieceSingle`: write piece bytes → file bytes at offset match
- `testWritePieceStraddling`: piece spanning two files lands correctly
- `testOverwriteSameOffsetIdempotent`

**Step 2:** FAIL. **Step 3 (implement):** `FileLayout.swift`:

```swift
public struct FileLayout: Sendable {
    public let baseDirectory: URL
    public let entries: [Entry]                       // resolved: name + path + length + url
    public struct Entry: Sendable { public let path: [String]; public let length: Int64; public let url: URL }
    public let fileEnds: [Int64]                       // prefix sums of lengths

    public init(torrent: TorrentFile, baseDirectory: URL) throws
    // piece byte-range → list of (fileIndex, offsetInFile, length)
    public func spans(forPieceRange range: Range<Int64>) -> [(file: Int, offset: Int64, length: Int)]
    public static func sanitize(_ component: String) throws -> String   // rejects "", ".", "..", "/", "\\", NUL; allows spaces/UTF-8
}
```

`DiskWriter.swift` — actor:

```swift
public actor DiskWriter {
    public init(layout: FileLayout, pieceLength: Int)
    public func prepare() throws                       // mkdir base, preallocate all files (ftruncate → sparse)
    public func write(piece index: Int, data: Data) throws   // verify size == piece size, spans → seek+write per file
    public func close()                                // flush + close handles
}
```

Keep a `FileHandle` cache per file; write via `seek(toFileOffset:)` + `write(contentsOf:)`. All lengths from the torrent (never trust the wire).

**Step 4:** PASS. **Step 5: Commit** — `git commit -m "Added disk writer support"`

**Task 17: TorrentSession engine (TDD — hermetic end-to-end)**

**Files:** Create: `Sources/Torrent/Engine/TorrentSession.swift`, `Tests/TorrentTests/SessionIntegrationTests.swift`

This task wires everything: tracker announce loop, peer manager, picker, disk, events. TDD via the hermetic harness built in Tasks 13/15/16 plus a **fake seeder**:

**Step 1 (test support):** `Support/FakeSeeder.swift` — `NWListener` TCP speaking the full MSE-responder + wire-protocol server role for a given `TorrentFile` + content `Data`: on connect, completes MSE, sends all-zero `bitfield`, `unchoke`, answers `request` with `piece` blocks from the content buffer, and **records every received message** (so tests can assert we never send `piece`/`have` and that requests arrive in ascending piece order).

**Step 2 (failing tests):** `SessionIntegrationTests.swift`:
- `testSequentialDownloadNoUpload`: synthetic 1 MB torrent (16 KiB pieces), `FakeSeeder` + `FakeTracker` (tracker returns seeder's address), session with `saveDirectory` = temp dir → `start()` → poll events until `.completed` (10 s cap) → content file bytes == original, `pieceVerified` events were 0,1,2,… in order, seeder log shows no `piece`/`have`/non-empty `bitfield` from us
- `testEncryptedOnly`: plaintext fake peer in the peer list → session never completes a connection to it (log contains `dropped`), and the MSE seeder still works
- `testSingleFilePlacement`: single-file torrent lands at `~/Downloads`-style base → `base/name`
- `testMultiFilePlacement`: multi-file torrent → `base/name/sub/path`
- `testCancel`: cancel mid-download → state `.stopped`, files partial, no crash

**Step 3 (implement):** `TorrentSession.swift` per the API in the Architecture section:

```swift
public actor TorrentSession {
    // state
    private let torrent: TorrentFile
    private let settings: TorrentSettings
    private var picker: PiecePicker
    private var disk: DiskWriter
    private var peers: [PeerID: PeerConnection] = [:]
    private var pieceBuffers: [Int: [Int: Data]]   // piece → blockBegin → data (in-progress only)
    private var pieceAttempts: [Int: Int]          // hash-mismatch retries
    private var verifiedPieces: Set<Int>
    private var stats: TorrentStats
    private let eventsContinuation: AsyncStream<TorrentEvent>.Continuation
    public let events: AsyncStream<TorrentEvent>
    // tasks
    private var trackerTask: Task<Void, Never>?
    private var peerTasks: [PeerID: Task<Void, Never>] = [:]
}
```

Loop structure:
- `start()`: `disk.prepare()`, load resume state (Task 18), announce `started` to tracker tiers (HTTP then UDP, `announceList` flattened; retry each with backoff; first successful announce seeds the peer list), spawn `trackerTask` (re-announce every `interval`, `downloaded`/`left` updated, `completed` event on finish, `stopped` on cancel), spawn peer tasks for each unique peer (cap `maxPeers`, dedupe by host:port), set state `.downloading`, emit events.
- Per-peer task: `PeerConnection.start()` (MSE), send `interested` (+ all-zero `bitfield` if the peer sends one first), then loop: `picker.request(for:peerID, pipeline:)` → `send(.request)`; `receiveMessage()`:
  - `.unchoke` → start requesting; `.choke` → stop
  - `.piece(index:begin:data:)` → verify block length, store into `pieceBuffers`, `picker.complete`, when all blocks of the piece are present → SHA1 over the assembled piece == `torrent.pieceHashes[index]` → `disk.write`, `picker.advancePast`, `verifiedPieces.insert`, emit `.pieceVerified`, update `stats.verifiedBytes`, on mismatch → increment `pieceAttempts`, retry (re-request) up to 3 times, then `.error`
  - `.have`/`.bitfield` → `picker.setAvailable`
  - `.request`/`.piece` from the peer → **never respond** (no-upload: log once per peer, ignore). This is the enforcement point.
  - disconnect/error → `picker.disconnect(peer)`, emit `.peer(.disconnected)`, remove from map
- Speed: EWMA over verified bytes; emit `.stats` every 1 s; `.completed` when `verifiedPieces.count == pieceCount` (announce `completed`).
- `pause()`/`resume()`: suspend peer tasks / restart them; `cancel()`: announce `stopped`, close all peers, state `.stopped`.

**Step 4:** PASS — all hermetic integration tests green. **Step 5: Commit** — `git commit -m "Added Torrent session engine"`

**Task 18: Resume state (stretch, do after Task 17 is green)**

**Files:** Create: `Sources/Torrent/Engine/Resume.swift`, `Tests/TorrentTests/ResumeTests.swift`

Persist verified-piece bitfield to `~/Library/Application Support/Get/<infohash-hex>.state` (JSON: `{pieceLength, totalSize, verified: [int…]}`) after every 16 verified pieces and on pause/cancel. On `start()`: if state exists and files exist with expected sizes → seed `verifiedPieces` + picker cursor (trust bitfield; full re-hash is a future option). Tests: save → reload → bitfield identical; corrupt/missing state → start fresh.

**Step: Commit** — `git commit -m "Added resume state support"`

### Phase 6 — App UI (kept in the Xcode project)

**Task 19: DownloadStore + TorrentView**

**Files:** Create: `Get/DownloadStore.swift`, `Get/TorrentView.swift`; Modify: `Get/ContentView.swift`

Keep the UI thin — it only mirrors `TorrentSession` events:

```swift
import SwiftUI
import Torrent
import Observation

@MainActor @Observable
final class DownloadStore {
    struct Item: Identifiable {
        let id: String                      // infohash hex
        var title: String
        var state: TorrentState
        var progress: Double                // 0...1
        var speed: String                   // "1.2 MB/s"
        var peers: Int
        var error: String?
    }
    private(set) var items: [Item] = []
    private var sessionTasks: [String: Task<Void, Never>] = [:]

    func openTorrent(url: URL) async throws {
        let torrent = try TorrentSession.parse(url: url)
        let settings = TorrentSettings()    // defaults: ~/Downloads, sequential, MSE-only, no upload
        let session = TorrentSession(torrent: torrent, settings: settings)
        // insert item, subscribe to session.events, await session.start()
    }
}
```

`TorrentView.swift`: `NavigationStack` + `List(items)` showing title, `ProgressView(value: progress)`, state/speed/peer line; toolbar "+" → `.fileImporter(allowedContentTypes: [.torrentUTType], allowsMultipleSelection: false)` where `torrentUTType = UTType(filenameExtension: "torrent") ?? .data`. `ContentView.swift` body → `TorrentView()`.

**Verify:** `xcodebuild -project Get.xcodeproj -scheme Get build` succeeds; `swift test` still green. Run the app (user confirms visually): add a small synthetic `.torrent` (generate one with the test helper or a tiny script) seeded locally, watch progress → file appears in `~/Downloads`.

**Commit** — `git add Get/ && git commit -m "GetApp: Added torrent download UI"`

---

## Verification strategy (summary)

- Unit: bencode, metadata, magnet, RC4 (RFC 6229), modpow (Python-generated vectors), MSE keys/sync (Python reference), wire codec, picker, file layout, disk, resume — all hermetic, `swift test`.
- Hermetic end-to-end: `FakeTracker` + `FakeSeeder` + synthetic torrent → full sequential download to a temp dir; asserts (a) byte-identical output, (b) strict ascending piece order, (c) no `piece`/`have`/non-empty `bitfield` sent by us, (d) plaintext peers dropped. No internet needed.
- Optional live test: `brew install transmission-cli`, create a small torrent with `transmission-create`, seed it locally, run the app against it (or run a tiny CLI harness using `TorrentSession`); then optionally the real `example.torrent` (user confirms visually; note its 8.88 GB size and private-tracker ratio implications).
- App: `xcodebuild -project Get.xcodeproj -scheme Get build` + user visual confirmation (per project convention: no screenshot/pixel checks).

## Risks & tradeoffs

- **MSE-only shrinks the peer pool** — peers that don't support MSE are dropped by design (encrypted-only requirement). Expect fewer peers than a normal client; acceptable for v1, logged as `dropped`.
- **No-upload leeching** — private trackers (e.g. RuTracker) enforce ratio; a pure leech may get choked by peers over time. User's explicit requirement; noted, not changed.
- **MSE is obfuscation, not authentication** — it defeats DPI throttling; it is not an authenticated cipher and an active MITM can defeat it. This is the BT standard "encryption"; requirement satisfied as specified.
- **Custom 768-bit modpow** — correctness de-risked by Python `pow()` vectors; the prime and exponent sizes are fixed by spec, so the code surface is small.
- **Swift 6 strict concurrency vs NWConnection callbacks** — all callback→actor hops go through checked continuations; keep `PeerConnection` fully encapsulated so no `nonisolated(unsafe)` leaks into the session.
- **Module collision `Get`/`Get`** — the app must `import Torrent`, never `import Get`. The stub `Get` product stays linked but unused; revisit (rename/remove) if it ever causes issues.
- **Path traversal from malicious torrents** — `FileLayout.sanitize` rejects `..`, `/`, `\`, NUL, empty, and `.` components; lengths always come from the torrent, never the wire.
- **`~/Downloads` writes** — work because `ENABLE_APP_SANDBOX = NO`. If sandbox is ever enabled, add `com.apple.security.files.downloads.read-write` (user-granted) — revisit then.
- **Example torrent passkey** — `example.torrent` embeds a private-tracker passkey; it is gitignored. Never commit it or paste its announce URL into issues/logs.
- **Resume trusts the persisted bitfield** (no re-hash on start) — a file modified outside the app could yield corrupt data; documented tradeoff, full re-hash is a future option.

## Out of scope (future work)

- DHT, PEX, uTP, web seeds, magnet metadata exchange (BEP 9 ut_metadata), seeding/upload mode, listen-port inbound MSE responder role, per-torrent bandwidth caps, IPv6 tracker `peers6` beyond decode support (decode done in Task 13; v1 connects IPv4 peers only), multiple downloads UI polish.

## Open questions (confirm before/while implementing)

1. **Engine** — proceed with the custom pure-Swift implementation? (Plan assumes yes; appendix below sketches the libtorrent-rasterbar fallback.)
2. **UDP tracker in v1** — included as Task 14 (small, broadens compatibility). Drop if you want a leaner first pass.
3. **Resume state** — included as stretch Task 18. Without it, an interrupted 8.88 GB download restarts from zero.
4. **Listen port** — v1 is outbound-only: no inbound listener, announce `port` = 0 (opentracker and most public trackers accept it; if the t-ru tracker rejects port 0 during live testing, bind an ephemeral `NWListener` and report its port — accept-and-close inbound connections).

## Appendix: libtorrent-rasterbar fallback (only if MSE blocks us)

`brew install libtorrent-rasterbar`; add `cxxSettings: [.unsafeFlags(["-I/opt/homebrew/include"])]` and `linkerSettings: [.unsafeFlags(["-L/opt/homebrew/lib", "-ltorrent-rasterbar"])]` to the Torrent target; write a Swift wrapper (C++ interop, `-cxx-interoperability-mode=default`) around `lt::session`. Feature mapping: `settings_pack::sequential_download = true`; `settings_pack::allowed_enc_level = pe_rc4` (MSE-only); upload disabled via `settings_pack::upload_rate_limit = 0` + never unchoking (`set_upload_mode(true)`); save path `~/Downloads`. Alerts must be drained on a background thread and marshalled to the session actor. License: GPL-2.0 — distribution implications apply. Phases 1 (bencode/metadata) and the wire codec remain useful for tests either way.
