import CryptoKit
import Foundation
import Testing

@testable import URLDownload

// MARK: - Helpers

private func randomData(_ count: Int) -> Data {
  Data((0..<count).map { _ in UInt8.random(in: 0...255) })
}

private func makeTempDir() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "url-download-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func sha256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Everything a session reported, collected until its stream ends or it
/// settles in a final state.
private struct Run {
  var states: [URLDownloadState] = []
  var file: URL?
  var verified: Checksum?
  var lastStats: URLDownloadStats?
  var finalState: URLDownloadState? { states.last }
}

private func makeSession(
  _ record: URLDownloadRecord, dir: URL, recordURL: URL? = nil, connections: Int = 4,
  minSegment: Int64 = 64 * 1024
) -> URLDownloadSession {
  URLDownloadSession(
    record: record, saveDirectory: dir, recordURL: recordURL, maxConnections: connections,
    minSegmentSize: minSegment, configuration: MockHTTP.configuration(),
    retryDelay: .milliseconds(5), maxRetries: 3)
}

private func run(_ session: URLDownloadSession) async -> Run {
  let events = await session.events
  await session.start()
  var run = Run()
  for await event in events {
    switch event {
    case .state(let state):
      run.states.append(state)
      if case .failed = state { return run }
    case .file(let url): run.file = url
    case .verified(let checksum): run.verified = checksum
    case .stats(let stats): run.lastStats = stats
    case .error: break
    }
  }
  return run
}

private func rangeHeaders(_ path: String) -> [String] {
  MockHTTP.requests(for: path).compactMap { $0.value(forHTTPHeaderField: "Range") }
}

// MARK: - Downloads

@Test func downloadsInParallelSegments() async throws {
  let dir = try makeTempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let data = randomData(1_000_000)
  let url = MockHTTP.serve(.init(data: data), at: "segments/file.bin")

  let result = await run(makeSession(.init(url: url), dir: dir))

  #expect(result.finalState == .completed)
  #expect(result.file == dir.appendingPathComponent("file.bin"))
  #expect(try Data(contentsOf: dir.appendingPathComponent("file.bin")) == data)
  // The probe, then three more segment requests (4 connections) at least.
  let ranges = rangeHeaders("segments/file.bin")
  #expect(ranges.first == "bytes=0-")
  #expect(ranges.count >= 4)
  #expect(result.lastStats?.resumable == true)
  #expect(result.lastStats?.receivedBytes == Int64(data.count))
}

@Test func downloadsFromServerWithoutRanges() async throws {
  let dir = try makeTempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let data = randomData(300_000)
  let url = MockHTTP.serve(.init(data: data, acceptsRanges: false), at: "noranges/a.zip")

  let result = await run(makeSession(.init(url: url), dir: dir))

  #expect(result.finalState == .completed)
  #expect(try Data(contentsOf: dir.appendingPathComponent("a.zip")) == data)
  #expect(MockHTTP.requests(for: "noranges/a.zip").count == 1)
  #expect(result.lastStats?.resumable == false)
}

@Test func resumesDroppedConnectionsFromWhereTheyStopped() async throws {
  let dir = try makeTempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let data = randomData(200_000)
  let url = MockHTTP.serve(
    .init(data: data, failAfter: 50_000, failures: 2), at: "drop/file.bin")

  let result = await run(makeSession(.init(url: url), dir: dir, connections: 1))

  #expect(result.finalState == .completed)
  #expect(try Data(contentsOf: dir.appendingPathComponent("file.bin")) == data)
  #expect(rangeHeaders("drop/file.bin") == ["bytes=0-", "bytes=50000-199999", "bytes=100000-199999"])
}

@Test func restartsWithoutRangesAfterADroppedConnection() async throws {
  let dir = try makeTempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let data = randomData(100_000)
  let url = MockHTTP.serve(
    .init(data: data, acceptsRanges: false, failAfter: 30_000, failures: 1), at: "droprestart/f")

  let result = await run(makeSession(.init(url: url), dir: dir))

  #expect(result.finalState == .completed)
  #expect(try Data(contentsOf: dir.appendingPathComponent("f")) == data)
}

