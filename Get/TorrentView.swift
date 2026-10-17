import ComponentKit
import DevScreenshots
import SwiftUI
import Torrent
import UniformTypeIdentifiers

/// The main window: downloads in the sidebar, details for the selected one
/// in the detail pane. Torrent details show the files grouped by folder with
/// per-file progress, plus a priority mode that assigns download order 1–4;
/// URL downloads show their transfer, source and checksum.
struct TorrentView: View {
  @State private var store = DownloadStore()
  @State private var showImporter = false
  @State private var showURLSheet = false
  @State private var selectedID: String?
  @State private var search = ""
  @State private var isDropTargeted = false
  /// The Download from URL sheet is on screen (its open or close animation is over).
  @State private var urlSheetIsUp = false
  /// The selected torrent's priority mode: clicking files numbers them 1–4.
  @State private var priorityMode = false
  @State private var columns = NavigationSplitViewVisibility.all

  private var selected: DownloadStore.DownloadItem? {
    selectedID.flatMap { id in store.items.first { $0.id == id } }
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columns) {
      // The sidebar has its own toggle; the kit's toolbar brings a hidden sidebar back.
      sidebar.navigationSplitViewColumnWidth(min: 220, ideal: 260).toolbar(removing: .sidebarToggle)
    } detail: {
      detail
        .kitToolbar(selected?.title ?? "Get") { title } tools: { tools }
        .kitSidebarToggle(columnVisibility: $columns)
    }
    .kitDropTarget(isDropTargeted, cornerRadius: KitMetrics.radiusWindow)
    .overlay {
      if isDropTargeted {
        Label("Drop to download", systemImage: "arrow.down")
          .kitFont(.headline)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .kitSurface(.floating, cornerRadius: KitMetrics.radiusCard)
          .allowsHitTesting(false)
          .transition(.opacity)
      }
    }
    .animation(.kit, value: isDropTargeted)
    .onDrop(of: [.fileURL, .url], isTargeted: $isDropTargeted) { providers in
      handleDrop(providers)
      return true
    }.onChange(of: selectedID) {
      priorityMode = false
    }.onAppear {
      // Hand the live store to the app delegate so "Open With…" events
      // reach it (and any queued from a cold start are drained).
      AppDelegate.attach(store: store)
    }.task {
      // Screenshots (.dev/screenshots.json): every scene in one launch, each next one opened from its arguments.
      Screenshots.prepare(waitsForReady: true) { scene in await openDemoScene(scene.arguments) }
      await openDemoScene(CommandLine.arguments)
      Screenshots.ready()
    }.sheet(isPresented: $showURLSheet) {
      URLDownloadSheet { url, checksum in
        Task { await store.download(from: url, checksum: checksum) }
      }.onAppear { urlSheetIsUp = true }.onDisappear { urlSheetIsUp = false }
    }.fileImporter(
      isPresented: $showImporter,
      allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data]
    ) { result in
      guard case .success(let url) = result else { return }
      Task { await store.open(url: url) }
    }.alert(
      "Couldn't Start Download",
      isPresented: Binding(
        get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })
    ) {
      Button("OK", role: .cancel) { store.lastError = nil }
    } message: {
      Text(store.lastError ?? "")
    }
  }

  // MARK: Detail

  @ViewBuilder private var detail: some View {
    if let item = selected {
      switch item.kind {
      case .torrent: TorrentDetailView(store: store, itemID: item.id, priorityMode: priorityMode)
      case .url: URLDownloadDetailView(store: store, itemID: item.id)
      }
    } else if store.items.isEmpty {
      EmptyState(
        systemImage: "arrow.down", title: "No Downloads",
        message: "Open a .torrent file, or download a link."
      ) {
        Button("Open Torrent…") { showImporter = true }.buttonStyle(.kitPrimary)
        Button("Download a Link…") { showURLSheet = true }.buttonStyle(.kit)
      }.kitPane()
    } else {
      EmptyState(
        systemImage: "arrow.down", title: "Select a Download",
        message: "Choose a download from the sidebar."
      ).kitPane()
    }
  }

  // MARK: Toolbar

  /// The rich title: the selected download, or every download summed up.
  @ViewBuilder private var title: some View {
    if let item = selected {
      KitTitle(item.title, meta: item.metaParts, systemImage: "arrow.down", status: item.workStatus)
    } else {
      KitTitle("Get", meta: store.summaryParts, systemImage: "arrow.down", status: store.overallStatus)
    }
  }

  /// The tools in card groups. As the window narrows they go icon-only, then fold into "…": adding first (the
  /// sidebar has both), then Show in Finder and Open; the download's own actions and Trash stay out.
  @ToolbarSlotBuilder private var tools: [ToolbarSlot] {
    ToolbarSlot(priority: 0) {
      ToolGroup(iconOnly: true) {
        Button("Open a .torrent file", systemImage: "plus") { showImporter = true }
          .help("Open a .torrent file")
        Button("Download a link", systemImage: "link") { showURLSheet = true }
          .help("Download a link")
      }
    } menu: {
      Button("Open a .torrent File…", systemImage: "plus") { showImporter = true }
      Button("Download a Link…", systemImage: "link") { showURLSheet = true }
    }
    if let item = selected {
      let onDisk = store.existingLocation(itemID: item.id) != nil
      ToolbarSlot(priority: 1) {
        ToolGroup(iconOnly: true) {
          fileActions(item, onDisk: onDisk)
        }
      } menu: {
        fileActions(item, onDisk: onDisk)
      }
      if item.isActive || canSetPriority(item) {
        ToolGroup {
          itemActions(item)
        }
      }
      Button("Move download to Trash", systemImage: "trash", role: .destructive) {
        Task { await store.trash(itemID: item.id) }
      }.buttonStyle(.kitRound).help("Move download to Trash")
    }
  }

  @ViewBuilder private func fileActions(_ item: DownloadStore.DownloadItem, onDisk: Bool) -> some View {
    Button("Show in Finder", systemImage: "folder") { store.reveal(itemID: item.id) }
      .help("Show in Finder").disabled(!onDisk)
    if item.isSingleFile {
      Button("Open", systemImage: "arrow.up.forward.app") { store.open(itemID: item.id) }
        .help("Open in its default app").disabled(!onDisk)
    }
  }

  @ViewBuilder private func itemActions(_ item: DownloadStore.DownloadItem) -> some View {
    switch item.kind {
    case .torrent:
      if canSetPriority(item) {
        Button(priorityMode ? "Done" : "Priority") {
          // Entering the mode clears all priorities; leaving it keeps the assigned ones.
          if !priorityMode { store.clearAllPriorities(itemID: item.id) }
          priorityMode.toggle()
        }.kitToolOn(priorityMode).help("Assign file download priority (1–4)")
      }
    case .url:
      switch item.state {
      case .downloading, .paused:
        Button(
          item.state == .paused ? "Resume" : "Pause",
          systemImage: item.state == .paused ? "play.fill" : "pause.fill"
        ) {
          store.togglePause(itemID: item.id)
        }.labelStyle(.iconOnly).help(item.state == .paused ? "Resume" : "Pause")
      case .failed:
        Button("Retry", systemImage: "arrow.clockwise") { store.retry(itemID: item.id) }
          .labelStyle(.iconOnly).help("Try again from where it stopped")
      default:
        EmptyView()
      }
    }
    if item.isActive {
      Button("Cancel", role: .destructive) { store.cancel(itemID: item.id) }
    }
  }

  private func canSetPriority(_ item: DownloadStore.DownloadItem) -> Bool {
    item.kind == .torrent && item.files.count > 1 && (item.state == .downloading || item.state == .paused)
  }

  // MARK: Sidebar

  private var sidebar: some View {
    KitSidebar(
      selection: $selectedID, searchText: $search, searchPrompt: "Search Downloads", columnVisibility: $columns
    ) {
      KitSection(
        "Downloads", meta: store.sectionMeta, systemImage: "arrow.down", status: store.overallStatus
      ) {
        ForEach(shownItems) { item in
          DownloadRow(
            item: item, onTogglePause: { store.togglePause(itemID: item.id) },
            onTrash: { Task { await store.trash(itemID: item.id) } },
            onOpen: { store.open(itemID: item.id) }, onReveal: { store.reveal(itemID: item.id) },
            onRetry: { store.retry(itemID: item.id) })
        }
      } accessory: {
        Button("Open a .torrent file", systemImage: "plus") { showImporter = true }
      }
    } bottomBar: {
      Button("Download a Link", systemImage: "link") { showURLSheet = true }
    }
  }

  private var shownItems: [DownloadStore.DownloadItem] {
    let query = search.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return store.items }
    return store.items.filter { $0.title.localizedCaseInsensitiveContains(query) }
  }

  // MARK: Screenshots and drops

  /// A screenshot scene of the demo list, from its arguments: `--select <title>` shows that download and `--add-url`
  /// opens the Download from URL sheet. What the arguments don't mention is closed, so a scene never keeps the one
  /// before's selection or sheet. Returns once the sheet has finished opening or closing.
  private func openDemoScene(_ arguments: [String]) async {
    guard ScreenshotDemo.isOn else { return }
    selectedID = ScreenshotDemo.value("--select", in: arguments).flatMap { title in
      store.items.first { $0.title == title }?.id
    }
    showURLSheet = ScreenshotDemo.flag("--add-url", in: arguments)
    showImporter = false
    for _ in 0..<60 where urlSheetIsUp != showURLSheet { try? await Task.sleep(for: .milliseconds(50)) }
  }

  /// Open every dropped `.torrent` file and download every dropped link.
  /// Other files are reported as an error so the drop isn't silently
  /// ignored.
  private func handleDrop(_ providers: [NSItemProvider]) {
    for provider in providers {
      // loadObject (not loadItem — deprecated in the macOS 27 SDK);
      // the completion's item is already URL?.
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        guard let url else { return }
        Task { @MainActor in
          if !url.isFileURL {
            await store.download(from: url)
            return
          }
          guard url.pathExtension.lowercased() == "torrent" else {
            store.lastError = "Not a .torrent file: \(url.lastPathComponent)"
            return
          }
          await store.open(url: url)
        }
      }
    }
  }
}

