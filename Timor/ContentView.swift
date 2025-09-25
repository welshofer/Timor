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
    @State private var isShuffling = false
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
                        // Use List instead of Table to avoid crashes
                        List(filteredTracks, selection: $selectedTracks) { track in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.name)
                                        .font(.system(size: 13))
                                        .lineLimit(1)
                                    Text(track.artist)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Text(track.album)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .frame(maxWidth: 200, alignment: .leading)

                                Text(track.releaseDate)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .frame(width: 80, alignment: .trailing)

                                Text(track.duration)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .frame(width: 50, alignment: .trailing)
                            }
                            .padding(.vertical, 2)
                        }
                        .listStyle(.inset)
                    }
                }
                .searchable(text: $searchText, prompt: "Search tracks")
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            searchText = ""
                            spotifyManager.fetchTracksForPlaylist(playlist.id)
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(spotifyManager.isLoadingTracks)
                        .help("Refresh playlist tracks")

                        if !spotifyManager.currentPlaylistTracks.isEmpty {
                            Divider()

                            if !selectedTracks.isEmpty {
                                Button {
                                    showDeleteConfirmation = true
                                } label: {
                                    Label("Delete \(selectedTracks.count)", systemImage: "trash")
                                }
                                .help("Delete selected tracks from playlist")

                                Divider()
                            }

                            Button {
                                spotifyManager.exportPlaylistToCSV(playlistName: playlist.name)
                            } label: {
                                Label("Export", systemImage: "square.and.arrow.down")
                            }
                            .help("Export playlist to CSV file")

                            Button {
                                Task {
                                    isShuffling = true
                                    shuffleResult = await spotifyManager.shuffleAndSavePlaylist(playlist.id)
                                    isShuffling = false
                                    showShuffleAlert = true
                                }
                            } label: {
                                Label("Shuffle", systemImage: "shuffle")
                            }
                            .disabled(isShuffling || spotifyManager.isLoadingTracks)
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
