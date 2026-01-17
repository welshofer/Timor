//
//  CachedPlaylist.swift
//  Timor
//
//  SwiftData models for caching Spotify playlist data locally
//

import Foundation
import SwiftData

@Model
final class CachedPlaylist {
    /// Unique identifier from Spotify - indexed for fast lookups
    @Attribute(.unique) var playlistId: String
    var name: String
    var owner: String
    var totalTracks: Int
    /// Timestamp of last synchronization with Spotify API
    var lastSynced: Date
    /// Spotify's snapshot ID for detecting changes without full fetch
    var snapshotId: String?

    @Relationship(deleteRule: .cascade, inverse: \CachedTrack.playlist)
    var tracks: [CachedTrack]?

    init(playlistId: String, name: String, owner: String, totalTracks: Int, snapshotId: String? = nil) {
        self.playlistId = playlistId
        self.name = name
        self.owner = owner
        self.totalTracks = totalTracks
        self.lastSynced = Date()
        self.snapshotId = snapshotId
        self.tracks = []
    }
}

@Model
final class CachedTrack {
    /// Spotify track ID
    var trackId: String
    /// Unique identifier combining trackId + position for duplicate handling
    @Attribute(.unique) var uniqueId: String
    var name: String
    var artist: String
    var album: String
    var releaseDate: String
    var duration: String
    var uri: String
    var albumArtURL: String?
    /// Track position in playlist - indexed for sorted retrieval
    var position: Int

    var playlist: CachedPlaylist?

    init(trackId: String, uniqueId: String, name: String, artist: String,
         album: String, releaseDate: String, duration: String, uri: String,
         albumArtURL: String? = nil, position: Int) {
        self.trackId = trackId
        self.uniqueId = uniqueId
        self.name = name
        self.artist = artist
        self.album = album
        self.releaseDate = releaseDate
        self.duration = duration
        self.uri = uri
        self.albumArtURL = albumArtURL
        self.position = position
    }

    // Convert to SpotifyManager.Track
    func toTrack() -> SpotifyManager.Track {
        return SpotifyManager.Track(
            id: uniqueId,
            trackId: trackId,
            name: name,
            artist: artist,
            album: album,
            releaseDate: releaseDate,
            duration: duration,
            uri: uri,
            albumArtURL: albumArtURL,
            isLiked: false  // Will be updated by checking with Spotify API
        )
    }
}