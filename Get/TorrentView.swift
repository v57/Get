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

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let id = selectedID, let item = store.items.first(where: { $0.id == id }) {
                TorrentDetailView(store: store, itemID: item.id)
            } else {
                ContentUnavailableView(
                    "Select a Download",
                    systemImage: "arrow.down.circle",
                    description: Text("Choose a download from the sidebar.")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showImporter = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Open a .torrent file")
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data]
        ) { result in
            guard case .success(let url) = result else { return }
            Task {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    try await store.openTorrent(url: url)
                } catch {
                    store.lastError = error.localizedDescription
                }
            }
        }
        .alert(
            "Couldn't Open Torrent",
            isPresented: Binding(
                get: { store.lastError != nil },
                set: { if !$0 { store.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    /// Sidebar: one row per download with title and progress.
    private var sidebar: some View {
        List(selection: $selectedID) {
            ForEach(store.items) { item in
                SidebarRow(item: item)
                    .tag(item.id)
            }
        }
        .navigationTitle("Downloads")
        .overlay {
            if store.items.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Click + to open a .torrent file.")
                )
            }
        }
    }
}

/// Compact sidebar row: title, mini progress bar, state line.
private struct SidebarRow: View {
    let item: DownloadStore.DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
                .lineLimit(1)
            ProgressView(value: item.progress)
                .controlSize(.small)
            HStack(spacing: 4) {
                Text(item.state.label)
                if !item.speed.isEmpty {
                    Text("· \(item.speed)")
                }
                Spacer(minLength: 0)
                Text("\(Int(item.progress * 100))%")
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
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
        VStack(alignment: .leading, spacing: 14) {
            header
            if !item.files.isEmpty {
                fileList
            } else {
                Spacer()
            }
        }
        .padding()
        .navigationTitle(item.title)
        .toolbar {
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
                    }
                    .help("Assign file download priority (1–4)")
                }
            }
            ToolbarItem(placement: .automatic) {
                if item.state != .stopped && item.state != .completed {
                    Button("Cancel", role: .destructive) {
                        store.cancel(itemID: itemID)
                    }
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.state.label)
                    .font(.title3.weight(.semibold))
                if !item.speed.isEmpty {
                    Text(item.speed)
                }
                if item.peers > 0 {
                    Text("· \(item.peers) peers")
                }
                Spacer()
                Text("\(Int(item.progress * 100))%")
                    .font(.title3.weight(.semibold).monospacedDigit())
            }
            ProgressView(value: item.progress)
                .controlSize(.large)
            if let error = item.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: File list

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Files")
                    .font(.headline)
                Spacer()
                if priorityMode {
                    Text("Click files to set priority 1–4; others download after.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            List {
                ForEach(item.files) { file in
                    FileRow(file: file, priorityMode: priorityMode)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard priorityMode else { return }
                            togglePriority(for: file)
                        }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private func togglePriority(for file: DownloadStore.DownloadFileItem) {
        if file.priority > 0 {
            store.setPriority(0, fileIndex: file.index, itemID: itemID)
        } else {
            // Next free level in 1...4.
            let used = Set(item.files.map(\.priority).filter { $0 > 0 })
            let next = (1...4).first { !used.contains($0) }
            if let next {
                store.setPriority(next, fileIndex: file.index, itemID: itemID)
            }
        }
    }
}

/// One file row: name, size, per-file progress, priority badge.
private struct FileRow: View {
    let file: DownloadStore.DownloadFileItem
    let priorityMode: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(file.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if file.priority > 0 {
                    Text("P\(file.priority)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(.tint)
                }
                Text(Self.formatSize(file.length))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: Double(file.verifiedBytes), total: Double(max(file.length, 1)))
            HStack {
                Text("\(Int(Double(file.verifiedBytes) / Double(max(file.length, 1)) * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if priorityMode {
                    Text(file.priority > 0 ? "Click to clear" : "Click to prioritize")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
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
