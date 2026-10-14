import Foundation
import Torrent

/// Debug builds: `--screenshot-demo` fills the list with made-up downloads for the screenshots
/// (`.dev/screenshots.json`). They are fixed states, not sessions: nothing connects to a tracker, a peer or a server,
/// and the user's own downloads aren't restored. The Download from URL sheet shows a demo link instead of the
/// clipboard.
///
///   --screenshot-demo        the demo list
///   --select <title>         shows that download
///   --add-url                opens the Download from URL sheet
enum ScreenshotDemo {
  static let isOn: Bool = {
    #if DEBUG
      CommandLine.arguments.contains("--screenshot-demo")
    #else
      false
    #endif
  }()

  static func value(_ option: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
  }

  static func flag(_ option: String) -> Bool { isOn && CommandLine.arguments.contains(option) }

  typealias Item = DownloadStore.DownloadItem
  typealias File = DownloadStore.DownloadFileItem

  private static let gigabyte: Int64 = 1_000_000_000

  @MainActor static var items: [Item] {
    var ubuntu = Item(id: "demo-ubuntu", title: "ubuntu-26.04-desktop-amd64.iso")
    ubuntu.state = .downloading
    ubuntu.progress = 0.62
    ubuntu.speed = "18.4 MB/s"
    ubuntu.peers = 47
    ubuntu.seeders = 31
    ubuntu.trackerSeeders = 2_814
    ubuntu.trackerLeechers = 196
    ubuntu.files = [File(index: 0, path: "ubuntu-26.04-desktop-amd64.iso", length: 6 * gigabyte, verifiedBytes: 3_720_000_000, sequentialBytes: 3_100_000_000)]
    ubuntu.fileOrder = [0]

    var photos = Item(id: "demo-photos", title: "Open Photo Archive 2026")
    photos.state = .downloading
    photos.progress = 0.38
    photos.speed = "6.1 MB/s"
    photos.peers = 12
    photos.seeders = 5
    photos.isSingleFile = false
    let names = [
      "01 Lisbon/IMG_0412.heic", "01 Lisbon/IMG_0418.heic", "01 Lisbon/IMG_0433.heic", "02 Sintra/IMG_0501.heic",
      "02 Sintra/IMG_0517.heic", "03 Porto/IMG_0602.heic", "03 Porto/IMG_0610.heic", "README.txt",
    ]
    photos.files = names.enumerated().map { index, name in
      let length: Int64 = name.hasSuffix(".txt") ? 2_400 : 4_800_000 + Int64(index) * 310_000
      let done: Int64 = index < 3 ? length : index == 3 ? length / 2 : 0
      return File(index: index, path: name, length: length, verifiedBytes: done, sequentialBytes: done, priority: index == 4 ? 1 : 0)
    }
    photos.fileOrder = Array(names.indices)

    var debian = Item(id: "demo-debian", title: "debian-13.6.0-amd64-netinst.iso")
    debian.state = .completed
    debian.progress = 1
    debian.files = [File(index: 0, path: "debian-13.6.0-amd64-netinst.iso", length: 784_000_000, verifiedBytes: 784_000_000, sequentialBytes: 784_000_000)]
    debian.fileOrder = [0]

    var font = Item(id: "url-demo-font", title: "Atkinson-Hyperlegible.zip")
    font.kind = .url
    font.state = .downloading
    font.progress = 0.81
    font.speed = "3.2 MB/s"
    font.sourceURL = URL(string: "https://downloads.example.com/fonts/Atkinson-Hyperlegible.zip")
    font.receivedBytes = 38_900_000
    font.totalBytes = 48_000_000
    font.connections = 4
    font.resumable = true

    var kali = Item(id: "demo-kali", title: "kali-linux-2026.2-installer-amd64.iso")
    kali.state = .paused
    kali.progress = 0.14
    kali.files = [File(index: 0, path: "kali-linux-2026.2-installer-amd64.iso", length: 4 * gigabyte, verifiedBytes: 560_000_000, sequentialBytes: 410_000_000)]
    kali.fileOrder = [0]

    return [ubuntu, photos, font, kali, debian]
  }
}