@Test func continuesASavedDownloadWithIfRange() async throws {
  let dir = try makeTempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let data = randomData(400_000)
  let url = MockHTTP.serve(.init(data: data), at: "saved/file.bin")

  // A previous run got the first 100 KB of each half.
  var record = URLDownloadRecord(url: url)
  record.filename = "file.bin"
  record.totalBytes = 400_000
  record.validator = "\"v1\""
  record.acceptsRanges = true
  record.segments = [
    .init(start: 0, next: 100_000, end: 200_000), .init(start: 200_000, next: 300_000, end: 400_000),
  ]
  var partial = Data(count: 400_000)
  partial.replaceSubrange(0..<100_000, with: data[0..<100_000])
  partial.replaceSubrange(200_000..<300_000, with: data[200_000..<300_000])
  try partial.write(to: dir.appendingPathComponent("file.bin"))

  let result = await run(makeSession(record, dir: dir, minSegment: 1_000_000))

  #expect(result.finalState == .completed)
  #expect(try Data(contentsOf: dir.appendingPathComponent("file.bin")) == data)
  #expect(Set(rangeHeaders("saved/file.bin")) == ["bytes=100000-199999", "bytes=300000-399999"])
  #expect(
    MockHTTP.requests(for: "saved/file.bin").allSatisfy {
      $0.value(forHTTPHeaderField: "If-Range") == "\"v1\""
    })
}

@Test func restartsWhenTheFileChangedOnTheServer() async throws {
  let dir = try makeTempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let data = randomData(150_000)
  let url = MockHTTP.serve(.init(data: data, etag: "\"v2\""), at: "changed/file.bin")

  var record = URLDownloadRecord(url: url)
  record.filename = "file.bin"
  record.totalBytes = 150_000
  record.validator = "\"v1\""
  record.acceptsRanges = true
  record.segments = [.init(start: 0, next: 50_000, end: 150_000)]
  try randomData(50_000).write(to: dir.appendingPathComponent("file.bin"))

  let result = await run(makeSession(record, dir: dir, minSegment: 1_000_000))

  #expect(result.finalState == .completed)
  #expect(try Data(contentsOf: dir.appendingPathComponent("file.bin")) == data)
  #expect(rangeHeaders("changed/file.bin") == ["bytes=50000-149999", "bytes=0-"])
}

@Test func savesProgressSoARelaunchCanContinue() async throws {
  let dir = try makeTempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let recordURL = dir.appendingPathComponent("state/record.json")
  let data = randomData(100_000)
  let url = MockHTTP.serve(.init(data: data, status: 503), at: "record/file.bin")

  let session = makeSession(.init(url: url), dir: dir, recordURL: recordURL)
  let result = await run(session)
  if case .failed = result.finalState {} else { Issue.record("expected failure, got \(result.states)") }
  #expect(URLDownloadRecord.load(from: recordURL)?.url == url)

  // The server recovers; a new session from the saved record finishes.
  MockHTTP.update("record/file.bin") { $0.status = nil }
  let saved = try #require(URLDownloadRecord.load(from: recordURL))
  let second = await run(makeSession(saved, dir: dir, recordURL: recordURL))
  #expect(second.finalState == .completed)
  #expect(try Data(contentsOf: dir.appendingPathComponent("file.bin")) == data)
}

@Test func failsOnNotFound() async throws {
  let dir = try makeTempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let result = await run(
    makeSession(.init(url: URL(string: "https://mock.test/missing/nothing")!), dir: dir))
  #expect(result.finalState == .failed("HTTP 404 Not Found"))
  #expect(MockHTTP.requests(for: "missing/nothing").count == 1)
}

