import Foundation
import Torrent
import URLDownload

/// Debug builds: `--screenshot-demo` fills the list with made-up downloads for the screenshots
/// (`.dev/screenshots.json`). They are fixed states, not sessions: nothing connects to a tracker, a peer or a server,
/// and the user's own downloads aren't restored. The Download from URL sheet shows a demo link instead of the
/// clipboard.
///
///   --screenshot-demo        the demo list
///   --select <title>         shows that download
///   --add-url                opens the Download from URL sheet, filled in to download the Fedora image on home-nas
///                            (the list without it)
///   --device <state>         the Fedora image on home-nas: downloading (the default), completed or failed
///
/// A capture by `dev-screenshots` takes every scene in one launch: `TorrentView` opens each next scene from its
/// arguments through `DevScreenshots`.
enum ScreenshotDemo {
  static let isOn: Bool = {
    #if DEBUG
      CommandLine.arguments.contains("--screenshot-demo")
    #else
      false
    #endif
  }()

  /// The argument after `option`, from the launch or from a later scene's arguments.
  static func value(_ option: String, in arguments: [String] = CommandLine.arguments) -> String? {
    guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
  }

  static func flag(_ option: String, in arguments: [String] = CommandLine.arguments) -> Bool {
    isOn && arguments.contains(option)
  }

  typealias Item = DownloadStore.DownloadItem
  typealias File = DownloadStore.DownloadFileItem

  private static let gigabyte: Int64 = 1_000_000_000

  /// Two of the user's devices to download on.
  static let devices = [(id: "demo-gaming-pc", name: "gaming-pc"), (id: "demo-home-nas", name: "home-nas")]

  static let fedoraURL = "https://downloads.example.com/fedora/44/Fedora-Workstation-Live-44.iso"
  static let fedoraChecksum = "7f3c2a91d84e6b05c1f9e27a4d6038b5e1c94f72a0b8d3e65f17c2049ab8e3d1"

  /// The demo list for a scene's arguments.
  @MainActor static func items(_ arguments: [String]) -> [Item] {
    var ubuntu = Item(id: "demo-ubuntu", title: "ubuntu-26.04-desktop-amd64.iso")
    ubuntu.state = .downloading
    ubuntu.progress = 0.62
    ubuntu.bytesPerSecond = 18.4 * 1_048_576
    ubuntu.remaining = 130
    ubuntu.peers = 47
    ubuntu.seeders = 31
    ubuntu.trackerSeeders = 2_814
    ubuntu.trackerLeechers = 196
    ubuntu.files = [File(index: 0, path: "ubuntu-26.04-desktop-amd64.iso", length: 6 * gigabyte, verifiedBytes: 3_720_000_000, sequentialBytes: 3_100_000_000)]
    ubuntu.fileOrder = [0]

    var photos = Item(id: "demo-photos", title: "Open Photo Archive 2026")
    photos.state = .downloading
    photos.progress = 0.38
    photos.bytesPerSecond = 6.1 * 1_048_576
    photos.remaining = 70
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
    font.bytesPerSecond = 3.2 * 1_048_576
    font.remaining = 3
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

    let items = [ubuntu, photos, font, kali, debian]
    if flag("--add-url", in: arguments) { return items }
    return items + [fedora(value("--device", in: arguments) ?? "downloading")]
  }

  /// The Fedora image downloading on home-nas, or done there, or failed.
  private static func fedora(_ state: String) -> Item {
    var fedora = Item(id: "remote-demo-fedora", title: "Fedora-Workstation-Live-44.iso")
    fedora.kind = .url
    fedora.device = "home-nas"
    fedora.sourceURL = URL(string: fedoraURL)
    fedora.checksum = Checksum(fedoraChecksum)
    switch state {
    case "completed":
      fedora.state = .completed
      fedora.progress = 1
      fedora.remotePath = "/home/maya/Downloads/Fedora-Workstation-Live-44.iso"
      fedora.verifiedChecksum = fedora.checksum
    case "failed":
      let message = "curl: (22) The requested URL returned error: 404"
      fedora.state = .failed(message)
      fedora.error = message
    default:
      fedora.state = .downloading
      fedora.progress = 0.45
    }
    return fedora
  }
}
