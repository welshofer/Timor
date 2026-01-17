//
//  PlaylistFolder.swift
//  Timor
//
//  Local folder organization for playlists (Spotify doesn't have folder API)
//

import Foundation
import SwiftData

/// A local folder for organizing playlists
/// Note: This is stored locally only - Spotify doesn't support playlist folders via API
@Model
final class PlaylistFolder {
    /// Unique identifier for the folder
    @Attribute(.unique) var id: UUID

    /// Display name of the folder
    var name: String

    /// Sort order for displaying folders
    var sortOrder: Int

    /// Whether the folder is expanded in the UI
    var isExpanded: Bool

    /// Spotify playlist IDs contained in this folder
    /// Using string array instead of relationship since Playlist isn't a @Model
    var playlistIds: [String]

    init(name: String, sortOrder: Int = 0, playlistIds: [String] = []) {
        self.id = UUID()
        self.name = name
        self.sortOrder = sortOrder
        self.isExpanded = true
        self.playlistIds = playlistIds
    }

    /// Adds a playlist to this folder
    func addPlaylist(_ playlistId: String) {
        if !playlistIds.contains(playlistId) {
            playlistIds.append(playlistId)
        }
    }

    /// Removes a playlist from this folder
    func removePlaylist(_ playlistId: String) {
        playlistIds.removeAll { $0 == playlistId }
    }

    /// Checks if this folder contains a specific playlist
    func containsPlaylist(_ playlistId: String) -> Bool {
        playlistIds.contains(playlistId)
    }
}
