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
            
            // Tracks table content
            if spotifyManager.isLoadingTracks {
                LoadingTracksView(spotifyManager: spotifyManager)
            } else if spotifyManager.currentPlaylistTracks.isEmpty {
                EmptyPlaylistView()
            } else {
                TrackTableView(
                    spotifyManager: spotifyManager,
                    playlist: selectedPlaylist,
                    selectedTracks: $selectedTracks,
                    searchText: $searchText,
                    showDeleteConfirmation: $showDeleteConfirmation
                )
            }
        }
        .searchable(text: $searchText, prompt: "Search tracks")
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
                searchText: $searchText
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
    
    var body: some ToolbarContent {
        if let playlist = selectedPlaylist, playlist.isEditable {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showTrackSearch = true
                } label: {
                    Label("Add Tracks", systemImage: "plus.square.fill.on.square.fill")
                }
                .help("Search and add tracks to this playlist")
            }
        }
        
        ToolbarItem(placement: .primaryAction) {
            Button {
                searchText = ""
                if let playlistId = selectedPlaylist?.id {
                    spotifyManager.fetchTracksForPlaylist(playlistId)
                } else {
                    spotifyManager.fetchLikedSongs()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(spotifyManager.isLoadingTracks)
            .help("Refresh tracks")
        }
        
        if !selectedTracks.isEmpty && (selectedPlaylist?.isEditable ?? false) {
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
                    let playlistName = selectedPlaylist?.name ?? "Liked Songs"
                    spotifyManager.exportPlaylistToCSV(playlistName: playlistName)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.down")
                }
                .help("Export to CSV file")
            }
            
            if let playlist = selectedPlaylist, playlist.isEditable {
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
    }
}