import CodeProgress
import Foundation
import Testing

@testable import GetKit

final class TestClock: @unchecked Sendable {
  var date = Date(timeIntervalSinceReferenceDate: 0)
  func advance(_ seconds: TimeInterval) { date += seconds }
}

private func near(_ value: Double?, _ expected: Double, _ tolerance: Double = 0.001) -> Bool {
  guard let value else { return false }
  return abs(value - expected) < tolerance
}

@Suite struct DownloadProgressTests {
  let transferID = DownloadProgress.transferID(url: URL(string: "https://Deb.Debian.org/images/mini.ISO")!)
  let checkID = DownloadProgress.checkID(algorithm: "SHA-256")

  func progress(_ history: ProgressHistory, _ clock: TestClock, check: Bool = true) -> DownloadProgress {
    DownloadProgress(transferID: transferID, checkID: check ? checkID : nil, history: history) { clock.date }
  }

  @Test func stageIDsNameTheKindOfWork() {
    #expect(transferID == "download deb.debian.org iso")
    #expect(DownloadProgress.transferID(url: URL(string: "https://example.com/")!) == "download example.com file")
    #expect(
      DownloadProgress.torrentTransferID(announce: URL(string: "udp://Tracker.example.org:1337/announce"))
        == "download torrent tracker.example.org")
    #expect(DownloadProgress.torrentTransferID(announce: nil) == "download torrent dht")
    #expect(checkID == "check SHA-256")
  }

  @Test func transferThenCheckLearnFromEachRun() {
    let history = ProgressHistory()
    let clock = TestClock()

    // First run: no history, so the transfer and the check share the bar equally.
    let first = progress(history, clock)
    first.transfer(received: 0, of: 1000)
    #expect(first.isRunning)
    clock.advance(5)
    first.transfer(received: 500, of: 1000)
    #expect(near(first.reading().fraction, 0.25))
    clock.advance(5)
    first.transfer(received: 1000, of: 1000)
    first.checking(checkID, bytes: 1000)
    #expect(near(first.reading().fraction, 0.5))
    clock.advance(2)
    first.finish()
    #expect(first.reading() == DownloadProgress.Reading(fraction: 1, remaining: 0))
    #expect(!first.isRunning)

    // The history keeps both stages, sized by their bytes.
    let transfer = ProgressStage(id: transferID, resource: .network, size: 1000)
    #expect(near(history.duration(for: transfer), 10))
    #expect(near(history.duration(for: ProgressStage(id: checkID, size: 1000)), 2))

    // Second run: the transfer takes 10 s of the 12 expected, and its bytes set the time left.
    let second = progress(history, clock)
    second.transfer(received: 0, of: 1000)
    clock.advance(5)
    second.transfer(received: 500, of: 1000)
    let reading = second.reading()
    #expect(near(reading.fraction, 5.0 / 12))
    #expect(near(reading.remaining, 7))
  }

  @Test func pausingKeepsTheBarAndResumingTimesOnlyTheBytesLeft() {
    let history = ProgressHistory()
    let clock = TestClock()
    let download = progress(history, clock, check: false)
    download.transfer(received: 0, of: 1000)
    clock.advance(5)
    download.transfer(received: 500, of: 1000)
    #expect(near(download.reading().fraction, 0.5))

    download.stop()
    #expect(!download.isRunning)
    clock.advance(100)
    #expect(download.reading() == DownloadProgress.Reading(fraction: 0.5, remaining: nil))

    // The new run fills the rest of the bar from where it stopped.
    download.transfer(received: 500, of: 1000)
    #expect(near(download.reading().fraction, 0.5))
    clock.advance(5)
    download.transfer(received: 750, of: 1000)
    #expect(near(download.reading().fraction, 0.75))
    clock.advance(5)
    download.transfer(received: 1000, of: 1000)
    download.finish()
    #expect(download.reading().fraction == 1)

    // Only the resumed run counts: 500 bytes in 10 s, the paused time left out.
    #expect(near(history.duration(for: ProgressStage(id: transferID, size: 1000)), 20))
  }

  @Test func changedWorkStartsFromTheBytesOnDisk() {
    let clock = TestClock()
    let download = progress(ProgressHistory(), clock, check: false)
    download.transfer(received: 0, of: 1000)
    clock.advance(4)
    download.transfer(received: 400, of: 1000)
    #expect(near(download.reading().fraction, 0.4))

    // A restored file doubles the torrent: the bar goes back to the share on disk.
    download.transfer(received: 400, of: 2000)
    #expect(near(download.reading().fraction, 0.2))

    // So does a link whose file changed on the server, even while paused.
    download.stop()
    download.transfer(received: 0, of: nil)
    #expect(download.reading().fraction == 0)
  }

  @Test func relaunchStartsFromTheBytesOnDisk() {
    let download = progress(ProgressHistory(), TestClock(), check: false)
    download.transfer(received: 600, of: 1000)
    #expect(near(download.reading().fraction, 0.6))
  }

  @Test func restoredPausedShowsTheBytesOnDisk() {
    let clock = TestClock()
    let download = progress(ProgressHistory(), clock, check: false)
    download.idle(received: 300, of: 1000)
    #expect(!download.isRunning)
    #expect(download.reading() == DownloadProgress.Reading(fraction: 0.3, remaining: nil))
    // Resumed, the run fills the rest of the bar from there.
    download.transfer(received: 300, of: 1000)
    clock.advance(7)
    download.transfer(received: 650, of: 1000)
    #expect(near(download.reading().fraction, 0.65))
  }

  @Test func transferOfUnknownSizeIsNotTimed() {
    let history = ProgressHistory()
    let clock = TestClock()
    let download = progress(history, clock, check: false)
    download.transfer(received: 100, of: nil)
    clock.advance(5)
    #expect(download.reading() == DownloadProgress.Reading(fraction: 0, remaining: nil))
    // The stream ended: its size is known only now.
    download.transfer(received: 5000, of: 5000)
    download.planCheck(checkID)
    download.checking(checkID, bytes: 5000)
    clock.advance(1)
    download.finish()

    #expect(history.duration(for: ProgressStage(id: transferID, size: 5000)) == nil)
    #expect(near(history.duration(for: ProgressStage(id: checkID, size: 5000)), 1))
  }
}
