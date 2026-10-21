import CryptoKit
import Foundation
import Testing

@testable import URLDownload

@Suite struct RemoteDownloadTests {
  @Test func parsesProgressMarkersAndErrors() {
    var parser = RemoteDownload.Parser()
    #expect(parser.consume(Data("\r###        12.5%\r########    40.0%".utf8)) == [.progress(0.4)])
    #expect(parser.consume(Data("\r#### 100.0%\nGET-SUM:ABCD\nGET-SAVED:/Users/me/Downloads/a (2).zip\n".utf8)) == [
      .progress(1), .checksum("abcd"), .saved(path: "/Users/me/Downloads/a (2).zip"),
    ])
    #expect(parser.consume(Data("curl: (22) The requested URL returned error: 404\r\n".utf8)) == [
      .failed("curl: (22) The requested URL returned error: 404")
    ])
    // A marker split across chunks.
    #expect(parser.consume(Data("GET-SAV".utf8)) == [])
    #expect(parser.consume(Data("ED:/x\n".utf8)) == [.saved(path: "/x")])
  }

  @Test func namesStayOneFile() {
    #expect(RemoteDownload(url: URL(string: "https://example.com/a/b.zip")!).fileName == "b.zip")
    #expect(RemoteDownload(url: URL(string: "https://example.com/")!).fileName == "example.com")
    #expect(RemoteDownload(url: URL(string: "https://example.com/x")!, fileName: "../.hidden/x").fileName == "-.hidden-x")
  }

  /// The command itself, run here with `HOME` in a temporary folder and a file:// link (curl reads those): the
  /// file arrives under its name, a second one beside it, and the checksum comes back.
  @Test func theCommandDownloadsRenamesAndChecks() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("remote-\(UUID().uuidString)")
    let source = home.appendingPathComponent("source it's.bin")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let bytes = Data((0..<300_000).map { UInt8($0 % 251) })
    try bytes.write(to: source)
    let hex = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let download = RemoteDownload(
      url: source, fileName: "file.bin", checksum: Checksum(algorithm: .sha256, hex: hex))

    func run() throws -> [RemoteDownload.Event] {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/zsh")
      process.arguments = ["-c", download.command]
      process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = pipe
      try process.run()
      let output = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      #expect(process.terminationStatus == 0)
      var parser = RemoteDownload.Parser()
      return parser.consume(output + Data("\n".utf8))
    }
    let first = try run()
    #expect(first.contains(.checksum(hex)))
    #expect(first.contains(.saved(path: home.path + "/Downloads/file.bin")))
    let second = try run()
    #expect(second.contains(.saved(path: home.path + "/Downloads/file (2).bin")))
    #expect(try Data(contentsOf: home.appendingPathComponent("Downloads/file (2).bin")) == bytes)
    #expect(!FileManager.default.fileExists(atPath: home.path + "/Downloads/file.bin.get-part"))
  }
}
