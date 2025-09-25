//
//  ContentView.swift
//  Timor
//
//  Created by Jay Welshofer on 9/24/25.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var items: [Item]
    @StateObject private var spotifyManager = SpotifyManager.shared
    @State private var showingSettings = false
    @State private var selectedPlaylist: SpotifyManager.Playlist?
    @State private var showShuffleAlert = false
    @State private var shuffleResult = false
    @State private var searchText = ""
    @State private var selectedTracks: Set<SpotifyManager.Track.ID> = []
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false

    var filteredTracks: [SpotifyManager.Track] {
        if searchText.isEmpty {
            return spotifyManager.currentPlaylistTracks
        }

        let lowercasedSearch = searchText.lowercased()
        return spotifyManager.currentPlaylistTracks.filter { track in
            track.name.lowercased().contains(lowercasedSearch) ||
            track.artist.lowercased().contains(lowercasedSearch) ||
            track.album.lowercased().contains(lowercasedSearch)
        }
    }

    // Safe selection that only includes tracks in current filtered results
    var safeSelection: Binding<Set<SpotifyManager.Track.ID>> {
        Binding(
            get: {
                let validIDs = Set(filteredTracks.map { $0.id })
                return selectedTracks.intersection(validIDs)
            },
            set: { newSelection in
                selectedTracks = newSelection
            }
        )
    }


    var body: some View {
        NavigationSplitView {
            List {
                // Spotify Section
                Section("Spotify") {
                    if spotifyManager.isAuthenticated {
                        Button {
                            spotifyManager.logout()
                        } label: {
                            Label("Logout from Spotify", systemImage: "arrow.left.circle")
                        }
                        .foregroundColor(.red)

                        if !spotifyManager.playlists.isEmpty {
                            ForEach(spotifyManager.playlists) { playlist in
                                Button {
                                    selectedPlaylist = playlist
                                    searchText = ""
                                    selectedTracks = []
                                    spotifyManager.fetchTracksForPlaylist(playlist.id)
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(playlist.name)
                                            .font(.headline)
                                        Text("\(playlist.totalTracks) tracks")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(selectedPlaylist?.id == playlist.id ? Color.accentColor.opacity(0.1) : Color.clear)
                            }
                        }
                    } else {
                        Button {
                            spotifyManager.authenticate()
                        } label: {
                            Label("Connect to Spotify", systemImage: "music.note.list")
                        }
                        .disabled(spotifyManager.clientID.isEmpty || spotifyManager.clientSecret.isEmpty)

                        if spotifyManager.clientID.isEmpty || spotifyManager.clientSecret.isEmpty {
                            Text("Configure Client ID and Secret in Preferences first")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Uses Spotify Web API")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Original Items Section
                Section("Items") {
                    ForEach(items) { item in
                        NavigationLink {
                            Text("Item at \(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))")
                        } label: {
                            Text(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))
                        }
                    }
                    .onDelete(perform: deleteItems)
                }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 300)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: addItem) {
                        Label("Add Item", systemImage: "plus")
                    }
                }
            }
        } detail: {
            if let playlist = selectedPlaylist {
                VStack(alignment: .leading, spacing: 0) {
                    // Playlist header
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(playlist.name)
                                .font(.largeTitle)
                                .bold()
                            HStack(spacing: 4) {
                                Text("By \(playlist.owner) • \(playlist.totalTracks) tracks")
                                if !searchText.isEmpty {
                                    Text("• Showing \(filteredTracks.count)")
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .padding()

                    Divider()

                    // Tracks table
                    if spotifyManager.isLoadingTracks {
                        VStack(spacing: 16) {
                            ProgressView()
                            if spotifyManager.loadingProgress.total > 0 {
                                Text("Loading \(spotifyManager.loadingProgress.current) of \(spotifyManager.loadingProgress.total) tracks...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Loading tracks...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if spotifyManager.currentPlaylistTracks.isEmpty {
                        Text("No tracks in this playlist")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        // Always use Table with resizable columns
                        Table(filteredTracks, selection: safeSelection) {
                            TableColumn("Title", value: \.name)
                                .width(min: 200)
                            TableColumn("Artist", value: \.artist)
                                .width(min: 150)
                            TableColumn("Album", value: \.album)
                                .width(min: 150)
                            TableColumn("Release Date", value: \.releaseDate)
                                .width(ideal: 100, max: 120)
                            TableColumn("Duration", value: \.duration)
                                .width(ideal: 60, max: 80)
                        }
                        .contextMenu(forSelectionType: SpotifyManager.Track.ID.self) { items in
                            if items.isEmpty {
                                Text("No selection")
                            } else if items.count == 1, searchText.isEmpty {
                                // Single track - allow reordering via context menu
                                Button("Move to Top") {
                                    if let trackId = items.first,
                                       let index = spotifyManager.currentPlaylistTracks.firstIndex(where: { $0.id == trackId }),
                                       index > 0 {
                                        Task {
                                            await spotifyManager.reorderTracks(
                                                in: selectedPlaylist!.id,
                                                from: IndexSet(integer: index),
                                                to: 0
                                            )
                                        }
                                    }
                                }
                                Button("Move Up") {
                                    if let trackId = items.first,
                                       let index = spotifyManager.currentPlaylistTracks.firstIndex(where: { $0.id == trackId }),
                                       index > 0 {
                                        Task {
                                            await spotifyManager.reorderTracks(
                                                in: selectedPlaylist!.id,
                                                from: IndexSet(integer: index),
                                                to: index - 1
                                            )
                                        }
                                    }
                                }
                                .keyboardShortcut("↑", modifiers: [.command])
                                Button("Move Down") {
                                    if let trackId = items.first,
                                       let index = spotifyManager.currentPlaylistTracks.firstIndex(where: { $0.id == trackId }),
                                       index < spotifyManager.currentPlaylistTracks.count - 1 {
                                        Task {
                                            await spotifyManager.reorderTracks(
                                                in: selectedPlaylist!.id,
                                                from: IndexSet(integer: index),
                                                to: index + 2
                                            )
                                        }
                                    }
                                }
                                .keyboardShortcut("↓", modifiers: [.command])
                                Button("Move to Bottom") {
                                    if let trackId = items.first,
                                       let index = spotifyManager.currentPlaylistTracks.firstIndex(where: { $0.id == trackId }),
                                       index < spotifyManager.currentPlaylistTracks.count - 1 {
                                        Task {
                                            await spotifyManager.reorderTracks(
                                                in: selectedPlaylist!.id,
                                                from: IndexSet(integer: index),
                                                to: spotifyManager.currentPlaylistTracks.count
                                            )
                                        }
                                    }
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    showDeleteConfirmation = true
                                }
                            } else {
                                Button("Delete \(items.count) tracks", role: .destructive) {
                                    showDeleteConfirmation = true
                                }
                            }
                        }
                        .id("\(selectedPlaylist?.id ?? "")-\(searchText)") // Force table recreation on search
                    }
                }
                .searchable(text: $searchText, prompt: "Search tracks")
                .onChange(of: searchText) { _ in
                    // Clear selection when search changes to prevent crash
                    selectedTracks.removeAll()
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            searchText = ""
                            spotifyManager.fetchTracksForPlaylist(playlist.id)
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(spotifyManager.isLoadingTracks)
                        .help("Refresh playlist tracks")
                    }

                    if !selectedTracks.isEmpty {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                showDeleteConfirmation = true
                            } label: {
                                Label("Delete \(selectedTracks.count)", systemImage: "trash")
                            }
                            .help("Delete selected tracks from playlist")
                        }
                    }

                    if !spotifyManager.currentPlaylistTracks.isEmpty {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                spotifyManager.exportPlaylistToCSV(playlistName: playlist.name)
                            } label: {
                                Label("Export", systemImage: "square.and.arrow.down")
                            }
                            .help("Export playlist to CSV file")
                        }

                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                Task {
                                    shuffleResult = await spotifyManager.shuffleAndSavePlaylist(playlist.id)
                                    showShuffleAlert = true
                                }
                            } label: {
                                Label("Shuffle", systemImage: "shuffle")
                            }
                            .disabled(spotifyManager.isShuffling || spotifyManager.isLoadingTracks)
                            .help("Shuffle and save playlist order")
                        }
                    }
                }
            } else {
                Text("Select a playlist to view tracks")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .alert("Playlist Shuffle", isPresented: $showShuffleAlert) {
            Button("OK") { }
        } message: {
            if shuffleResult {
                Text("Successfully shuffled and saved the playlist! The new order has been permanently saved to Spotify.")
            } else {
                Text("Failed to save shuffled playlist. Please check your permissions and try again.")
            }
        }
        .confirmationDialog(
            "Delete Tracks",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectedTracks.count) track\(selectedTracks.count == 1 ? "" : "s")", role: .destructive) {
                Task {
                    guard let playlist = selectedPlaylist else { return }
                    isDeleting = true
                    // Convert selected IDs to tracks
                    let tracksToDelete = Set(spotifyManager.currentPlaylistTracks.filter { selectedTracks.contains($0.id) })
                    let success = await spotifyManager.deleteTracksFromPlaylist(playlist.id, tracks: tracksToDelete)
                    isDeleting = false

                    if success {
                        // Only clear selection, keep search term
                        await MainActor.run {
                            selectedTracks.removeAll()
                        }
                    } else {
                        // Show error alert
                        await MainActor.run {
                            let alert = NSAlert()
                            alert.messageText = "Delete Failed"
                            alert.informativeText = "Failed to delete tracks from playlist. Please try again."
                            alert.alertStyle = .warning
                            alert.addButton(withTitle: "OK")
                            alert.runModal()
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will permanently remove the selected track\(selectedTracks.count == 1 ? "" : "s") from your Spotify playlist. This action cannot be undone.")
        }
        // Playlists load automatically on authentication
    }

    private func addItem() {
        withAnimation {
            let newItem = Item(timestamp: Date())
            modelContext.insert(newItem)
        }
    }

    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(items[index])
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
