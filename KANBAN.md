KANBAN: Get / Torrent Engine  (board slug: get-torrent)

GOAL: Fix the Get macOS download app's torrent engine so downloads sustain
throughput (not collapse to 0 KB/s), stop burning ~116% CPU while stalled, and
finish pieces that stall near-complete. The user observed "7 MB/s -> 0-512 KB/s
for a minute or two", "much slower than Transmission", "116% CPU at 0 KB/s",
and "some parts never retried after being stuck".

BOARD / COMMAND REFERENCE
  Board slug : get-torrent  (ALWAYS pass --board get-torrent; the switch does
               not persist across CLI invocations)
  DB path    : ~/.hermes/kanban/boards/get-torrent/kanban.db
  Lifecycle  : triage -> todo -> ready -> running -> done/archived (+ scheduled)
  Commands   :
    hermes kanban --board get-torrent list --json
    hermes kanban --board get-torrent show <id>
    hermes kanban --board get-torrent comment <id> "<text>"
    hermes kanban --board get-torrent dispatch [--max N]
    hermes kanban --board get-torrent log <id>
  Create cards WITHOUT --triage and WITH full self-contained bodies so the
  specifier sweep does not rewrite them.

WORKING CONTRACT / LOCAL TEST LOOP
  - Repo: /Users/v57/Projects/Get (single git repo, origin = github.com/v57/Get.git)
  - Engine is a SwiftPM package: Swift Package targets under Sources/Torrent.
  - Hermetic test suite (skip the 4 network suites):
      cd /Users/v57/Projects/Get && \
      swift test --skip HTTPTrackerTests --skip UDPTrackerTests \
                 --skip SessionIntegrationTests --skip PeerConnectionTests
    (currently 141 tests passing; baseline at faf135e)
  - The app target (macOS) builds via xcodebuild, but for engine work the
    SwiftPM `swift test` + `swift build` gate is authoritative. Do NOT relaunch
    Get.app to verify — the running app does harm. Verify by test + build only.

GIT RULES (hard)
  - Commit locally. NEVER push (origin = github.com/v57/Get.git).
  - Commit style for a change to existing code: "<Scope>: <past-tense>",
    e.g. "Torrent: relax strict piece gate for sustained speed".
  - Keep the working tree clean before declaring a card done (workers commit
    their own card's work; never swallow a sibling's uncommitted hunks).

BASELINE (already done — do NOT re-implement)
  - faf135e "Torrent: advance picker frontier only past verified pieces":
    PiecePicker.advancePast clamps cursorPos to the lowest non-completed piece
    (never jumps past an unverified one); PiecePicker has `completed: Set<Int>`;
    request() skips completed pieces. This killed the order-exhaustion deadlock
    (frontier=3020 sentinel at 94.3%).
  - e3b2452 "Torrent: do not scan or connect paused downloads": paused-at-launch
    downloads skip the disk scan and start() returns before announce/DHT/peers.
  - d90a3f2 "Torrent: bound resume re-verify memory and retry stalled pieces":
    streaming SHA-1 hash in DiskWriter (256 KB reused buffer) removes the
    19-25 GB launch-time memory spike; resume API now has reverify mode.
  - The strict-sequential gate is STILL PRESENT and is the root cause of the
    remaining speed + CPU problems — this is what the tasks below remove.

DEADLOCKED/STALLED TORRENT SEEN IN LOGS (context for the workers)
  - debian-13.6.0-amd64-netinst.iso: 3020 pieces @ 256 KB, verified 2848/3020,
    127 scattered holes starting at piece 1260. DIAG line showed frontier=3020
    (== pieceCount sentinel) with peer-has-frontier=false, 33-80 peers, but
    speedKBs=0 — a discovery/fetch wall, not a peer-count problem.
  - The user profile: media apps test with "no pixel checks, user confirms
    visually"; downloads are verified by the engine's own SHA-1 piece hashes.

TASKS (priority = phase*10)

  Phase 1 (priority 10) — ROOT, dispatch first
    t_aee890c9  "Torrent: relax strict sequential piece gate for sustained speed"
      - Remove the strict gate (PiecePicker.request ~line 118) so a peer is
        assigned its earliest available uncompleted piece (>= frontier) even
        when the frontier is momentarily unheld by all peers.
      - Idle-poll backoff in TorrentSession.peerLoop: when a peer has nothing in
        flight and nothing to request, back off receiveMessageOrIdle from 500ms
        (e.g. 2-5s) so a momentarily-empty swarm does not burn a core.
      - Rewrite the picker test stallsWhenCursorPieceAvailableOnNoPeer (it
        currently asserts the old freeze) and add a regression proving the
        freeze is gone (frontier unheld but later pieces available -> a peer
        holding a later piece still gets it).
      - Build gate: swift test (hermetic, 141+) + swift build must pass.

  Phase 2 (priority 20) — DEPENDS ON Phase 1 (linked parent t_aee890c9)
    t_99136532  "Torrent: add endgame mode for near-complete pieces"
      - Endgame policy in PiecePicker: when a piece has only a few blocks
        missing (<= endgameThreshold, ~6), allow the same missing BlockKey to be
        requested by MULTIPLE peers (redundant last-block fetch).
      - Idempotent block handling in TorrentSession.handlePiece: a duplicate
        endgame block (already in pieceBuffers) is a no-op, not re-stored/hashed.
      - Endgame state resets on hash mismatch so the piece re-fetches cleanly.
      - Build gate: swift test (hermetic) + swift build must pass.

DEPENDENCY GRAPH
  t_aee890c9  ->  t_99136532   (endgame waits for the gate fix)
  Both edit the SAME files (PiecePicker.swift, TorrentSession.swift,
  PiecePickerTests.swift), so they are SEQUENCED via the link — run one at a
  time, never in parallel, to avoid a shared-worktree collision.

ACCEPTANCE CRITERIA (board-wide)
  - Sweep all 141 hermetic tests green plus the new regression tests.
  - swift build of the Torrent package succeeds.
  - No relaunch of Get.app; engine verified by test/build only.

SHOW / VERIFY
  hermes kanban --board get-torrent show t_aee890c9   (parents [], children
                                                        t_99136532)
  hermes kanban --board get-torrent show t_99136532   (parents t_aee890c9)
  hermes kanban --board get-torrent list --json