@Test func namesTheFileFromContentDispositionWithoutOverwriting() async throws {
  let dir = try makeTempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  try Data("existing".utf8).write(to: dir.appendingPathComponent("report.pdf"))
  let data = randomData(10_000)
  let url = MockHTTP.serve(
    .init(data: data, headers: ["Content-Disposition": "attachment; filename=\"report.pdf\""]),
    at: "named/download")

  let result = await run(makeSession(.init(url: url), dir: dir))

  #expect(result.file == dir.appendingPathComponent("report (1).pdf"))
  #expect(try Data(contentsOf: dir.appendingPathComponent("report (1).pdf")) == data)
  #expect(try Data(contentsOf: dir.appendingPathComponent("report.pdf")) == Data("existing".utf8))
}

// MARK: - Checksums

@Test func verifiesTheChecksumTheUserGave() async throws {
  let dir = try makeTempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let data = randomData(250_000)
  let url = MockHTTP.serve(.init(data: data), at: "checksum/good.iso")
  let checksum = try #require(Checksum(sha256(data)))

  let result = await run(makeSession(.init(url: url, checksum: checksum), dir: dir))

  #expect(result.states.contains(.verifying))
  #expect(result.finalState == .completed)
  #expect(result.verified == checksum)
}

@Test func failsOnAChecksumMismatch() async throws {
  let dir = try makeTempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let url = MockHTTP.serve(.init(data: randomData(20_000)), at: "checksum/bad.iso")
  let checksum = Checksum(algorithm: .sha256, hex: String(repeating: "0", count: 64))

  let result = await run(makeSession(.init(url: url, checksum: checksum), dir: dir))

  guard case .failed(let message) = result.finalState else {
    Issue.record("expected failure, got \(result.states)")
    return
  }
  #expect(message.hasPrefix("SHA-256 mismatch"))
}

@Test func verifiesTheServersReprDigest() async throws {
  let dir = try makeTempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let data = randomData(30_000)
  let digest = Data(SHA256.hash(data: data)).base64EncodedString()
  let url = MockHTTP.serve(
    .init(data: data, headers: ["Repr-Digest": "sha-256=:\(digest):"]), at: "checksum/server.bin")

  let result = await run(makeSession(.init(url: url), dir: dir))

  #expect(result.finalState == .completed)
  #expect(result.verified == Checksum(sha256(data)))
}

@Test func parsesPastedChecksums() {
  let hex = String(repeating: "ab", count: 32)
  #expect(Checksum(hex)?.algorithm == .sha256)
  #expect(Checksum("\(hex)  ubuntu.iso")?.hex == hex)
  #expect(Checksum("SHA256 (ubuntu.iso) = \(hex.uppercased())")?.hex == hex)
  #expect(Checksum(String(repeating: "0", count: 32))?.algorithm == .md5)
  #expect(Checksum(String(repeating: "0", count: 40))?.algorithm == .sha1)
  #expect(Checksum(String(repeating: "0", count: 128))?.algorithm == .sha512)
  #expect(Checksum("not a checksum") == nil)
  #expect(Checksum(String(repeating: "z", count: 64)) == nil)
}

@Test func parsesDigestHeaders() {
  let sha256 = Data(repeating: 1, count: 32).base64EncodedString()
  let md5 = Data(repeating: 2, count: 16).base64EncodedString()
  #expect(Checksum(digestHeader: "sha-256=:\(sha256):")?.algorithm == .sha256)
  #expect(Checksum(digestHeader: "MD5=\(md5), SHA-256=\(sha256)")?.algorithm == .sha256)
  #expect(Checksum(digestHeader: "MD5=\(md5)")?.hex == String(repeating: "02", count: 16))
  #expect(Checksum(digestHeader: "unixsum=30637") == nil)
}

@Test func uniqueNamesNumberBeforeTheExtension() {
  let taken: Set = ["a.zip", "a (1).zip", "README"]
  #expect(URLDownloadSession.uniqueName("a.zip") { taken.contains($0) } == "a (2).zip")
  #expect(URLDownloadSession.uniqueName("README") { taken.contains($0) } == "README (1)")
  #expect(URLDownloadSession.uniqueName("new.txt") { taken.contains($0) } == "new.txt")
}