/// A sidebar row: the title, one status line, the progress bar under them while there is work left, and one small
/// action (pause, resume, retry, or Show in Finder once it's done). A download that finishes drops in; one that
/// fails shakes.
private struct DownloadRow: View {
  let item: DownloadStore.DownloadItem
  let onTogglePause: () -> Void
  let onTrash: () -> Void
  let onOpen: () -> Void
  let onReveal: () -> Void
  let onRetry: () -> Void
  @State private var finishes = 0
  @State private var failures = 0

  var body: some View {
    SidebarRow(value: item.id, item.title, subtitle: item.rowStatus) {
      EmptyView()
    } trailing: {
      action
    }
    .progress(item.showsBar ? item.progress : nil)
    .effect(.receive("arrow.down.circle.fill"), on: finishes)
    .effect(.failure, on: failures)
    .onChange(of: item.state) { old, new in
      if new == .completed, old != .completed { finishes += 1 }
      if new.isFailed, !old.isFailed { failures += 1 }
    }
    .kitContextMenu {
      if item.isSingleFile { Button("Open", systemImage: "arrow.up.forward.app") { onOpen() } }
      Button("Show in Finder", systemImage: "folder") { onReveal() }
      Divider()
      if item.state == .downloading || item.state == .paused {
        Button(
          item.state == .paused ? "Resume" : "Pause", systemImage: item.state == .paused ? "play" : "pause"
        ) { onTogglePause() }
      }
      if item.state.isFailed && item.kind == .url {
        Button("Retry", systemImage: "arrow.clockwise") { onRetry() }
      }
      Button("Move to Trash", systemImage: "trash", role: .destructive) { onTrash() }
    }
  }

