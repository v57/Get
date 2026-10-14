import AppKit
import SwiftUI
import Torrent
import URLDownload

/// Detail pane for a URL download: progress, speed, connections, source and
/// checksum.
struct URLDownloadDetailView: View {
  let store: DownloadStore
  let itemID: String

  private var item: DownloadStore.DownloadItem {
    store.items.first { $0.id == itemID } ?? .init(id: itemID, title: "")
  }

  var body: some View {
    Form {
      Section {
        LabeledContent("Status") {
          HStack(spacing: 4) {
            Text(item.state.label)
            if item.state == .downloading, item.connections > 1 {
              Text("· \(item.connections) connections")
            }
            if !item.speed.isEmpty { Text("· \(item.speed)") }
          }.monospacedDigit()
        }
        LabeledContent("Size") {
          if let total = item.totalBytes {
            Text(
              "\(Text(item.receivedBytes, format: .byteCount(style: .file))) of \(Text(total, format: .byteCount(style: .file)))"
            ).monospacedDigit()
          } else {
            Text(item.receivedBytes, format: .byteCount(style: .file)).monospacedDigit()
          }
        }
        if item.totalBytes != nil {
          ProgressView(value: item.progress)
        } else if item.state == .downloading {
          ProgressView().progressViewStyle(.linear)
        }
        if let error = item.error {
          Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
        }
      }
      Section {
        if let source = item.sourceURL {
          LabeledContent("Source") {
            Text(source.absoluteString).lineLimit(3).truncationMode(.middle)
              .textSelection(.enabled)
          }
        }
        if let checksum = item.verifiedChecksum {
          LabeledContent("Checksum") {
            Label("\(checksum.algorithm.rawValue) verified", systemImage: "checkmark.seal.fill")
              .foregroundStyle(.green)
          }
        } else if let checksum = item.checksum {
          LabeledContent("Checksum") {
            Text("\(checksum.algorithm.rawValue), checked when finished")
          }
        }
        if item.state == .downloading || item.state == .paused, item.totalBytes != nil {
          LabeledContent("Resume") {
            Text(item.resumable ? "Continues after interruptions" : "The server can't resume; restarts")
          }
        }
      }
    }.formStyle(.grouped).navigationTitle(item.title).toolbar {
      LocationToolbar(store: store, item: item)
      ToolbarItem(placement: .automatic) {
        switch item.state {
        case .downloading, .paused:
          Button {
            store.togglePause(itemID: itemID)
          } label: {
            Label(
              item.state == .paused ? "Resume" : "Pause",
              systemImage: item.state == .paused ? "play.fill" : "pause.fill")
          }.help(item.state == .paused ? "Resume" : "Pause")
        case .failed:
          Button {
            store.retry(itemID: itemID)
          } label: {
            Label("Retry", systemImage: "arrow.clockwise")
          }.help("Try again from where it stopped")
        default:
          EmptyView()
        }
      }
      ToolbarItem(placement: .automatic) {
        if item.state != .stopped && item.state != .completed {
          Button("Cancel", role: .destructive) { store.cancel(itemID: itemID) }
        }
      }
      ToolbarItem(placement: .automatic) {
        Button {
          Task { await store.trash(itemID: itemID) }
        } label: {
          Image(systemName: "trash")
        }.help("Move download to Trash")
      }
    }
  }
}

/// Sheet for starting a URL download: the link, and an optional checksum to
/// verify the finished file against. Prefilled from the clipboard when it
/// holds a link.
struct URLDownloadSheet: View {
  let onDownload: (URL, Checksum?) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var link = ""
  @State private var checksumText = ""

  private var url: URL? { Self.parse(link) }
  private var checksum: Checksum? { Checksum(checksumText) }
  private var checksumInvalid: Bool {
    !checksumText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && checksum == nil
  }

  var body: some View {
    Form {
      TextField("URL", text: $link, prompt: Text("https://example.com/file.zip"))
      TextField("Checksum", text: $checksumText, prompt: Text("Optional: SHA-256, SHA-1 or MD5"))
      if checksumInvalid {
        Text("Not a SHA-256, SHA-512, SHA-1 or MD5 checksum.").font(.caption)
          .foregroundStyle(.red)
      }
    }.formStyle(.grouped).frame(width: 480).fixedSize(horizontal: false, vertical: true).toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("Download") {
          guard let url else { return }
          onDownload(url, checksum)
          dismiss()
        }.disabled(url == nil || checksumInvalid)
      }
    }.onAppear {
      // The screenshot demo shows a link of its own, never the clipboard.
      if ScreenshotDemo.isOn {
        link = "https://downloads.example.com/fonts/Atkinson-Hyperlegible.zip"
        return
      }
      if link.isEmpty, let text = NSPasteboard.general.string(forType: .string),
        Self.parse(text) != nil
      {
        link = text.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
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
