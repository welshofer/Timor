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
    @Attribute(.unique) var playlistId: String
    var name: String
    var owner: String
    var totalTracks: Int
    var lastSynced: Date
    var snapshotId: String? // Spotify's snapshot ID for detecting changes

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
    var trackId: String
    var uniqueId: String // Combination of trackId + position
    var name: String
    var artist: String
    var album: String
    var releaseDate: String
    var duration: String
    var uri: String
    var position: Int // Track position in playlist

    var playlist: CachedPlaylist?

    init(trackId: String, uniqueId: String, name: String, artist: String,
         album: String, releaseDate: String, duration: String, uri: String, position: Int) {
        self.trackId = trackId
        self.uniqueId = uniqueId
        self.name = name
        self.artist = artist
        self.album = album
        self.releaseDate = releaseDate
        self.duration = duration
        self.uri = uri
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
            uri: uri
        )
    }
}