  @ViewBuilder private var action: some View {
    switch item.state {
    case .downloading, .paused:
      Button(
        item.state == .paused ? "Resume" : "Pause",
        systemImage: item.state == .paused ? "play.fill" : "pause.fill", action: onTogglePause
      ).buttonStyle(.kitIcon).help(item.state == .paused ? "Resume" : "Pause")
    case .failed where item.kind == .url:
      Button("Retry", systemImage: "arrow.clockwise", action: onRetry).buttonStyle(.kitIcon).help("Retry")
    case .completed:
      Button("Show in Finder", systemImage: "folder", action: onReveal).buttonStyle(.kitIcon)
        .help("Show in Finder")
    default:
      EmptyView()
    }
  }
}

// MARK: - Torrent detail

/// Detail pane for one torrent: the swarm line, then its files. A single file is one row with its sequential and
/// verified progress; several files are grouped by folder into cards whose live icons carry each folder's progress.
private struct TorrentDetailView: View {
  let store: DownloadStore
  let itemID: String
  let priorityMode: Bool

  private var item: DownloadStore.DownloadItem {
    store.items.first { $0.id == itemID } ?? .init(id: itemID, title: "")
  }

  var body: some View {
    ScrollView {
      // A folder card can hold hundreds of files: the cards and their rows are built as they near the screen.
      KitLazyStack(alignment: .leading, spacing: KitMetrics.gutter) {
        header
        if item.files.count == 1, let file = item.files.first {
          SingleFileRow(
            file: file, onTogglePause: { store.toggleFilePaused(fileIndex: file.index, itemID: itemID) }
          ).kitContextMenu { fileMenu(file) }
        } else {
          ForEach(FileGroup.groups(of: item)) { group in
            groupCard(group)
          }
        }
      }.padding(.horizontal, 14).padding(.bottom, 14)
    }.kitPane(item.files.count == 1 ? .content : .secondary)
  }

