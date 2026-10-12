import GetKit
import Foundation
import os

public enum URLDownloadState: Sendable, Equatable {
  case stopped
  case downloading
  case paused
  /// Checking the finished file against its checksum.
  case verifying
  case completed
  case failed(String)
}

public struct URLDownloadStats: Sendable, Equatable {
  public var receivedBytes: Int64 = 0
  /// File length, when the server reported it.
  public var totalBytes: Int64?
  /// Bytes/sec averaged over the last 5 seconds.
  public var downloadSpeed: Double = 0
  /// Connections currently fetching segments.
  public var connections = 0
  /// The server accepts range requests: segmented, and resumable.
  public var resumable = false

  public init() {}

  public var progress: Double {
    guard let totalBytes, totalBytes > 0 else { return 0 }
    return min(1, Double(receivedBytes) / Double(totalBytes))
  }
}

public enum URLDownloadEvent: Sendable {
  case state(URLDownloadState)
  case stats(URLDownloadStats)
  /// Where the file is being written, once the first response named it.
  case file(URL)
  /// The finished file matched this checksum.
  case verified(Checksum)
  /// A transient problem; the download retries on its own.
  case error(String)
}

/// One plain HTTP/HTTPS download.
///
/// The first request asks for `bytes=0-`. A `206` answer means the server
/// takes ranges: the file is split into up to `maxConnections` segments
/// fetched in parallel, and when a connection finishes early it takes half of
/// the largest remaining segment. A `200` answer is read as a single stream.
/// Progress is saved per segment in the record, so a paused, failed or
/// relaunched download continues with `Range` + `If-Range` requests. If the
/// file changed on the server meanwhile, the download restarts from zero
/// rather than mixing versions. When a checksum is known (given by the user,
/// or published by the server in `Repr-Digest`/`Digest`), the finished file
/// is verified before the download counts as completed.
public actor URLDownloadSession {
  static let log = Logger(subsystem: "dev.v57.get", category: "url")

  public let events: AsyncStream<URLDownloadEvent>
  private let continuation: AsyncStream<URLDownloadEvent>.Continuation

  private var record: URLDownloadRecord
  private let saveDirectory: URL
  private let recordURL: URL?
  private let maxConnections: Int
  private let minSegmentSize: Int64
  private let retryDelay: Duration
  private let maxRetries: Int
  private let streamer: HTTPStreamer

  private var state: URLDownloadState = .stopped
  private var stats = URLDownloadStats()
  private var speedMeter = SpeedMeter()
  private var file: FileHandle?
  /// Bumped whenever the running workers are abandoned (pause, restart,
  /// cancel); a worker from an older generation stops at its next step.
  private var generation = 0
  private var workers: [Task<Void, Never>] = []
  private var activeWorkers = 0
  /// Segments a worker is fetching right now. An unfinished segment outside
  /// this set (its worker retired) is picked up by the next free worker.
  private var owned: Set<Int> = []
  private var statsTask: Task<Void, Never>?
  private var ticks = 0

  /// - Parameters:
  ///   - record: a new `URLDownloadRecord(url:checksum:)`, or one loaded from
  ///     `recordURL` to continue a download.
  ///   - saveDirectory: where the file is written.
  ///   - recordURL: where progress is saved (nil: not saved).
  ///   - configuration: the URLSession configuration (tests inject a mock
  ///     protocol). Caching is turned off on it.
  public init(
    record: URLDownloadRecord, saveDirectory: URL, recordURL: URL?, maxConnections: Int = 4,
    minSegmentSize: Int64 = 1 << 20, configuration: URLSessionConfiguration = .default,
    retryDelay: Duration = .seconds(1), maxRetries: Int = 10
  ) {
    self.record = record
    self.saveDirectory = saveDirectory
    self.recordURL = recordURL
    self.maxConnections = max(1, maxConnections)
    self.minSegmentSize = max(1, minSegmentSize)
    self.retryDelay = retryDelay
    self.maxRetries = maxRetries
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    self.streamer = HTTPStreamer(configuration: configuration)
    var cont: AsyncStream<URLDownloadEvent>.Continuation!
    self.events = AsyncStream(bufferingPolicy: .bufferingNewest(200)) { cont = $0 }
    self.continuation = cont
    stats.totalBytes = record.totalBytes
    stats.receivedBytes = record.receivedBytes
    stats.resumable = record.acceptsRanges
  }

  deinit { streamer.invalidate() }

  /// Where the file is (or will be) written; nil until the name is known.
  public var fileURL: URL? { record.filename.map { saveDirectory.appendingPathComponent($0) } }

  public func currentRecord() -> URLDownloadRecord { record }

  // MARK: - Lifecycle

  public func start(initiallyPaused: Bool = false) {
    guard state == .stopped else { return }
    if let fileURL {
      // A saved download whose file is gone has nothing to resume.
      if !FileManager.default.fileExists(atPath: fileURL.path) { resetSegments() }
      emit(.file(fileURL))
    }
    emit(.stats(stats))
    if initiallyPaused {
      state = .paused
      emit(.state(state))
      return
    }
    begin()
  }

  public func pause() {
    guard state == .downloading else { return }
    stopWorkers()
    state = .paused
    emit(.state(state))
    saveRecord()
  }

  public func resume() {
    guard state == .paused || isFailed else { return }
    begin()
  }

  /// Stop for good, keeping the partial file and the saved record.
  public func cancel() {
    guard state != .stopped, state != .completed else { return }
    stopWorkers()
    saveRecord()
    closeFile()
    streamer.invalidate()
    state = .stopped
    emit(.state(state))
    continuation.finish()
  }

  private var isFailed: Bool {
    if case .failed = state { return true }
    return false
  }

  private func begin() {
    state = .downloading
    emit(.state(state))
    if statsTask == nil { statsTask = Task { await self.statsLoop() } }
    launchWorkers()
  }

  private func stopWorkers() {
    generation += 1
    for worker in workers { worker.cancel() }
    workers.removeAll()
    activeWorkers = 0
    owned.removeAll()
    speedMeter.reset()
    stats.downloadSpeed = 0
    stats.connections = 0
    emit(.stats(stats))
  }

  /// Start a worker for every unfinished segment.
  private func launchWorkers() {
    generation += 1
    if record.segments.isEmpty || (!record.acceptsRanges && record.receivedBytes > 0) {
      // Fresh, or a server without ranges: the only way on is from byte 0.
      resetSegments()
    }
    let pending = record.segments.indices.filter { !record.segments[$0].isDone }
    if pending.isEmpty {
      Task { await self.finishIfDone() }
      return
    }
    // Without ranges only one stream can run. With them, at most
    // `maxConnections`; the other segments go to whichever frees up first.
    for index in (record.acceptsRanges ? pending : [pending[0]]).prefix(maxConnections) {
      spawnWorker(index)
    }
  }

  private func spawnWorker(_ segment: Int) {
    let gen = generation
    owned.insert(segment)
    activeWorkers += 1
    stats.connections = activeWorkers
    workers.append(Task { await self.runWorker(segment: segment, generation: gen) })
  }

  /// Back to a single unbounded segment and an empty file.
  private func resetSegments() {
    record.segments = [.init(start: 0, end: nil)]
    record.totalBytes = nil
    record.validator = nil
    record.acceptsRanges = false
    stats.receivedBytes = 0
    stats.totalBytes = nil
    if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
      try? file?.truncate(atOffset: 0)
      if file == nil { try? FileManager.default.removeItem(at: fileURL) }
    }
  }

  // MARK: - Workers

  private enum WorkerError: Error {
    /// The file changed on the server (or the server dropped range
    /// support): start over.
    case restart
    /// Not worth retrying (404, disk full…).
    case permanent(String)
    /// The server wants fewer requests (429, 503), maybe saying how long to
    /// wait.
    case busy(String, retryAfter: Duration?)
    /// The response ended before the segment did.
    case truncated
  }

  private func runWorker(segment initial: Int, generation gen: Int) async {
    var index = initial
    var failures = 0
    defer { workerEnded(segment: index, generation: gen) }
    while gen == generation, !Task.isCancelled {
      if record.segments[index].isDone {
        guard let next = nextSegment() else { return }
        owned.remove(index)
        owned.insert(next)
        index = next
        failures = 0
        continue
      }
      let before = record.segments[index].next
      do {
        try await fetch(segment: index, generation: gen)
        guard gen == generation else { return }
        if record.segments[index].end == nil {
          // An unbounded stream ended cleanly: that was the whole file.
          let length = record.segments[index].next
          record.segments[index].end = length
          record.totalBytes = length
          stats.totalBytes = length
        } else if !record.segments[index].isDone {
          throw WorkerError.truncated
        }
      } catch is CancellationError {
        return
      } catch WorkerError.restart {
        guard gen == generation else { return }
        Self.log.info("\(self.record.url, privacy: .public) changed on the server; restarting")
        stopWorkers()
        resetSegments()
        launchWorkers()
        return
      } catch WorkerError.permanent(let message) {
        guard gen == generation else { return }
        fail(message)
        return
      } catch WorkerError.busy(let message, let retryAfter) {
        guard gen == generation else { return }
        if activeWorkers > 1 {
          // Too many connections for this server: this one steps back and
          // its segment goes to whichever connection frees up first.
          Self.log.info("server busy (\(message, privacy: .public)); dropping a connection")
          return
        }
        failures += 1
        guard failures <= maxRetries else {
          fail(message)
          return
        }
        emit(.error(message))
        let backoff = retryDelay * (1 << min(failures - 1, 5))
        try? await Task.sleep(for: min(max(backoff, retryAfter ?? .zero), .seconds(120)))
      } catch {
        guard gen == generation, !Task.isCancelled else { return }
        if (error as? URLError)?.code == .cancelled { return }
        if record.segments[index].next > before { failures = 0 }
        failures += 1
        let message = Self.describe(error)
        guard failures <= maxRetries else {
          fail(message)
          return
        }
        Self.log.info("retrying after: \(message, privacy: .public)")
        emit(.error(message))
        if !record.acceptsRanges { resetSegments() }
        let delay = retryDelay * (1 << min(failures - 1, 5))
        try? await Task.sleep(for: min(delay, .seconds(30)))
      }
    }
  }

  private func workerEnded(segment: Int, generation gen: Int) {
    guard gen == generation else { return }
    owned.remove(segment)
    activeWorkers -= 1
    stats.connections = activeWorkers
    if activeWorkers == 0 { Task { await self.finishIfDone() } }
  }

  /// Fetch one segment from its `next` byte, writing as data arrives, until
  /// the segment's end, the end of the response, or an error.
  private func fetch(segment index: Int, generation gen: Int) async throws {
    let segment = record.segments[index]
    var request = URLRequest(url: record.url)
    // Byte ranges and lengths must describe the file itself, not a
    // compressed encoding of it.
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    let rangeEnd = segment.end.map { String($0 - 1) } ?? ""
    request.setValue("bytes=\(segment.next)-\(rangeEnd)", forHTTPHeaderField: "Range")
    if let validator = record.validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }

    for try await chunk in streamer.stream(request) {
      guard gen == generation else { return }
      switch chunk {
      case .response(let response):
        try accept(response, segment: index)
      case .data(let data):
        if try !write(data, segment: index) { return }
      }
    }
  }

  /// Check a response against the segment it answers. Learns the file's
  /// name, length, validator and range support from the first one, and
  /// splits the file into segments once ranges are confirmed.
  private func accept(_ response: HTTPURLResponse, segment index: Int) throws {
    let segment = record.segments[index]
    switch response.statusCode {
    case 206:
      guard let range = Self.contentRange(response), range.start == segment.next else {
        throw WorkerError.restart
      }
      if let total = range.total, let known = record.totalBytes, total != known {
        throw WorkerError.restart
      }
      record.acceptsRanges = true
      stats.resumable = true
      if record.totalBytes == nil, let total = range.total {
        record.totalBytes = total
        stats.totalBytes = total
        record.segments[index].end = record.segments[index].end ?? total
      }
    case 200:
      // The whole file. Fine for a fresh single stream; anything else means
      // the server ignored the range (no support, or If-Range said the file
      // changed), and the bytes on disk no longer line up.
      guard segment.next == 0, record.segments.count == 1 else { throw WorkerError.restart }
      record.acceptsRanges = false
      stats.resumable = false
      let length = response.expectedContentLength
      record.totalBytes = length >= 0 ? length : nil
      stats.totalBytes = record.totalBytes
      record.segments[index].end = record.totalBytes
    case 416:
      throw WorkerError.restart
    case 429, 503:
      throw WorkerError.busy(Self.status(response), retryAfter: Self.retryAfter(response))
    case 408, 500...599:
      throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: Self.status(response)])
    default:
      throw WorkerError.permanent(Self.status(response))
    }

    if record.validator == nil { record.validator = Self.validator(response) }
    if record.serverChecksum == nil {
      let header =
        response.value(forHTTPHeaderField: "Repr-Digest")
        ?? response.value(forHTTPHeaderField: "Digest")
      record.serverChecksum = header.flatMap { Checksum(digestHeader: $0) }
    }
    if record.filename == nil {
      record.filename = uniqueFilename(Self.filename(response, url: record.url))
      emit(.file(fileURL!))
    }
    try openFile()
    if index == 0, record.segments.count == 1, record.acceptsRanges { splitFirstSegment() }
  }

  /// Write a body chunk at the segment's position. Returns false once the
  /// segment is complete (the caller stops reading).
  private func write(_ data: Data, segment index: Int) throws -> Bool {
    var segment = record.segments[index]
    var chunk = data
    if let remaining = segment.remaining {
      guard remaining > 0 else { return false }
      if chunk.count > remaining { chunk = chunk.prefix(Int(remaining)) }
    }
    guard let file else { throw WorkerError.permanent("The file isn't open") }
    do {
      try file.seek(toOffset: UInt64(segment.next))
      try file.write(contentsOf: chunk)
    } catch {
      throw WorkerError.permanent("Couldn't write the file: \(error.localizedDescription)")
    }
    segment.next += Int64(chunk.count)
    record.segments[index] = segment
    stats.receivedBytes += Int64(chunk.count)
    return !segment.isDone
  }

  /// After the first `206`: split what is left of the file into up to
  /// `maxConnections` segments of at least `minSegmentSize`. The first keeps
  /// its running connection; the others get their own.
  private func splitFirstSegment() {
    guard let total = record.totalBytes else { return }
    let from = record.segments[0].next
    let left = total - from
    let count = Int(max(1, min(Int64(maxConnections), left / minSegmentSize)))
    guard count > 1 else { return }
    let start = record.segments[0].start
    record.segments = (0..<count).map { part in
      let partStart = from + left * Int64(part) / Int64(count)
      let partEnd = from + left * Int64(part + 1) / Int64(count)
      return part == 0 ? .init(start: start, next: from, end: partEnd) : .init(start: partStart, end: partEnd)
    }
    for part in 1..<count { spawnWorker(part) }
  }

  /// A connection finished its segment: give it an unfinished segment no one
  /// is fetching, or else the second half of the running segment with the
  /// most left, if that is worth a new request. Returns the segment's index.
  private func nextSegment() -> Int? {
    guard record.acceptsRanges else { return nil }
    if let orphan = record.segments.indices.first(where: {
      !owned.contains($0) && !record.segments[$0].isDone
    }) {
      return orphan
    }
    let candidates = record.segments.indices.compactMap { index in
      record.segments[index].remaining.map { (index: index, remaining: $0) }
    }
    guard let largest = candidates.max(by: { $0.remaining < $1.remaining }),
      largest.remaining >= 2 * minSegmentSize
    else { return nil }
    let segment = record.segments[largest.index]
    let middle = segment.next + largest.remaining / 2
    record.segments[largest.index].end = middle
    record.segments.append(.init(start: middle, end: segment.end))
    return record.segments.count - 1
  }

  // MARK: - Finishing

  private func finishIfDone() async {
    guard state == .downloading, activeWorkers == 0 else { return }
    guard !record.segments.isEmpty, record.segments.allSatisfy(\.isDone) else {
      // Every worker stopped with segments left (connections retired while
      // the last one was finishing): start them again.
      launchWorkers()
      return
    }
    statsTask?.cancel()
    statsTask = nil
    if let total = record.totalBytes { try? file?.truncate(atOffset: UInt64(total)) }
    closeFile()
    stats.downloadSpeed = 0
    stats.connections = 0
    stats.receivedBytes = record.receivedBytes
    emit(.stats(stats))
    saveRecord()

    if let checksum = record.checksum ?? record.serverChecksum, let fileURL {
      state = .verifying
      emit(.state(state))
      let actual = await Task.detached { try? checksum.digest(ofFileAt: fileURL) }.value
      guard state == .verifying else { return }
      guard actual == checksum.hex else {
        fail(
          "\(checksum.algorithm.rawValue) mismatch: expected \(checksum.hex), got \(actual ?? "nothing")")
        return
      }
      emit(.verified(checksum))
    }
    state = .completed
    emit(.state(state))
    streamer.invalidate()
    continuation.finish()
  }

  private func fail(_ message: String) {
    Self.log.error("\(self.record.url, privacy: .public) failed: \(message, privacy: .public)")
    stopWorkers()
    statsTask?.cancel()
    statsTask = nil
    saveRecord()
    state = .failed(message)
    emit(.state(state))
  }

  // MARK: - Stats

  private func statsLoop() async {
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(1))
      if Task.isCancelled || state != .downloading { continue }
      stats.downloadSpeed = speedMeter.record(totalBytes: stats.receivedBytes)
      emit(.stats(stats))
      ticks += 1
      if ticks % 5 == 0 { saveRecord() }
    }
  }

  // MARK: - Files

  private func openFile() throws {
    guard file == nil, let fileURL else { return }
    do {
      try FileManager.default.createDirectory(
        at: saveDirectory, withIntermediateDirectories: true)
      if !FileManager.default.fileExists(atPath: fileURL.path) {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
      }
      file = try FileHandle(forWritingTo: fileURL)
    } catch {
      throw WorkerError.permanent("Couldn't create the file: \(error.localizedDescription)")
    }
  }

  private func closeFile() {
    try? file?.close()
    file = nil
  }

  private func saveRecord() {
    guard let recordURL else { return }
    record.save(to: recordURL)
  }

  /// `name`, or `name (1).ext`, `name (2).ext`… so a new download never
  /// writes into an existing file.
  private func uniqueFilename(_ name: String) -> String {
    Self.uniqueName(name) { FileManager.default.fileExists(atPath: saveDirectory.appendingPathComponent($0).path) }
  }

  /// `name`, or the first `name (n).ext` for which `exists` is false.
  public static func uniqueName(_ name: String, exists: (String) -> Bool) -> String {
    guard exists(name) else { return name }
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var number = 1
    while true {
      let candidate = ext.isEmpty ? "\(base) (\(number))" : "\(base) (\(number)).\(ext)"
      if !exists(candidate) { return candidate }
      number += 1
    }
  }

  // MARK: - Response parsing

  /// `Content-Range: bytes <start>-<end>/<total or *>`.
  static func contentRange(_ response: HTTPURLResponse) -> (start: Int64, total: Int64?)? {
    guard let value = response.value(forHTTPHeaderField: "Content-Range"),
      value.lowercased().hasPrefix("bytes ")
    else { return nil }
    let spec = value.dropFirst(6)
    let parts = spec.split(separator: "/", maxSplits: 1)
    guard parts.count == 2, let dash = parts[0].firstIndex(of: "-"),
      let start = Int64(parts[0][..<dash].trimmingCharacters(in: .whitespaces))
    else { return nil }
    return (start, Int64(parts[1].trimmingCharacters(in: .whitespaces)))
  }

  /// `Retry-After` in seconds (the HTTP-date form is ignored).
  static func retryAfter(_ response: HTTPURLResponse) -> Duration? {
    response.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }.map { .seconds($0) }
  }

  /// A validator usable in `If-Range`: a strong ETag, else Last-Modified.
  static func validator(_ response: HTTPURLResponse) -> String? {
    if let etag = response.value(forHTTPHeaderField: "ETag"), !etag.hasPrefix("W/") { return etag }
    return response.value(forHTTPHeaderField: "Last-Modified")
  }

  /// The file name from Content-Disposition, else the URL's last path
  /// component, made safe to use as a single file name.
  static func filename(_ response: HTTPURLResponse, url: URL) -> String {
    var name = response.suggestedFilename ?? ""
    if name.isEmpty || name == "Unknown" { name = url.lastPathComponent }
    name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    name = name.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    return name.isEmpty ? "download" : name
  }

  private static func status(_ response: HTTPURLResponse) -> String {
    "HTTP \(response.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode).capitalized)"
  }

  private static func describe(_ error: Error) -> String {
    if case WorkerError.truncated = error { return "The server closed the connection early" }
    return error.localizedDescription
  }

  private func emit(_ event: URLDownloadEvent) { continuation.yield(event) }
}
