//
//  Constants.swift
//  Timor
//
//  App-wide constants and configuration
//

import Foundation

enum Constants {
    enum Spotify {
        // API Limits
        static let playlistFetchLimit = 50
        static let trackFetchLimit = 100
        static let searchResultLimit = 50
        static let likedSongsBatchSize = 50
        static let trackCheckBatchSize = 50
        
        // API Endpoints
        static let baseURL = "https://api.spotify.com/v1"
        static let tokenURL = "https://accounts.spotify.com/api/token"
        static let authURL = "https://accounts.spotify.com/authorize"
        
        // OAuth Configuration
        static let redirectURI = "timor://spotify-callback"
        static let scopes = "playlist-read-private playlist-read-collaborative playlist-modify-public playlist-modify-private user-read-private user-library-read user-library-modify"
    }
    
    enum UI {
        // Layout
        static let sidebarMinWidth: CGFloat = 250
        static let sidebarIdealWidth: CGFloat = 300
        static let trackSearchWidth: CGFloat = 800
        static let trackSearchHeight: CGFloat = 600
        static let createPlaylistWidth: CGFloat = 400
        static let createPlaylistHeight: CGFloat = 250
        
        // Table Column Widths
        static let titleColumnMinWidth: CGFloat = 200
        static let artistColumnMinWidth: CGFloat = 150
        static let albumColumnMinWidth: CGFloat = 150
        static let releaseDateColumnWidth: CGFloat = 120
        static let durationColumnWidth: CGFloat = 80
        static let likeButtonColumnWidth: CGFloat = 30
        
        // Padding
        static let defaultPadding: CGFloat = 12
        static let compactPadding: CGFloat = 8
        static let sectionSpacing: CGFloat = 20
    }
    
    enum Cache {
        static let playlistCacheKey = "cached_playlists"
        static let likedSongsCacheId = "LIKED_SONGS"
        static let cacheStoreFileName = "SpotifyCache.store"
    }
    
    enum Keychain {
        static let service = "com.timor.spotify"
        static let clientIdKey = "spotify_client_id"
        static let clientSecretKey = "spotify_client_secret"
        static let accessTokenKey = "spotify_web_access_token"
        static let refreshTokenKey = "spotify_web_refresh_token"
    }
    
    enum Animation {
        static let shuffleDelay: UInt64 = 1_000_000_000 // 1 second in nanoseconds
    }
    
    enum Validation {
        static let trackCountDifferenceThreshold = 10 // Warning threshold for track count mismatch
    }
}