  // MARK: Header

  /// The swarm line: the state, connected peers and seeders, the tracker's swarm counts.
  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 16) {
        Chip(item.state.label, hue: item.state.hue).controlSize(.small)
        stat("Peers", "\(item.peers)")
        stat("Seeds", "\(item.seeders)")
        if let s = item.trackerSeeders, let l = item.trackerLeechers {
          stat("Swarm", "\(s) seeds · \(l) leechers")
        }
      }.frame(height: 36)
      if let error = item.error {
        Banner("Download failed", message: error, systemImage: "exclamationmark.triangle", hue: .red)
      }
      if priorityMode {
        Text("Click files to set priority 1–4; others download after.").kitFont(.caption)
          .padding(.bottom, 4)
      }
    }.padding(.horizontal, 10).kitFont(.caption)
  }

  private func stat(_ key: String, _ value: String) -> some View {
    HStack(spacing: 5) {
      Text(key).foregroundStyle(.kitSecondary)
      Text(value).monospacedDigit()
    }
  }

  // MARK: Groups

  private func groupCard(_ group: FileGroup) -> some View {
    KitSection(
      group.name, meta: group.meta(speed: item.speed),
      systemImage: group.status.isWorking ? "arrow.down" : group.isFolder ? "folder" : "doc",
      hue: group.status == .idle ? .gray : .accent, status: group.status
    ) {
      ForEach(group.files) { file in
        fileRow(file)
      }
    } accessory: {
      if item.state == .downloading || item.state == .paused, group.status.isWorking || group.isPaused {
        let paused = group.isPaused
        Button(paused ? "Resume \(group.name)" : "Pause \(group.name)", systemImage: paused ? "play.fill" : "pause.fill") {
          for file in group.files where !file.isRemoved && !file.isDone {
            store.setFilePaused(!paused, fileIndex: file.index, itemID: itemID)
          }
        }.help(paused ? "Resume this folder" : "Pause this folder")
      }
    }
  }

  private func fileRow(_ file: DownloadStore.DownloadFileItem) -> some View {
    SidebarRow(file.name) {
      EmptyView()
    } trailing: {
      FileTrail(file: file, priorityMode: priorityMode)
    }
    // A click sets the file's priority while assigning them; otherwise the row does nothing on one click.
    .action {
      if priorityMode { togglePriority(for: file) }
    }
    .onDoubleClick {
      guard !priorityMode else { return }
      store.openFile(fileIndex: file.index, itemID: itemID)
    }
    .opacity(file.isRemoved ? 0.5 : 1)
    .kitContextMenu { fileMenu(file) }
  }

  @ViewBuilder private func fileMenu(_ file: DownloadStore.DownloadFileItem) -> some View {
    let onDisk = store.existingFileURL(fileIndex: file.index, itemID: itemID) != nil
    Button("Open", systemImage: "arrow.up.forward.app") { store.openFile(fileIndex: file.index, itemID: itemID) }
      .disabled(!onDisk)
    Button("Show in Finder", systemImage: "folder") { store.revealFile(fileIndex: file.index, itemID: itemID) }
      .disabled(!onDisk)
    Divider()
    if file.isRemoved {
      Button("Restore File", systemImage: "arrow.uturn.backward") {
        store.restoreFile(fileIndex: file.index, itemID: itemID)
      }
    } else if !file.isDone {
      Button(file.isPaused ? "Resume File" : "Pause File", systemImage: file.isPaused ? "play" : "pause") {
        store.toggleFilePaused(fileIndex: file.index, itemID: itemID)
      }
      // Trash a paused file to remove it from the download.
      if file.isPaused {
        Button("Remove File", systemImage: "trash", role: .destructive) {
          store.removeFile(fileIndex: file.index, itemID: itemID)
        }
      }
    }
    // Restrict the download to this file (or this file and every file
    // after it): every other file that isn't fully downloaded is
    // paused and trashed.
    if item.files.count > 1 {
      KitSubmenu("Download", systemImage: "arrow.down") {
        Button("Only This") { store.downloadOnly(fileIndex: file.index, itemID: itemID) }
        Button("Only This and After") {
          store.downloadOnly(fileIndex: file.index, itemID: itemID, andAfter: true)
        }
      }
    }
  }

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

