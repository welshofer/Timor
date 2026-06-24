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
    @State private var showStats = false
    @State private var showDeleteError = false

    var body: some View {
        NavigationSplitView {
            PlaylistSidebarView(
                spotifyManager: spotifyManager,
                selectedPlaylist: $selectedPlaylist,
                isViewingLikedSongs: $isViewingLikedSongs,
                searchText: $searchText,
                selectedTracks: $selectedTracks,
                showOnlyEditablePlaylists: $showOnlyEditablePlaylists,
                showCreatePlaylist: $showCreatePlaylist,
                showSettings: $showingSettings
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
                    showImport: $showImport,
                    showStats: $showStats
                )
            } else {
                EmptyDetailView()
            }
        }
        .inspector(isPresented: $showInspector) {
            TrackInspectorView(track: selectedTrack)
                .inspectorColumnWidth(min: Constants.UI.inspectorMinWidth, ideal: Constants.UI.inspectorIdealWidth, max: Constants.UI.inspectorMaxWidth)
        }
        .sheet(isPresented: $showingSettings) {
            #if os(macOS)
            SettingsView()
            #else
            NavigationStack {
                SettingsView()
            }
            #endif
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
        .sheet(isPresented: $showStats) {
            PlaylistStatsView(
                spotifyManager: spotifyManager,
                playlist: selectedPlaylist,
                isViewingLikedSongs: isViewingLikedSongs,
                isPresented: $showStats
            )
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
                isDeleting: $isDeleting,
                showDeleteError: $showDeleteError
            )
        } message: {
            Text("This will remove the selected track\(selectedTracks.count == 1 ? "" : "s") from your Spotify playlist. You can undo it with ⌘Z.")
        }
        .alert("Delete Failed", isPresented: $showDeleteError) {
            Button("OK") { }
        } message: {
            Text("Failed to delete tracks from playlist. Please try again.")
        }
        .alert("Error", isPresented: $spotifyManager.showError) {
            Button("OK") {
                spotifyManager.showError = false
                spotifyManager.lastError = nil
                spotifyManager.lastErrorRecovery = nil
            }
        } message: {
            VStack(alignment: .leading, spacing: 8) {
                Text(spotifyManager.lastError ?? "An unexpected error occurred")
                if let recovery = spotifyManager.lastErrorRecovery {
                    Text(recovery)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // USE-5: transient feedback for bulk like/unlike (and similar) results.
        .alert(spotifyManager.infoMessage ?? "", isPresented: Binding(
            get: { spotifyManager.infoMessage != nil },
            set: { if !$0 { spotifyManager.infoMessage = nil } }
        )) {
            Button("OK") { spotifyManager.infoMessage = nil }
        }
    }
}

struct EmptyDetailView: View {
    var body: some View {
        // ATTR-1: native empty state instead of bare centered text.
        ContentUnavailableView(
            "No Playlist Selected",
            systemImage: "music.note.list",
            description: Text("Select a playlist from the sidebar to view its tracks.")
        )
    }
}

struct CreatePlaylistSheet: View {
    @Binding var isPresented: Bool
    @Binding var newPlaylistName: String
    @Binding var newPlaylistDescription: String
    @Binding var isCreatingPlaylist: Bool
    @ObservedObject var spotifyManager: SpotifyManager
    @Binding var selectedPlaylist: SpotifyManager.Playlist?
    @State private var showCreateError = false

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
        .alert("Failed to Create Playlist", isPresented: $showCreateError) {
            Button("OK") { }
        } message: {
            Text("Could not create the playlist. Please try again.")
        }
    }
    
    private func createPlaylist() {
        isCreatingPlaylist = true
        let name = newPlaylistName
        let description = newPlaylistDescription
        Task {
            let newId = await spotifyManager.createPlaylist(name: name, description: description)

            await MainActor.run {
                isCreatingPlaylist = false
                guard let newId = newId else {
                    showCreateError = true
                    return
                }
                newPlaylistName = ""
                newPlaylistDescription = ""
                isPresented = false

                // REL-4: select the new playlist directly by its returned ID — no fixed
                // sleep, no name match (which broke on slow refreshes / duplicate names).
                let newPlaylist = SpotifyManager.Playlist(
                    id: newId,
                    name: name,
                    totalTracks: 0,
                    owner: "You",
                    description: description.isEmpty ? nil : description,
                    isEditable: true
                )
                selectedPlaylist = newPlaylist
                spotifyManager.selectedPlaylist = newPlaylist
                spotifyManager.fetchTracksForPlaylist(newId)
            }
        }
    }
}

struct DeleteTracksConfirmation: View {
    let selectedTracks: Set<SpotifyManager.Track.ID>
    let selectedPlaylist: SpotifyManager.Playlist?
    let spotifyManager: SpotifyManager
    @Binding var isDeleting: Bool
    @Binding var showDeleteError: Bool

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
                    showDeleteError = true
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: CachedPlaylist.self, inMemory: true)
}