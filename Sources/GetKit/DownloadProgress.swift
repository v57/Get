import CodeProgress
import Foundation

/// One download's progress as the user sees it, the transfer and the check that follows it, and the time left,
/// estimated by CodeProgress from how long the same kind of work took before.
///
/// Each stretch of moving work is a run of a `ProgressTracker`. Pausing or failing ends the run without keeping its
/// running stage (time spent stopped says nothing about speed); resuming starts a new run for the bytes still to
/// fetch, which fills what is left of the bar from where it stopped. The transfer is sized by the bytes the run
/// fetches, so the history learns its fixed cost (connecting, finding peers) apart from its cost per byte. When the
/// work itself changes (bytes are dropped because the file changed on the server, a torrent gains or loses files),
/// the next run starts from the share of bytes on disk instead.
///
/// Snapshots move with time: read `reading()` on a timer while `isRunning`.
public final class DownloadProgress {
  /// How far the download got, at one moment.
  public struct Reading: Equatable, Sendable {
    /// From 0 to 1, never lower than an earlier reading unless the work changed.
    public var fraction: Double
    /// Time left, when every stage left has an estimate.
    public var remaining: TimeInterval?

    public init(fraction: Double, remaining: TimeInterval?) {
      self.fraction = fraction
      self.remaining = remaining
    }
  }

  /// The transfer's stage id, also the operation the history keeps the run's stages under.
  public let transferID: String
  public let history: ProgressHistory
  private let now: @Sendable () -> Date

  private var tracker: ProgressTracker?
  private enum Running { case nothing, transfer, check }
  private var running = Running.nothing
  /// The check planned for the next run, when the download will be checked.
  private var checkID: String?
  /// Where this run's share of the bar starts.
  private var base = 0.0
  /// Bytes on disk when the run started, and the total the transfer was begun with.
  private var runStart: Int64 = 0
  private var runTotal: Int64?
  /// What the transfer last reported, to tell when the work changed.
  private var last: (received: Int64, total: Int64?)?
  private var shown: Double?
  private var isFinished = false

  /// - Parameters:
  ///   - transferID: the kind of transfer (`transferID(url:)`, `torrentTransferID(announce:)`), so other files of
  ///     the same kind share its history.
  ///   - checkID: the check that follows the transfer (`checkID(algorithm:)`), when one is known.
  public init(
    transferID: String, checkID: String? = nil, history: ProgressHistory = .standard,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.transferID = transferID
    self.checkID = checkID
    self.history = history
    self.now = now
  }

  // MARK: - Stage ids

  /// "download deb.debian.org iso": the server and the file type, which set a link's speed more than the file does.
  public static func transferID(url: URL) -> String {
    let type = url.pathExtension.lowercased()
    return "download \(url.host()?.lowercased() ?? "link") \(type.isEmpty ? "file" : type)"
  }

  /// "download torrent tracker.example.org": a swarm's speed follows its tracker (public or private) more than its
  /// files. Trackerless torrents share one history.
  public static func torrentTransferID(announce: URL?) -> String {
    "download torrent \(announce?.host()?.lowercased() ?? "dht")"
  }

  /// "check SHA-256": hashing speed follows the algorithm and the file's size.
  public static func checkID(algorithm: String) -> String { "check \(algorithm)" }

  // MARK: - Reporting

  /// Whether a run is going: read `reading()` on a timer while it is.
  public var isRunning: Bool { tracker != nil }

  /// The check the download will run once the transfer is over, learned after it began (a server's digest).
  public func planCheck(_ id: String?) { checkID = id }

  /// The download isn't moving (paused, or restored paused): until a run shows more, the bar shows the bytes on
  /// disk.
  public func idle(received: Int64, of total: Int64?) {
    guard !isFinished else { return }
    note(received: received, of: total)
  }

  /// The transfer is moving: `received` bytes on disk of `total` (nil while unknown).
  public func transfer(received: Int64, of total: Int64?) {
    guard !isFinished else { return }
    note(received: received, of: total)
    if tracker == nil { startRun(received: received, total: total) }
    guard let tracker else { return }
    // A transfer whose size is unknown isn't timed: its run would record a size it never had. Nor is one that
    // learned its size only as it ended.
    if running == .nothing, let total, received < total {
      runTotal = total
      tracker.begin(transferStage(size: total - runStart))
      running = .transfer
    }
    if running == .transfer, let runTotal {
      tracker.update(units: Double(received - runStart), of: Double(runTotal - runStart))
    }
  }

  /// The transfer is over and the file (`bytes` long) is being checked.
  public func checking(_ id: String, bytes: Int64?) {
    guard !isFinished else { return }
    checkID = id
    if tracker == nil { startRun(received: bytes ?? 0, total: bytes) }
    guard running != .check, let tracker else { return }
    tracker.begin(checkStage(id, size: bytes))
    running = .check
  }

  /// Paused, failed or stopped: the run ends, and the bar stays where it is.
  public func stop() {
    tracker?.cancel()
    tracker = nil
    running = .nothing
  }

  /// Done: the run's stages go into the history.
  public func finish() {
    tracker?.complete()
    tracker = nil
    running = .nothing
    shown = 1
    isFinished = true
  }

  // MARK: - Reading

  public func reading() -> Reading {
    if isFinished { return Reading(fraction: 1, remaining: 0) }
    guard let tracker else { return Reading(fraction: shown ?? onDisk, remaining: nil) }
    let snapshot = tracker.snapshot()
    let value = base + (1 - base) * (snapshot.fraction ?? 0)
    shown = max(shown ?? 0, value)
    // Before the transfer learns its size nothing runs, and nothing planned would read as no time left.
    return Reading(fraction: shown ?? 0, remaining: running == .nothing ? nil : snapshot.remaining)
  }

  // MARK: - Runs

  private func note(received: Int64, of total: Int64?) {
    if let last, received < last.received || (last.total != nil && total != last.total) {
      // The work changed, even while stopped: the bar starts again from what is on disk.
      stop()
      shown = nil
    }
    last = (received, total)
  }

  /// The share of bytes on disk, from what the transfer last reported.
  private var onDisk: Double {
    guard let last, let total = last.total, total > 0 else { return 0 }
    return min(1, Double(last.received) / Double(total))
  }

  private func startRun(received: Int64, total: Int64?) {
    base = shown ?? onDisk
    runStart = received
    runTotal = nil
    running = .nothing
    var stages: [ProgressStage] = []
    if let total, received < total { stages.append(transferStage(size: total - received)) }
    if let checkID { stages.append(checkStage(checkID, size: total)) }
    tracker = ProgressTracker(operation: transferID, stages: stages, history: history, now: now)
  }

  private func transferStage(size: Int64) -> ProgressStage {
    ProgressStage(id: transferID, title: "Download", resource: .network, timing: .static, size: Double(size))
  }

  private func checkStage(_ id: String, size: Int64?) -> ProgressStage {
    ProgressStage(id: id, title: "Check", resource: .cpu, timing: .static, size: size.map(Double.init))
  }
}
