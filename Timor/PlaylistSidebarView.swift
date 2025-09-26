//
//  PlaylistSidebarView.swift
//  Timor
//
//  Sidebar component for playlist navigation
//

import SwiftUI

struct PlaylistSidebarView: View {
    @ObservedObject var spotifyManager: SpotifyManager
    @Binding var selectedPlaylist: SpotifyManager.Playlist?
    @Binding var isViewingLikedSongs: Bool
    @Binding var searchText: String
    @Binding var selectedTracks: Set<SpotifyManager.Track.ID>
    @Binding var showOnlyEditablePlaylists: Bool
    @Binding var showCreatePlaylist: Bool
    
    var filteredPlaylists: [SpotifyManager.Playlist] {
        if showOnlyEditablePlaylists {
            return spotifyManager.playlists.filter { $0.isEditable }
        }
        return spotifyManager.playlists
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Spotify Playlists")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            
            // Playlists List
            List {
                if spotifyManager.isAuthenticated {
                    // Liked Songs special item
                    Button {
                        selectedPlaylist = nil
                        spotifyManager.selectedPlaylist = nil
                        spotifyManager.isViewingLikedSongs = true
                        searchText = ""
                        selectedTracks = []
                        isViewingLikedSongs = true
                        spotifyManager.fetchLikedSongs()
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                HStack {
                                    Image(systemName: "heart.fill")
                                        .foregroundColor(.red)
                                    Text("Liked Songs")
                                        .font(.headline)
                                }
                                Text("Your liked tracks")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(isViewingLikedSongs ? Color.accentColor.opacity(0.1) : Color.clear)
                    
                    Divider()
                    
                    ForEach(filteredPlaylists) { playlist in
                        PlaylistRow(
                            playlist: playlist,
                            isSelected: selectedPlaylist?.id == playlist.id,
                            onSelect: {
                                selectedPlaylist = playlist
                                spotifyManager.selectedPlaylist = playlist
                                spotifyManager.isViewingLikedSongs = false
                                searchText = ""
                                selectedTracks = []
                                isViewingLikedSongs = false
                                spotifyManager.fetchTracksForPlaylist(playlist.id)
                            }
                        )
                    }
                } else {
                    EmptyPlaylistsView()
                }
            }
            .listStyle(.sidebar)
            
            Divider()
            
            // Bottom controls
            SpotifyControlsView(
                spotifyManager: spotifyManager,
                showOnlyEditablePlaylists: $showOnlyEditablePlaylists
            )
        }
        .navigationSplitViewColumnWidth(min: 250, ideal: 300)
        .toolbar {
            if spotifyManager.isAuthenticated {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showCreatePlaylist = true }) {
                        Label("Create Playlist", systemImage: "text.badge.plus")
                    }
                    .help("Create a new Spotify playlist")
                }
            }
        }
    }
}

struct PlaylistRow: View {
    let playlist: SpotifyManager.Playlist
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading) {
                    HStack {
                        Text(playlist.name)
                            .font(.headline)
                        if !playlist.isEditable {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("\(playlist.totalTracks) tracks • \(playlist.owner)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .contextMenu {
            if playlist.isEditable {
                Button(role: .destructive) {
                    deletePlaylist(playlist)
                } label: {
                    Label("Delete Playlist", systemImage: "trash")
                }
            }
        }
    }
    
    private func deletePlaylist(_ playlist: SpotifyManager.Playlist) {
        Task {
            let alert = NSAlert()
            alert.messageText = "Delete Playlist?"
            alert.informativeText = "Are you sure you want to delete \"\(playlist.name)\"? This cannot be undone."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            
            if alert.runModal() == .alertFirstButtonReturn {
                let success = await SpotifyManager.shared.deletePlaylist(playlist.id)
                if !success {
                    await MainActor.run {
                        let errorAlert = NSAlert()
                        errorAlert.messageText = "Failed to Delete"
                        errorAlert.informativeText = "Could not delete the playlist. Please try again."
                        errorAlert.alertStyle = .warning
                        errorAlert.addButton(withTitle: "OK")
                        errorAlert.runModal()
                    }
                }
            }
        }
    }
}

struct EmptyPlaylistsView: View {
    var body: some View {
        VStack {
            Spacer()
            Text("Connect to Spotify to see your playlists")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding()
            Spacer()
        }
    }
}

struct SpotifyControlsView: View {
    @ObservedObject var spotifyManager: SpotifyManager
    @Binding var showOnlyEditablePlaylists: Bool
    
    var body: some View {
        VStack(spacing: 12) {
            // Spotify section label
            HStack {
                Text("Spotify")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            
            // Login/Logout button
            if spotifyManager.isAuthenticated {
                Button {
                    spotifyManager.logout()
                } label: {
                    HStack {
                        Image(systemName: "stop.circle")
                            .foregroundColor(.red)
                        Text("Logout from Spotify")
                            .foregroundColor(.red)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    spotifyManager.authenticate()
                } label: {
                    HStack {
                        Image(systemName: "music.note.list")
                        Text("Connect to Spotify")
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .disabled(spotifyManager.clientID.isEmpty || spotifyManager.clientSecret.isEmpty)
                
                if spotifyManager.clientID.isEmpty || spotifyManager.clientSecret.isEmpty {
                    Text("Configure Client ID and Secret in Preferences first")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            
            // Only Editable toggle
            if spotifyManager.isAuthenticated {
                Toggle("Only Editable", isOn: $showOnlyEditablePlaylists)
                    .toggleStyle(.switch)
                    .font(.caption)
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
    }
}