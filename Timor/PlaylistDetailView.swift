//
//  PlaylistDetailView.swift
//  Timor
//
//  Main detail view for displaying playlist contents
//

import SwiftUI

struct PlaylistDetailView: View {
    @ObservedObject var spotifyManager: SpotifyManager
    let selectedPlaylist: SpotifyManager.Playlist?
    let isViewingLikedSongs: Bool
    @Binding var searchText: String
    @Binding var selectedTracks: Set<SpotifyManager.Track.ID>
    @Binding var showDeleteConfirmation: Bool
    @Binding var showTrackSearch: Bool
    @Binding var showShuffleAlert: Bool
    @Binding var shuffleResult: Bool
    @Binding var selectedTrack: SpotifyManager.Track?
    @Binding var showInspector: Bool
    @Binding var showDuplicateFinder: Bool
    @Binding var showImport: Bool
    @Binding var showStats: Bool
    
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
        VStack(alignment: .leading, spacing: 0) {
            // Playlist header
            PlaylistHeader(
                spotifyManager: spotifyManager,
                selectedPlaylist: selectedPlaylist,
                isViewingLikedSongs: isViewingLikedSongs,
                searchText: searchText,
                filteredTracksCount: filteredTracks.count
            )
            
            Divider()
            
            // Tracks content - Table on macOS, List on iOS for drag reorder
            if spotifyManager.isLoadingTracks {
                LoadingTracksView(spotifyManager: spotifyManager)
            } else if spotifyManager.currentPlaylistTracks.isEmpty {
                EmptyPlaylistView()
            } else {
                #if os(macOS)
                TrackTableView(
                    spotifyManager: spotifyManager,
                    playlist: selectedPlaylist,
                    selectedTracks: $selectedTracks,
                    searchText: $searchText,
                    showDeleteConfirmation: $showDeleteConfirmation,
                    selectedTrack: $selectedTrack
                )
                #else
                TrackListView(
                    spotifyManager: spotifyManager,
                    playlist: selectedPlaylist,
                    selectedTracks: $selectedTracks,
                    searchText: $searchText,
                    showDeleteConfirmation: $showDeleteConfirmation,
                    selectedTrack: $selectedTrack
                )
                #endif
            }
        }
        .searchable(text: $searchText, placement: .toolbarPrincipal, prompt: "Search tracks")
        .onChange(of: searchText) { oldValue, newValue in
            selectedTracks.removeAll()
        }
        .toolbar {
            PlaylistToolbar(
                spotifyManager: spotifyManager,
                selectedPlaylist: selectedPlaylist,
                selectedTracks: selectedTracks,
                showTrackSearch: $showTrackSearch,
                showDeleteConfirmation: $showDeleteConfirmation,
                showShuffleAlert: $showShuffleAlert,
                shuffleResult: $shuffleResult,
                searchText: $searchText,
                showInspector: $showInspector,
                selectedTrack: $selectedTrack,
                showDuplicateFinder: $showDuplicateFinder,
                showImport: $showImport,
                showStats: $showStats
            )
        }
    }
}

struct PlaylistHeader: View {
    @ObservedObject var spotifyManager: SpotifyManager
    let selectedPlaylist: SpotifyManager.Playlist?
    let isViewingLikedSongs: Bool
    let searchText: String
    let filteredTracksCount: Int
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if isViewingLikedSongs {
                        Image(systemName: "heart.fill")
                            .foregroundColor(.red)
                            .font(.largeTitle)
                            .accessibilityHidden(true)
                    }
                    Text(isViewingLikedSongs ? "Liked Songs" : (selectedPlaylist?.name ?? ""))
                        .font(.largeTitle)
                        .bold()
                }
                
                HStack(spacing: 4) {
                    if isViewingLikedSongs {
                        Text("\(spotifyManager.currentPlaylistTracks.count) liked songs")
                    } else if let playlist = selectedPlaylist {
                        Text("By \(playlist.owner) • \(playlist.totalTracks) tracks")

                        if let description = playlist.description, !description.isEmpty {
                            Text("• \(description)")
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }

                    if !searchText.isEmpty {
                        Text("• Showing \(filteredTracksCount)")
                            .foregroundColor(.accentColor)
                    }

                    CacheStalenessIndicator(spotifyManager: spotifyManager)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding()
    }
}

struct CacheStalenessIndicator: View {
    @ObservedObject var spotifyManager: SpotifyManager
    
