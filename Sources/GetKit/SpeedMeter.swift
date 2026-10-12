import Foundation

/// Download speed averaged over a sliding time window.
///
/// Fed the running byte total once per stats tick, it reports
/// bytes/sec over the last `window` seconds. A per-tick delta jumps between 0
/// and the full rate whenever bytes arrive in bursts (a torrent counts a whole
/// piece at once, a slow tick sees nothing); averaging over several ticks
/// shows the rate the user is actually getting.
public struct SpeedMeter: Sendable {
  /// Averaging window in seconds.
  public let window: Double
  private var samples: [(time: Double, bytes: Int64)] = []

  public init(window: Double = 5) { self.window = window }

  /// Monotonic seconds since boot, the default clock for `record`.
  public static var now: Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

  /// Record the running byte total at `time` (monotonic seconds) and return
  /// the average speed in bytes/sec over the window. The first sample (or a
  /// total that went backwards) returns 0.
  public mutating func record(totalBytes: Int64, at time: Double = SpeedMeter.now) -> Double {
    if let last = samples.last, totalBytes < last.bytes { samples.removeAll() }
    samples.append((time, totalBytes))
    // Keep one sample at or before the window start as the baseline.
    while samples.count > 2, samples[1].time <= time - window { samples.removeFirst() }
    guard let first = samples.first, time > first.time else { return 0 }
    return Double(totalBytes - first.bytes) / (time - first.time)
  }

  /// Forget every sample (pause, restart): the next `record` starts at 0.
  public mutating func reset() { samples.removeAll() }
}