/// A file row's end: its priority, then its progress (the microbar and percent), its state, or its size once done.
private struct FileTrail: View {
  let file: DownloadStore.DownloadFileItem
  let priorityMode: Bool

  var body: some View {
    HStack(spacing: 6) {
      if file.priority > 0 {
        Chip("P\(file.priority)", hue: .accent).controlSize(.small)
      }
      if file.isRemoved {
        Text("Removed")
      } else if file.isDone {
        Text(Int64(file.length), format: .byteCount(style: .file))
      } else if file.isPaused {
        Text("Paused")
      } else if file.verifiedBytes > 0 {
        ProgressRow(value: file.progress)
      } else if priorityMode, file.priority == 0 {
        Text("Click to prioritize")
      } else {
        Text("Waiting")
      }
    }.foregroundStyle(.kitSecondary)
  }
}

/// A single-file torrent's one row: the name, pause, the size, then the sequential progress over the verified one and
/// the byte counts.
private struct SingleFileRow: View {
  let file: DownloadStore.DownloadFileItem
  let onTogglePause: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 8) {
        Text(file.path).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
        if !file.isDone && !file.isRemoved {
          Button(
            file.isPaused ? "Resume file" : "Pause file",
            systemImage: file.isPaused ? "play.circle" : "pause.circle", action: onTogglePause
          ).buttonStyle(.kitIcon).help(file.isPaused ? "Resume file" : "Pause file")
        }
        Text(Int64(file.length), format: .byteCount(style: .file)).kitFont(.caption).monospacedDigit()
          .frame(minWidth: 54, alignment: .trailing)
      }
      if !file.isDone {
        KitProgressBar(value: fraction(file.sequentialBytes), secondary: fraction(file.verifiedBytes))
          .opacity(file.isPaused ? 0.4 : 1)
      }
      Text(
        "\(Text(file.sequentialBytes, format: .byteCount(style: .file))) / \(Text(file.verifiedBytes, format: .byteCount(style: .file)))"
      ).kitFont(.caption).monospacedDigit()
    }.padding(.horizontal, 10).padding(.vertical, 7).opacity(file.isPaused ? 0.75 : 1)
  }

  /// The sequential bytes (playable from the start) or the verified ones (which may run ahead) as a share of the file.
  private func fraction(_ bytes: Int64) -> Double {
    max(0, min(Double(bytes) / Double(max(file.length, 1)), 1))
  }
}

/// The files of one folder of a torrent (files at the top level make the group "Other"), in download order.
private struct FileGroup: Identifiable {
  let name: String
  let isFolder: Bool
  var files: [DownloadStore.DownloadFileItem]
  var id: String { (isFolder ? "d:" : "f:") + name }

  /// The torrent's files by folder, each group where its first file comes in the download order.
  static func groups(of item: DownloadStore.DownloadItem) -> [FileGroup] {
    var groups: [FileGroup] = []
    for file in item.orderedFiles {
      let folder = file.folder
      if let index = groups.firstIndex(where: { $0.isFolder == (folder != nil) && $0.name == (folder ?? "Other") }) {
        groups[index].files.append(file)
      } else {
        groups.append(FileGroup(name: folder ?? "Other", isFolder: folder != nil, files: [file]))
      }
    }
    // Loose files go last, under "Other"; with no folders at all they are just "Files".
    groups.sort { a, b in a.isFolder && !b.isFolder }
    if groups.count == 1, !groups[0].isFolder {
      groups[0] = FileGroup(name: "Files", isFolder: false, files: groups[0].files)
    }
    return groups
  }

  private var kept: [DownloadStore.DownloadFileItem] { files.filter { !$0.isRemoved } }
  private var length: Int64 { kept.reduce(0) { $0 + $1.length } }
  private var verified: Int64 { kept.reduce(0) { $0 + min($1.verifiedBytes, $1.length) } }
  var hasWorkLeft: Bool { kept.contains { !$0.isDone } }
  var isPaused: Bool { kept.contains { !$0.isDone } && kept.filter { !$0.isDone }.allSatisfy(\.isPaused) }

  var status: WorkStatus {
    guard !kept.isEmpty, length > 0 else { return .idle }
    if !hasWorkLeft { return .done }
    let progress = Double(verified) / Double(length)
    if isPaused { return .paused(progress: progress) }
    return verified > 0 ? .working(progress: progress) : .idle
  }