    var body: some View {
        if spotifyManager.isUsingCache {
            if let cacheDate = spotifyManager.lastCacheUpdate {
                Text("• Cached \(formattedCacheDate(cacheDate))")
                    .foregroundColor(.orange)
                    .help("Data loaded from cache. Click refresh to get latest.")
            }
        }
    }
    
    private func formattedCacheDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct LoadingTracksView: View {
    @ObservedObject var spotifyManager: SpotifyManager
    
    var body: some View {
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
    }
}

struct EmptyPlaylistView: View {
    var body: some View {
        Text("No tracks in this playlist")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PlaylistToolbar: ToolbarContent {
    @ObservedObject var spotifyManager: SpotifyManager
    let selectedPlaylist: SpotifyManager.Playlist?
    let selectedTracks: Set<SpotifyManager.Track.ID>
    @Binding var showTrackSearch: Bool
    @Binding var showDeleteConfirmation: Bool
    @Binding var showShuffleAlert: Bool
    @Binding var shuffleResult: Bool
    @Binding var searchText: String
    @Binding var showInspector: Bool
    @Binding var selectedTrack: SpotifyManager.Track?
    @Binding var showDuplicateFinder: Bool
    @Binding var showImport: Bool
    @Binding var showStats: Bool

    var body: some ToolbarContent {
        // Undo/Redo buttons
        ToolbarItemGroup(placement: .navigation) {
            Button {
                spotifyManager.playlistUndoManager.undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!spotifyManager.playlistUndoManager.canUndo || spotifyManager.playlistUndoManager.isUndoRedoInProgress)
            .help(spotifyManager.playlistUndoManager.undoActionName.map { "Undo \($0)" } ?? "Undo")
            .keyboardShortcut("z", modifiers: .command)

            Button {
                spotifyManager.playlistUndoManager.redo()
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(!spotifyManager.playlistUndoManager.canRedo || spotifyManager.playlistUndoManager.isUndoRedoInProgress)
            .help(spotifyManager.playlistUndoManager.redoActionName.map { "Redo \($0)" } ?? "Redo")
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }

        // Main action buttons group
        ToolbarItemGroup(placement: .primaryAction) {

            ControlGroup{
                if let playlist = selectedPlaylist, playlist.isEditable {
                    Button {
                        showTrackSearch = true
                    } label: {
                        Label("Add Tracks", systemImage: "plus.square.fill.on.square.fill")
                    }
                    .help("Search and add tracks to this playlist")

                    Button {
                        showImport = true
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.up")
                    }
                    .help("Import tracks from CSV or URLs")
                }
                if selectedPlaylist?.isEditable ?? false {
                    Button {
                        showDeleteConfirmation = true
                    } label: {
                        Label(selectedTracks.isEmpty ? "Delete" : "Delete \(selectedTracks.count)", systemImage: "trash")
                    }
                    .disabled(selectedTracks.isEmpty)
                    .help(selectedTracks.isEmpty ? "Select tracks to delete" : "Delete selected tracks from playlist")
                }
            }
            .controlGroupStyle(.navigation)
            
            ControlGroup {
                Button {
                    searchText = ""
                    selectedTrack = nil
                    showInspector = false

                    if let playlistId = selectedPlaylist?.id {
                        spotifyManager.fetchTracksForPlaylist(playlistId, forceRefresh: true)
                    } else {
                        spotifyManager.fetchLikedSongs(forceRefresh: true)
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(spotifyManager.isLoadingTracks)
                .help("Refresh tracks from Spotify")

                if !spotifyManager.currentPlaylistTracks.isEmpty {
                    Button {
                        showStats = true
                    } label: {
                        Label("Stats", systemImage: "chart.bar.xaxis")
                    }
                    .help("View playlist statistics")

                    Button {
                        showDuplicateFinder = true
                    } label: {
                        Label("Duplicates", systemImage: "doc.on.doc")
                    }
                    .help("Find and remove duplicate tracks")

                    #if os(macOS)
                    Button {
                        let playlistName = selectedPlaylist?.name ?? "Liked Songs"
                        spotifyManager.exportPlaylistToCSV(playlistName: playlistName)
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.down")
                    }
                    .help("Export to CSV file")
                    #endif

                    if let playlist = selectedPlaylist, playlist.isEditable {
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
            .controlGroupStyle(.navigation)
        }
      //  ToolbarSpacer(.flexible)
        ToolbarItem() {
            Button {
                showInspector.toggle()
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .disabled(selectedTrack == nil)
            .help(selectedTrack == nil ? "Select a track to view details" : "Toggle Inspector")
        }
    }
}
