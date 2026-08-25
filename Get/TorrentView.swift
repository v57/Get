import SwiftUI
import Torrent
import UniformTypeIdentifiers

/// The main window: downloads in the sidebar, details for the selected one
/// in the detail pane. Torrent details show the file list with per-file
/// progress, plus a priority mode that assigns download order 1–4.
struct TorrentView: View {
  @State private var store = DownloadStore()
  @State private var showImporter = false
  @State private var selectedID: String?
  @State private var isDropTargeted = false

  var body: some View {
    NavigationSplitView {
      sidebar.navigationSplitViewColumnWidth(min: 200, ideal: 240).tint(.red)
    } detail: {
      if let id = selectedID, let item = store.items.first(where: { $0.id == id }) {
        TorrentDetailView(store: store, itemID: item.id)
      } else {
        ContentUnavailableView(
          "Select a Download", systemImage: "arrow.down.circle",
          description: Text("Choose a download from the sidebar."))
      }
    }.contentTransition(.symbolEffect).overlay {
      if isDropTargeted {
        RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 2).padding(6)
          .overlay {
            Text("Drop to download").font(.headline).padding(10).background(
              .regularMaterial, in: RoundedRectangle(cornerRadius: 8))
          }.allowsHitTesting(false)
      }
    }.onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
      handleDrop(providers)
      return true
    }.onAppear {
      // Hand the live store to the app delegate so "Open With…" events
      // reach it (and any queued from a cold start are drained).
      AppDelegate.attach(store: store)
    }.toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          showImporter = true
        } label: {
          Image(systemName: "plus")
        }.help("Open a .torrent file")
      }
    }.fileImporter(
      isPresented: $showImporter,
      allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data]
    ) { result in
      guard case .success(let url) = result else { return }
      Task { await store.open(url: url) }
    }.alert(
      "Couldn't Open Torrent",
      isPresented: Binding(
        get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })
    ) {
      Button("OK", role: .cancel) { store.lastError = nil }
    } message: {
      Text(store.lastError ?? "")
    }
  }

  /// Open every dropped file that is a `.torrent`. Non-torrent files are
  /// reported as an error so the drop isn't silently ignored.
  private func handleDrop(_ providers: [NSItemProvider]) {
    for provider in providers {
      // loadObject (not loadItem — deprecated in the macOS 27 SDK);
      // the completion's item is already URL?.
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        guard let url else { return }
        Task { @MainActor in
          guard url.pathExtension.lowercased() == "torrent" else {
            store.lastError = "Not a .torrent file: \(url.lastPathComponent)"
            return
          }
          await store.open(url: url)
        }
      }
    }
  }

  /// Sidebar: one row per download with title and progress.
  private var sidebar: some View {
    List(selection: $selectedID) {
      ForEach(store.items) { item in
        SidebarRow(
          item: item, onTogglePause: { store.togglePause(itemID: item.id) },
          onTrash: { Task { await store.trash(itemID: item.id) } }
        ).tag(item.id)
      }
    }.navigationTitle("Downloads").overlay {
      if store.items.isEmpty {
        ContentUnavailableView(
          "No Downloads", systemImage: "arrow.down.circle",
          description: Text("Click + to open a .torrent file."))
      }
    }
  }
}

/// Compact sidebar row: title, mini progress bar, state line, pause button.
private struct SidebarRow: View {
  let item: DownloadStore.DownloadItem
  let onTogglePause: () -> Void
  let onTrash: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 4) {
        Text(item.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        if item.state == .downloading || item.state == .paused {
          Button(action: onTogglePause) {
            Image(systemName: item.state == .paused ? "play.fill" : "pause.fill")
          }.buttonStyle(.borderless).help(item.state == .paused ? "Resume" : "Pause")
        }
      }
      ProgressView(value: item.progress).controlSize(.small)
      HStack(spacing: 4) {
        Text(item.state.label)
        if !item.speed.isEmpty { Text("· \(item.speed)") }
        Spacer(minLength: 0)
        Text("\(Int(item.progress * 100))%").monospacedDigit()
      }.contentTransition(.numericText()).font(.caption2).foregroundStyle(.secondary)
    }.padding(.vertical, 2).contextMenu {
      if item.state == .downloading || item.state == .paused {
        Button(item.state == .paused ? "Resume" : "Pause") { onTogglePause() }
      }
      Button("Move to Trash", role: .destructive) { onTrash() }
    }.animation(.smooth, value: item.state)
  }
}

/// Detail pane for one torrent: header stats, overall progress, and the file
/// list with per-file progress and an optional priority mode.
private struct TorrentDetailView: View {
  let store: DownloadStore
  let itemID: String

  @State private var priorityMode = false

  private var item: DownloadStore.DownloadItem {
    store.items.first { $0.id == itemID } ?? .init(id: itemID, title: "")
  }

