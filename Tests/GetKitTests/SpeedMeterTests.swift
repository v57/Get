import Testing

@testable import GetKit

@Test func speedMeterFirstSampleIsZero() {
  var meter = SpeedMeter()
  #expect(meter.record(totalBytes: 1000, at: 10) == 0)
}

@Test func speedMeterAveragesBurstsOverTheWindow() {
  // 8 MB lands every other second: a per-tick delta would read 8, 0, 8, 0…
  var meter = SpeedMeter(window: 5)
  var total: Int64 = 0
  _ = meter.record(totalBytes: total, at: 0)
  var speeds: [Double] = []
  for second in 1...10 {
    if second % 2 == 0 { total += 8_000_000 }
    speeds.append(meter.record(totalBytes: total, at: Double(second)))
  }
  // Once the window is full the reading stays near the real 4 MB/s average.
  for speed in speeds.suffix(5) { #expect(speed >= 3_000_000 && speed <= 5_000_000) }
  #expect(!speeds.suffix(5).contains(0))
}

@Test func speedMeterDropsSamplesOlderThanTheWindow() {
  var meter = SpeedMeter(window: 5)
  _ = meter.record(totalBytes: 0, at: 0)
  _ = meter.record(totalBytes: 100_000_000, at: 1)  // a fast first second
  var speed = 0.0
  for second in 2...12 { speed = meter.record(totalBytes: 100_000_000, at: Double(second)) }
  // Nothing has arrived for the last 5+ seconds.
  #expect(speed == 0)
}

@Test func speedMeterResetAndBackwardsTotalsStartOver() {
  var meter = SpeedMeter()
  _ = meter.record(totalBytes: 0, at: 0)
  #expect(meter.record(totalBytes: 1000, at: 1) == 1000)
  meter.reset()
  #expect(meter.record(totalBytes: 5000, at: 2) == 0)
  #expect(meter.record(totalBytes: 10, at: 3) == 0)
}
