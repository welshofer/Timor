//
//  TrackTableView.swift
//  Timor
//
//  Track table component for displaying playlist tracks
//

import SwiftUI

struct TrackTableView: View {
    @ObservedObject var spotifyManager: SpotifyManager
    let playlist: SpotifyManager.Playlist?
    @Binding var selectedTracks: Set<SpotifyManager.Track.ID>
    @Binding var searchText: String
    @Binding var showDeleteConfirmation: Bool
    @Binding var selectedTrack: SpotifyManager.Track?
    
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
                // Update selected track for inspector
                if let firstId = newSelection.first,
                   newSelection.count == 1,
                   let track = filteredTracks.first(where: { $0.id == firstId }) {
                    selectedTrack = track
                } else if newSelection.isEmpty {
                    selectedTrack = nil
                }
            }
        )
    }
    
    var body: some View {
        Table(filteredTracks, selection: safeSelection) {
            TableColumn("Title", value: \.name)
                .width(min: 200)
            TableColumn("Artist", value: \.artist)
                .width(min: 150)
            TableColumn("Album", value: \.album)
                .width(min: 150)
            TableColumn("Release Date", value: \.releaseDate)
                .width(120)
            TableColumn("Duration", value: \.duration)
                .width(80)
            TableColumn(Text(Image(systemName: "heart.fill")).font(.caption)) { track in
                LikeButton(track: track, spotifyManager: spotifyManager)
            }
            .width(30)
        }
        .contextMenu(forSelectionType: SpotifyManager.Track.ID.self) { items in
            TrackContextMenu(
                items: items,
                playlist: playlist,
                spotifyManager: spotifyManager,
                showDeleteConfirmation: $showDeleteConfirmation,
                searchText: searchText
            )
        }
        .id("\(playlist?.id ?? "")-\(searchText)-\(spotifyManager.currentPlaylistTracks.count)")
    }
}

struct LikeButton: View {
    let track: SpotifyManager.Track
    let spotifyManager: SpotifyManager
    
    var body: some View {
        Button(action: {
            Task {
                if track.isLiked {
                    _ = await spotifyManager.unlikeTrack(track)
                } else {
                    _ = await spotifyManager.likeTrack(track)
                }
            }
        }) {
            Image(systemName: track.isLiked ? "heart.fill" : "heart")
                .foregroundColor(track.isLiked ? .red : .secondary)
        }
        .buttonStyle(.borderless)
        .help(track.isLiked ? "Remove from Liked Songs" : "Add to Liked Songs")
    }
}

struct TrackContextMenu: View {
    let items: Set<SpotifyManager.Track.ID>
    let playlist: SpotifyManager.Playlist?
    let spotifyManager: SpotifyManager
    @Binding var showDeleteConfirmation: Bool
    let searchText: String
    
    var body: some View {
        if items.isEmpty {
            Text("No selection")
        } else if items.count == 1, searchText.isEmpty {
            SingleTrackContextMenu(
                trackId: items.first!,
                playlist: playlist,
                spotifyManager: spotifyManager,
                showDeleteConfirmation: $showDeleteConfirmation
            )
        } else {
            Button("Delete \(items.count) tracks", role: .destructive) {
                showDeleteConfirmation = true
            }
        }
    }
}

struct SingleTrackContextMenu: View {
    let trackId: SpotifyManager.Track.ID
    let playlist: SpotifyManager.Playlist?
    let spotifyManager: SpotifyManager
    @Binding var showDeleteConfirmation: Bool
    
    var track: SpotifyManager.Track? {
        spotifyManager.currentPlaylistTracks.first(where: { $0.id == trackId })
    }
    
    var body: some View {
        if let track = track {
            Button {
                Task {
                    if track.isLiked {
                        _ = await spotifyManager.unlikeTrack(track)
                    } else {
                        _ = await spotifyManager.likeTrack(track)
                    }
                }
            } label: {
                Label(track.isLiked ? "Remove from Liked Songs" : "Add to Liked Songs",
                      systemImage: track.isLiked ? "heart.fill" : "heart")
            }
            
            Divider()
            
            if let playlist = playlist, playlist.isEditable {
                Button("Move to Top") {
                    moveTrack(to: 0)
                }
                Button("Move Up") {
                    if let index = spotifyManager.currentPlaylistTracks.firstIndex(where: { $0.id == trackId }),
                       index > 0 {
                        moveTrack(to: index - 1)
                    }
                }
                .keyboardShortcut("↑", modifiers: [.command])
                
                Button("Move Down") {
                    if let index = spotifyManager.currentPlaylistTracks.firstIndex(where: { $0.id == trackId }),
                       index < spotifyManager.currentPlaylistTracks.count - 1 {
                        moveTrack(to: index + 2)
                    }
                }
                .keyboardShortcut("↓", modifiers: [.command])
                
                Button("Move to Bottom") {
                    moveTrack(to: spotifyManager.currentPlaylistTracks.count)
                }
                
                Divider()
                
                Button("Delete", role: .destructive) {
                    showDeleteConfirmation = true
                }
            }
        }
    }
    
    private func moveTrack(to destination: Int) {
        guard let playlist = playlist,
              let index = spotifyManager.currentPlaylistTracks.firstIndex(where: { $0.id == trackId }) else {
            return
        }
        
        Task {
            await spotifyManager.reorderTracks(
                in: playlist.id,
                from: IndexSet(integer: index),
                to: destination
            )
        }
    }
}