  var body: some View {
    List {
      Section {
        ForEach(item.files) { file in
          FileRow(file: file, priorityMode: priorityMode) {
            store.toggleFilePaused(fileIndex: file.index, itemID: itemID)
          }.contentShape(Rectangle()).onTapGesture {
            guard priorityMode else { return }
            togglePriority(for: file)
          }
        }
      }
    }.safeAreaInset(edge: .top) { VStack { header }.padding(.horizontal) }.tint(.red)
      .navigationTitle(item.title).toolbar {
        ToolbarItem(placement: .primaryAction) {
          if !item.files.isEmpty, item.state == .downloading || item.state == .paused {
            Button(priorityMode ? "Done" : "Priority") {
              if priorityMode {
                // Leaving the mode keeps the assigned priorities.
              } else {
                // Entering the mode clears all priorities.
                store.clearAllPriorities(itemID: itemID)
              }
              priorityMode.toggle()
            }.help("Assign file download priority (1–4)")
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

  // MARK: Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      // Detailed status: connected peers, seeders, tracker swarm counts.
      HStack(spacing: 12) {
        Text(item.state.label)
        LabeledContent("Peers") { Text("\(item.peers)").monospacedDigit() }
        LabeledContent("Seeds") { Text("\(item.seeders)").monospacedDigit() }
        if let s = item.trackerSeeders, let l = item.trackerLeechers {
          LabeledContent("Swarm") { Text("\(s) seeds · \(l) leechers").monospacedDigit() }
        }
      }.font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
      if let error = item.error { Text(error).font(.caption).foregroundStyle(.red) }
      if priorityMode {
        Text("Click files to set priority 1–4; others download after.").font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: File list

  private func togglePriority(for file: DownloadStore.DownloadFileItem) {
    if file.priority > 0 {
      store.setPriority(0, fileIndex: file.index, itemID: itemID)
    } else {
      // Next free level in 1...4.
      let used = Set(item.files.map(\.priority).filter { $0 > 0 })
      let next = (1...4).first { !used.contains($0) }
      if let next { store.setPriority(next, fileIndex: file.index, itemID: itemID) }
    }
  }
}

/// One file row: name, size, per-file progress, priority badge, pause button.
private struct FileRow: View {
  let file: DownloadStore.DownloadFileItem
  let priorityMode: Bool
  let onTogglePause: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Text(file.path).lineLimit(1).truncationMode(.middle)
        Spacer()
        if file.priority > 0 {
          Text("P\(file.priority)").font(.caption.weight(.semibold)).padding(.horizontal, 5)
            .padding(.vertical, 1).background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .foregroundStyle(.tint)
        }
        if file.isPaused { Text("Paused").font(.caption).foregroundStyle(.secondary) }
        Button(action: onTogglePause) {
          Image(systemName: file.isPaused ? "play.circle" : "pause.circle")
        }.buttonStyle(.borderless).help(file.isPaused ? "Resume file" : "Pause file")
        Text(Self.formatSize(file.length)).font(.caption).foregroundStyle(.secondary)
          .monospacedDigit()
      }
      DualProgressView(
        primary: file.sequentialBytes, secondary: file.verifiedBytes, total: file.length
      ).opacity(file.isPaused ? 0.4 : 1)
      if priorityMode {
        Text(file.priority > 0 ? "Click to clear" : "Click to prioritize").font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }.padding(.vertical, 2).opacity(file.isPaused ? 0.75 : 1)
  }
  struct DualProgressView: View {
    let primary: Int64
    let secondary: Int64
    let total: Int64
    var primaryProgress: Double { max(0, min(Double(primary) / Double(total), 1)) }
    var secondaryProgress: Double { max(0, min(Double(secondary) / Double(total), 1)) }
    var body: some View {
      GeometryReader { view in
        ZStack(alignment: .leading) {
          Capsule().fill(.primary.opacity(0.05)).frame(width: view.size.width, height: 2)
          Capsule().fill(.tint.opacity(0.5)).frame(
            width: view.size.width * secondaryProgress, height: 2)
          Capsule().fill(.tint).frame(width: view.size.width * primaryProgress, height: 4)
        }
      }.frame(height: 4)
    }
  }

  private static func formatSize(_ bytes: Int64) -> String {
    let units = ["B", "KB", "MB", "GB"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1024, unit < units.count - 1 {
      value /= 1024
      unit += 1
    }
    return String(format: "%.1f %@", value, units[unit])
  }
}

extension TorrentState {
  var label: String {
    switch self {
    case .stopped: "Stopped"
    case .checking: "Checking"
    case .downloading: "Downloading"
    case .paused: "Paused"
    case .completed: "Completed"
    case .failed: "Failed"
    }
  }
}
