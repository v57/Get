import Foundation

/// A link downloaded on another device (Download on…): the shell command that fetches it there with `curl` (or
/// `wget`) into that device's `~/Downloads`, and the parser that turns what the command prints into progress, the
/// saved file and its checksum. How the command reaches the device (SSH, a Hub runner) is up to the app.
///
/// The file arrives as `<name>.get-part` and is renamed once complete, to `<name>`, or `<name> (2)` when that is
/// taken, so a half-fetched file never looks finished. A partial file left by an earlier attempt is continued.
public struct RemoteDownload: Sendable, Equatable {
  public var url: URL
  /// The file name it is saved as.
  public var fileName: String
  /// Checked on the device once the file is complete (its digest comes back as `.checksum`).
  public var checksum: Checksum?

  public init(url: URL, fileName: String? = nil, checksum: Checksum? = nil) {
    self.url = url
    self.fileName = Self.safeName(fileName ?? Self.name(of: url))
    self.checksum = checksum
  }

  /// What the command prints that the app acts on.
  public enum Event: Sendable, Equatable {
    /// 0…1 of the transfer.
    case progress(Double)
    /// The finished file's path on the device.
    case saved(path: String)
    /// The finished file's digest (lowercase hex), in the checksum's algorithm.
    case checksum(String)
    /// Why it couldn't run there.
    case failed(String)
  }

  /// The command for the device's login shell: a POSIX `sh` script, whatever shell the user has there.
  public var command: String {
    var script = """
      d="$HOME/Downloads"; mkdir -p "$d" && cd "$d" || exit 1
      n=\(Self.quoted(fileName)); p="$n.get-part"
      if command -v curl >/dev/null 2>&1; then curl -fL --retry 3 -C - -# -o "$p" \(Self.quoted(url.absoluteString)) || exit $?
      elif command -v wget >/dev/null 2>&1; then wget -c --progress=bar:force -O "$p" \(Self.quoted(url.absoluteString)) || exit $?
      else echo "GET-ERROR:Neither curl nor wget is installed there."; exit 127; fi
      case "$n" in *.*) s="${n%.*}"; e=".${n##*.}";; *) s="$n"; e="";; esac
      f="$n"; i=2; while [ -e "$f" ]; do f="$s ($i)$e"; i=$((i+1)); done
      mv "$p" "$f" || exit 1

      """
    if let checksum {
      script += "h=$(\(Self.digestCommand(checksum.algorithm)) | cut -d' ' -f1); echo \"GET-SUM:$h\"\n"
    }
    script += "printf 'GET-SAVED:%s\\n' \"$d/$f\"\n"
    return "sh -c \(Self.quoted(script))"
  }

  /// Reads the command's output as it arrives.
  public struct Parser: Sendable {
    private var pending = ""

    public init() {}

    /// The events in `data`. Progress bars redraw with carriage returns, so pieces between `\r` and `\n` are read
    /// one by one; only the latest progress of a chunk is reported.
    public mutating func consume(_ data: Data) -> [Event] {
      pending += String(decoding: data, as: UTF8.self)
      var events: [Event] = []
      var latest: Double?
      while let end = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
        let line = String(pending[..<end]).trimmingCharacters(in: .whitespaces)
        pending.removeSubrange(...end)
        if let event = Self.marker(line) {
          events.append(event)
        } else if let fraction = Self.percent(line) {
          latest = fraction
        }
      }
      // A bar still being drawn on the current line.
      if let fraction = Self.percent(pending) { latest = fraction }
      if let latest { events.insert(.progress(latest), at: 0) }
      return events
    }

    static func marker(_ line: String) -> Event? {
      if line.hasPrefix("GET-SAVED:") { return .saved(path: String(line.dropFirst(10))) }
      if line.hasPrefix("GET-SUM:") { return .checksum(String(line.dropFirst(8)).lowercased()) }
      if line.hasPrefix("GET-ERROR:") { return .failed(String(line.dropFirst(10))) }
      if line.hasPrefix("curl: (") { return .failed(line) }
      return nil
    }

    /// The last "45.2%" in a line, as 0…1.
    static func percent(_ line: String) -> Double? {
      guard let sign = line.lastIndex(of: "%") else { return nil }
      let digits = line[..<sign].reversed().prefix { $0.isNumber || $0 == "." || $0 == "," }
      guard let value = Double(String(digits.reversed()).replacingOccurrences(of: ",", with: ".")), value <= 100
      else { return nil }
      return value / 100
    }
  }

  // MARK: Helpers

  /// The link's last path component, or its host.
  public static func name(of url: URL) -> String {
    let last = url.lastPathComponent
    return last.isEmpty || last == "/" ? (url.host() ?? "download") : last
  }

  /// A name that stays one file in `~/Downloads`: no folders, no hidden or empty name.
  static func safeName(_ name: String) -> String {
    var name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\0", with: "")
    while name.hasPrefix(".") { name.removeFirst() }
    return name.isEmpty ? "download" : name
  }

  static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

  /// The digest tool on macOS (shasum, md5) or Linux (sha*sum, md5sum), whichever is there.
  static func digestCommand(_ algorithm: Checksum.Algorithm) -> String {
    switch algorithm {
    case .md5: "{ md5sum \"$f\" 2>/dev/null || md5 -r \"$f\"; }"
    case .sha1: "{ shasum -a 1 \"$f\" 2>/dev/null || sha1sum \"$f\"; }"
    case .sha256: "{ shasum -a 256 \"$f\" 2>/dev/null || sha256sum \"$f\"; }"
    case .sha512: "{ shasum -a 512 \"$f\" 2>/dev/null || sha512sum \"$f\"; }"
    }
  }
}