  /// "3 files · 15.3 MB · done", "2 files · 2.9 of 11.3 MB · 6.1 MB/s", "2 files · waiting".
  func meta(speed: String) -> [String] {
    let count = files.count == 1 ? "1 file" : "\(files.count) files"
    let size = Int64(length).formatted(.byteCount(style: .file))
    switch status {
    case .done: return [count, size, "done"]
    case .working: return [count, "\(Int64(verified).formatted(.byteCount(style: .file))) of \(size)", speed]
    case .paused: return [count, "\(Int64(verified).formatted(.byteCount(style: .file))) of \(size)", "paused"]
    default: return files.count == 1 ? [count, size] : [count, "waiting"]
    }
  }
}

extension DownloadStore.DownloadFileItem {
  /// The file's own name, without its folders.
  var name: String { path.split(separator: "/").last.map(String.init) ?? path }
  /// The folder it is in ("02 Sintra"), `nil` at the top level.
  var folder: String? {
    let parts = path.split(separator: "/")
    return parts.count > 1 ? parts.dropLast().joined(separator: "/") : nil
  }
  var isDone: Bool { verifiedBytes >= length }
  var progress: Double { length > 0 ? Double(verifiedBytes) / Double(length) : 0 }
}

extension DownloadStore.DownloadItem {
  /// Not finished, stopped or failed: it can still be paused or cancelled.
  var isActive: Bool { state != .stopped && state != .completed && !state.isFailed }

  /// The work for live icons: the ring carries the progress, gray while paused, green once done, red when it failed.
  var workStatus: WorkStatus {
    switch state {
    case .downloading, .checking: .working(progress: kind == .url && totalBytes == nil ? nil : progress)
    case .paused: .paused(progress: progress)
    case .completed: .done
    case .failed(let message): .failed(message)
    case .stopped: .idle
    }
  }

  /// The toolbar title's meta: "Downloading · 18.4 MB/s · 62%".
  var metaParts: [String] {
    switch state {
    case .completed: [state.label, totalLength.map { $0.formatted(.byteCount(style: .file)) } ?? ""]
    case .failed, .stopped: [state.label]
    default: [state.label, speed, "\(Int(progress * 100))%"]
    }
  }

  /// The sidebar row's status line: "62% · 18.4 MB/s", "Paused · 14%", "Completed · 784 MB".
  var rowStatus: String {
    let parts = state == .downloading ? ["\(Int(progress * 100))%", speed] : metaParts
    return parts.filter { !$0.isEmpty }.joined(separator: " · ")
  }

  /// A bar while there is work left; finished, stopped and failed downloads drop theirs.
  var showsBar: Bool { state == .downloading || state == .paused || state == .checking }

  /// The download's size: the files' for a torrent, the server's for a link.
  var totalLength: Int64? {
    kind == .url ? totalBytes : files.isEmpty ? nil : files.reduce(0) { $0 + $1.length }
  }
}

extension DownloadStore {
  private var activeItems: [DownloadItem] { items.filter { $0.state == .downloading || $0.state == .checking } }

  /// Every active download's progress at once, for the section's and the window's live icon.
  var overallStatus: WorkStatus {
    let active = activeItems
    guard !active.isEmpty else { return items.contains { $0.state == .paused } ? .paused(progress: nil) : .idle }
    return .working(progress: active.reduce(0) { $0 + $1.progress } / Double(active.count))
  }

  /// "3 downloading · 27.7 MB/s", or how many there are when nothing runs.
  var sectionMeta: [String] {
    let active = activeItems
    guard !active.isEmpty else {
      return [items.isEmpty ? "No downloads" : items.count == 1 ? "1 download" : "\(items.count) downloads"]
    }
    return ["\(active.count) downloading", Self.formatSpeed(active.reduce(0) { $0 + $1.bytesPerSecond })]
  }

  /// The window title's meta with nothing selected: "5 downloads · 3 active · 60%".
  var summaryParts: [String] {
    var parts = [items.count == 1 ? "1 download" : "\(items.count) downloads"]
    if case .working(let progress?) = overallStatus {
      parts += ["\(activeItems.count) active", "\(Int(progress * 100))%"]
    }
    return parts
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

  /// The hue its chip speaks in.
  var hue: Hue {
    switch self {
    case .downloading: .blue
    case .checking: .orange
    case .completed: .green
    case .failed: .red
    case .stopped, .paused: .gray
    }
  }

  var isFailed: Bool { if case .failed = self { true } else { false } }
}
