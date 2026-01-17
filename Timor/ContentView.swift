//
//  ContentView.swift
//  Timor
//
//  Simplified main view using extracted components
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @StateObject private var spotifyManager = SpotifyManager.shared
    @State private var showingSettings = false
    @State private var selectedPlaylist: SpotifyManager.Playlist?
    @State private var showShuffleAlert = false
    @State private var shuffleResult = false
    @State private var searchText = ""
    @State private var selectedTracks: Set<SpotifyManager.Track.ID> = []
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var showOnlyEditablePlaylists = true
    @State private var showTrackSearch = false
    @State private var showCreatePlaylist = false
    @State private var isViewingLikedSongs = false
    @State private var newPlaylistName = ""
    @State private var newPlaylistDescription = ""
    @State private var isCreatingPlaylist = false
    @State private var showInspector = false
    @State private var selectedTrack: SpotifyManager.Track?
    @State private var showDuplicateFinder = false
    @State private var showImport = false
    
    var body: some View {
        NavigationSplitView {
            PlaylistSidebarView(
                spotifyManager: spotifyManager,
                selectedPlaylist: $selectedPlaylist,
                isViewingLikedSongs: $isViewingLikedSongs,
                searchText: $searchText,
                selectedTracks: $selectedTracks,
                showOnlyEditablePlaylists: $showOnlyEditablePlaylists,
                showCreatePlaylist: $showCreatePlaylist
            )
        } detail: {
            if selectedPlaylist != nil || isViewingLikedSongs {
                PlaylistDetailView(
                    spotifyManager: spotifyManager,
                    selectedPlaylist: selectedPlaylist,
                    isViewingLikedSongs: isViewingLikedSongs,
                    searchText: $searchText,
                    selectedTracks: $selectedTracks,
                    showDeleteConfirmation: $showDeleteConfirmation,
                    showTrackSearch: $showTrackSearch,
                    showShuffleAlert: $showShuffleAlert,
                    shuffleResult: $shuffleResult,
                    selectedTrack: $selectedTrack,
                    showInspector: $showInspector,
                    showDuplicateFinder: $showDuplicateFinder,
                    showImport: $showImport
                )
            } else {
                EmptyDetailView()
            }
        }
        .inspector(isPresented: $showInspector) {
            TrackInspectorView(track: selectedTrack)
                .inspectorColumnWidth(min: 280, ideal: 280, max: 320)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showTrackSearch) {
            if let playlist = selectedPlaylist {
                TrackSearchView(
                    isPresented: $showTrackSearch,
                    playlistId: playlist.id,
                    playlistName: playlist.name
                )
            }
        }
        .sheet(isPresented: $showCreatePlaylist) {
            CreatePlaylistSheet(
                isPresented: $showCreatePlaylist,
                newPlaylistName: $newPlaylistName,
                newPlaylistDescription: $newPlaylistDescription,
                isCreatingPlaylist: $isCreatingPlaylist,
                spotifyManager: spotifyManager,
                selectedPlaylist: $selectedPlaylist
            )
        }
        .sheet(isPresented: $showDuplicateFinder) {
            DuplicateFinderView(
                spotifyManager: spotifyManager,
                playlist: selectedPlaylist,
                isPresented: $showDuplicateFinder
            )
        }
        .sheet(isPresented: $showImport) {
            if let playlist = selectedPlaylist {
                ImportView(
                    spotifyManager: spotifyManager,
                    playlist: playlist,
                    isPresented: $showImport
                )
            }
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
            DeleteTracksConfirmation(
                selectedTracks: selectedTracks,
                selectedPlaylist: selectedPlaylist,
                spotifyManager: spotifyManager,
                isDeleting: $isDeleting
            )
        } message: {
            Text("This will permanently remove the selected track\(selectedTracks.count == 1 ? "" : "s") from your Spotify playlist. This action cannot be undone.")
        }
        .alert("Error", isPresented: $spotifyManager.showError) {
            Button("OK") {
                spotifyManager.showError = false
            }
        } message: {
            Text(spotifyManager.lastError ?? "An unexpected error occurred")
        }
    }
}

struct EmptyDetailView: View {
    var body: some View {
        Text("Select a playlist to view tracks")
            .font(.title2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CreatePlaylistSheet: View {
    @Binding var isPresented: Bool
    @Binding var newPlaylistName: String
    @Binding var newPlaylistDescription: String
    @Binding var isCreatingPlaylist: Bool
    @ObservedObject var spotifyManager: SpotifyManager
    @Binding var selectedPlaylist: SpotifyManager.Playlist?
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Create New Playlist")
                .font(.title2)
                .bold()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Playlist Name")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("My Awesome Playlist", text: $newPlaylistName)
                    .textFieldStyle(.roundedBorder)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Description (Optional)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("A great collection of songs", text: $newPlaylistDescription)
                    .textFieldStyle(.roundedBorder)
            }
            
            Spacer()
            
            HStack {
                Button("Cancel") {
                    newPlaylistName = ""
                    newPlaylistDescription = ""
                    isPresented = false
                }
                .keyboardShortcut(.escape)
                
                Spacer()
                
                Button("Create") {
                    createPlaylist()
                }
                .buttonStyle(.borderedProminent)
                .disabled(newPlaylistName.isEmpty || isCreatingPlaylist)
            }
        }
        .padding()
        .frame(width: Constants.UI.createPlaylistWidth, height: Constants.UI.createPlaylistHeight)
    }
    
    private func createPlaylist() {
        isCreatingPlaylist = true
        Task {
            let success = await spotifyManager.createPlaylist(
                name: newPlaylistName,
                description: newPlaylistDescription
            )
            
            await MainActor.run {
                isCreatingPlaylist = false
                if success {
                    let playlistNameToSelect = newPlaylistName
                    newPlaylistName = ""
                    newPlaylistDescription = ""
                    isPresented = false
                    
                    Task {
                        try? await Task.sleep(nanoseconds: Constants.Animation.shuffleDelay)
                        if let newPlaylist = spotifyManager.playlists.first(where: { $0.name == playlistNameToSelect }) {
                            selectedPlaylist = newPlaylist
                            spotifyManager.selectedPlaylist = newPlaylist
                            spotifyManager.fetchTracksForPlaylist(newPlaylist.id)
                        }
                    }
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Failed to Create Playlist"
                    alert.informativeText = "Could not create the playlist. Please try again."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }
}

struct DeleteTracksConfirmation: View {
    let selectedTracks: Set<SpotifyManager.Track.ID>
    let selectedPlaylist: SpotifyManager.Playlist?
    let spotifyManager: SpotifyManager
    @Binding var isDeleting: Bool
    
    var body: some View {
        Button("Delete \(selectedTracks.count) track\(selectedTracks.count == 1 ? "" : "s")", role: .destructive) {
            deleteSelectedTracks()
        }
        Button("Cancel", role: .cancel) { }
    }
    
    private func deleteSelectedTracks() {
        Task {
            guard let playlist = selectedPlaylist else { return }
            isDeleting = true
            
            let tracksToDelete = Set(spotifyManager.currentPlaylistTracks.filter { selectedTracks.contains($0.id) })
            let success = await spotifyManager.deleteTracksFromPlaylist(playlist.id, tracks: tracksToDelete)
            isDeleting = false
            
            if !success {
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
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}