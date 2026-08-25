import Testing
import Foundation
@testable import Torrent

/// `PeerRateTracker` — the adaptive per-peer pipeline depth.
///
/// The core property: a peer's queue should scale with its MEASURED rate so
/// a single fast peer can saturate the link (in-flight/RTT is the ceiling),
/// while a slow peer doesn't pile up requests. Also: before any data, the
/// depth is the `min` (pipe primed, not zero); and it never exceeds `max`.
struct PeerRateTrackerTests {

    @Test func freshTrackerUsesMinDepth() {
        let clock = FakeClock()
        var t = PeerRateTracker(nowNanos: { clock.now })
        // No data recorded yet — the EMA is 0, so the depth must fall back
        // to the caller's `min` (keep the pipe primed), not 0.
        #expect(t.pipelineDepth(blockSize: 16384, min: 64, max: 250) == 64)
    }

    @Test func depthClampsToMax() {
        let clock = FakeClock()
        var t = PeerRateTracker(nowNanos: { clock.now })
        feed(&t, clock: clock, bytesPerSecond: 100 * 1024 * 1024, seconds: 3)
        // 100 MiB/s → 2 s of buffer = 200 MiB = 12800 blocks at 16 KiB —
        // far over the 250 cap.
        #expect(t.pipelineDepth(blockSize: 16384, min: 64, max: 250) == 250)
    }

    @Test func depthScalesWithRate() {
        let clock = FakeClock()
        var t = PeerRateTracker(nowNanos: { clock.now })
        // 1 MiB/s → 2 s of buffer = 2 MiB = 128 blocks at 16 KiB.
        feed(&t, clock: clock, bytesPerSecond: 1024 * 1024, seconds: 3)
        let depth = t.pipelineDepth(blockSize: 16384, min: 64, max: 250)
        // EMA converges toward the true rate; allow a tolerance band.
        #expect(depth > 100 && depth <= 250, "depth \(depth) should be ~128")
    }

    @Test func slowPeerStaysShallow() {
        let clock = FakeClock()
        var t = PeerRateTracker(nowNanos: { clock.now })
        // 64 KiB/s → 2 s = 128 KiB = 8 blocks — below min, so min wins.
        feed(&t, clock: clock, bytesPerSecond: 64 * 1024, seconds: 3)
        #expect(t.pipelineDepth(blockSize: 16384, min: 64, max: 250) == 64)
    }

    @Test func emaSmoothsSpikes() {
        let clock = FakeClock()
        var t = PeerRateTracker(nowNanos: { clock.now })
        // Alternate a moderately fast window with a slow one: the EMA must
        // not jump to either extreme (a pure spike would clamp at 250).
        for i in 0..<6 {
            let fast = i % 2 == 0
            feed(&t, clock: clock, bytesPerSecond: fast ? 4 * 1024 * 1024 : 256 * 1024, seconds: 0.6)
        }
        let depth = t.pipelineDepth(blockSize: 16384, min: 64, max: 250)
        // 4 MiB/s → 512 blocks; 256 KiB/s → 32 blocks. The EMA should sit
        // between them, not at the clamp.
        #expect(depth > 64 && depth < 250, "depth \(depth) should be between the rates")
    }

    // MARK: Helpers

    /// A fake monotonic clock in nanoseconds, advanced explicitly.
    private final class FakeClock: @unchecked Sendable {
        var now: Int64 = 0
        func advance(by nanos: Int64) { now += nanos }
    }

    /// Feed `bytesPerSecond` for `seconds`, advancing the fake clock one
    /// 500ms window per record call so each window closes. The tracker's
    /// window is 500ms = 5e8 nanoseconds, so advance by that.
    private func feed(_ t: inout PeerRateTracker, clock: FakeClock,
                      bytesPerSecond: Int64, seconds: Double) {
        var remaining = seconds
        while remaining > 0 {
            let window = min(0.5, remaining)
            clock.advance(by: 500_000_000)  // 500ms in nanos, BEFORE record
            t.record(bytes: Int64(Double(bytesPerSecond) * window))
            remaining -= window
        }
    }
}
