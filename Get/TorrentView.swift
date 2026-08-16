import SwiftUI
import Torrent
import UniformTypeIdentifiers

/// The main download list: one row per torrent, a '+' button to open a
/// `.torrent` file, and an empty state when nothing is downloading yet.
struct TorrentView: View {
    @State private var store = DownloadStore()
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    ContentUnavailableView(
                        "No Torrents",
                        systemImage: "arrow.down.circle",
                        description: Text("Click + to open a .torrent file.")
                    )
                } else {
                    List(store.items) { item in
                        TorrentRow(item: item) {
                            store.cancel(itemID: item.id)
                        }
                    }
                }
            }
            .navigationTitle("Get")
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
    }
}

/// One torrent's title, progress bar, and state/speed/peers line.
private struct TorrentRow: View {
    let item: DownloadStore.DownloadItem
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if item.state != .stopped && item.state != .completed {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.borderless)
                }
            }
            ProgressView(value: item.progress)
            HStack {
                Text(item.state.label)
                if !item.speed.isEmpty {
                    Text("· \(item.speed)")
                }
                if item.peers > 0 {
                    Text("· \(item.peers) peers")
                }
                if let error = item.error {
                    Text("· \(error)")
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(Int(item.progress * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
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
