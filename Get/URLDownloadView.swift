import ComponentKit
import SwiftUI
import Torrent
import URLDownload

/// Detail pane for a URL download: the transfer (progress, speed, connections, size) and the source (link, checksum,
/// resume), each a card whose header sums it up.
struct URLDownloadDetailView: View {
  let store: DownloadStore
  let itemID: String

  private var item: DownloadStore.DownloadItem {
    store.items.first { $0.id == itemID } ?? .init(id: itemID, title: "")
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        if let error = item.error {
          Banner(
            item.state.isFailed ? "Download failed" : "Connection trouble", message: error,
            systemImage: "exclamationmark.triangle", hue: item.state.isFailed ? .red : .orange
          ) {
            if item.state.isFailed { Button("Retry") { store.retry(itemID: itemID) } }
          }.textSelection(.enabled)
        }
        KitSection("Transfer", meta: transferMeta, systemImage: "arrow.down", status: item.workStatus) {
          InspectorRow("Status", copyText: nil) { Text(status).monospacedDigit() }
          InspectorRow("Size", copyText: nil) { Text(size).monospacedDigit() }
        }
        if let device = item.device {
          KitSection("On \(device)", meta: "over SSH through your Hub", systemImage: "point.3.connected.trianglepath.dotted", hue: .purple) {
            InspectorRow("Device", value: device, copyable: false)
            if let path = item.remotePath {
              InspectorRow("Saved as", value: path)
            } else {
              InspectorRow("Saving to", value: "Downloads on \(device)", copyable: false)
            }
          }
        }
        KitSection(
          "Source", meta: item.sourceURL?.host() ?? "", systemImage: "link", hue: .teal
        ) {
          if let source = item.sourceURL {
            InspectorRow("Source", value: source.absoluteString)
          }
          if let checksum = item.verifiedChecksum {
            InspectorRow("Checksum", copyText: nil) {
              Label("\(checksum.algorithm.rawValue) verified", systemImage: "checkmark.seal.fill")
                .foregroundStyle(Hue.green.text)
            }
          } else if let checksum = item.checksum {
            InspectorRow("Checksum", value: "\(checksum.algorithm.rawValue), checked when finished", copyable: false)
          }
          if item.device == nil, item.state == .downloading || item.state == .paused, item.totalBytes != nil {
            InspectorRow(
              "Resume", value: item.resumable ? "Continues after interruptions" : "The server can't resume; restarts",
              copyable: false)
          }
        }
      }.frame(maxWidth: 680).frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 20)
    }.kitPane(.secondary)
  }

  /// "Downloading · 4 connections · 3.2 MB/s", "Downloading on Mac Studio · 45%".
  private var status: String {
    if let device = item.device {
      return [item.state.label + " on \(device)", item.state == .downloading ? "\(Int(item.progress * 100))%" : ""]
        .filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var parts = [item.state.label]
    if item.state == .downloading, item.connections > 1 { parts.append("\(item.connections) connections") }
    if !item.speed.isEmpty { parts.append(item.speed) }
    return parts.joined(separator: " · ")
  }

  /// "38.9 MB of 48 MB", or what has arrived while the size is unknown.
  private var size: String {
    let received = item.receivedBytes.formatted(.byteCount(style: .file))
    guard let total = item.totalBytes else { return received }
    return "\(received) of \(total.formatted(.byteCount(style: .file)))"
  }

  /// "38.9 of 48 MB · 3.2 MB/s".
  private var transferMeta: [String] {
    [size, item.speed]
  }
}

/// Sheet for starting a URL download: the link, and an optional checksum to
/// verify the finished file against. Prefilled from the clipboard when it
/// holds a link.
struct URLDownloadSheet: View {
  /// The user's other devices it can download on instead (hosts via Hub): id and name.
  var devices: [(id: String, name: String)] = []
  /// The link, its checksum, and the device to download on (nil for this Mac).
  let onDownload: (URL, Checksum?, String?) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var link = ""
  @State private var checksumText = ""
  @State private var device = ""

  private var url: URL? { Self.parse(link) }
  private var checksum: Checksum? { Checksum(checksumText) }
  private var checksumInvalid: Bool {
    !checksumText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && checksum == nil
  }
  private var linkInvalid: Bool {
    !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && url == nil
  }

  var body: some View {
    KitSheet(
      title: "Download a Link",
      meta: "An http(s) or magnet link. With a checksum, the finished file is checked against it.",
      systemImage: "arrow.down", width: 480
    ) {
      FormCard {
        FormRow(
          "URL", systemImage: "link", hue: .blue, error: linkInvalid ? "Not an http(s) or magnet link" : nil,
          field: TextField("URL", text: $link, prompt: Text("https://example.com/file.zip")))
        FormRow(
          "Checksum", systemImage: "key", hue: .gray,
          error: checksumInvalid ? "Not a SHA-256, SHA-512, SHA-1 or MD5 checksum" : nil,
          field: TextField("Checksum", text: $checksumText, prompt: Text("Optional: SHA-256, SHA-1 or MD5"))
            .kitFont(.mono))
        if !devices.isEmpty {
          FormRow(
            "Download on", help: device.isEmpty ? nil : "Into its Downloads folder, over SSH through your Hub",
            systemImage: "point.3.connected.trianglepath.dotted", hue: .purple
          ) {
            KitPicker(
              "Download on", selection: $device,
              options: [("This \(KitDevice.name)", "")] + devices.map { ($0.name, $0.id) }
            ).fixedSize()
          }
        }
      }
    } footer: {
      SheetStatus(
        url.map(Self.name(of:)) ?? "Paste or type a link", systemImage: "doc",
        status: url == nil ? .idle : .done)
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("Download") {
        guard let url else { return }
        onDownload(url, checksum, device.isEmpty ? nil : device)
        dismiss()
      }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction).disabled(url == nil || checksumInvalid)
    }.onAppear {
      // The screenshot demo shows a link of its own, never the clipboard.
      if ScreenshotDemo.isOn {
        link = "https://downloads.example.com/fonts/Atkinson-Hyperlegible.zip"
        return
      }
      if link.isEmpty, let text = KitPasteboard.string(),
        Self.parse(text) != nil
      {
        link = text.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
  }

  /// What the link will be saved as: its last path component, or its host (a magnet's name when it has one).
  private static func name(of url: URL) -> String {
    if url.scheme?.lowercased() == "magnet" {
      let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "dn" }?.value
      return name ?? "Magnet link"
    }
    let last = url.lastPathComponent
    return last.isEmpty || last == "/" ? (url.host() ?? url.absoluteString) : last
  }

  /// An http(s) or magnet link from typed or pasted text.
  static func parse(_ text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return nil }
    switch scheme {
    case "http", "https": return url.host() == nil ? nil : url
    case "magnet": return url
    default: return nil
    }
  }
}
