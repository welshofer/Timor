//
//  SpotifyManager.swift
//  Timor
//
//  Manages Spotify authentication using Web API for macOS
//

import Foundation
import SwiftUI
import Combine

@MainActor
class SpotifyManager: ObservableObject {
    static let shared = SpotifyManager()

    @Published var isAuthenticated = false
    @Published var playlists: [Playlist] = []
    @Published var currentTrack: String = ""

    private let keychain = KeychainManager.shared

    struct Playlist: Identifiable {
        let id: String
        let name: String
        let totalTracks: Int
        let owner: String
    }

    private init() {
        setupWebAPIObserver()
    }

    private func setupWebAPIObserver() {
        // Monitor Web API authentication state changes
        Task {
            for await _ in NotificationCenter.default.notifications(named: .init("SpotifyWebAPIAuthChanged")) {
                await updateAuthenticationState()
            }
        }
    }

    private func updateAuthenticationState() {
        isAuthenticated = SpotifyWebAPI.shared.isAuthenticated
        if isAuthenticated {
            fetchPlaylists()
        }
    }

    var clientID: String {
        get {
            (try? keychain.retrieve(for: "spotify_client_id")) ?? ""
        }
        set {
            try? keychain.save(newValue, for: "spotify_client_id")
        }
    }

    var clientSecret: String {
        get {
            (try? keychain.retrieve(for: "spotify_client_secret")) ?? ""
        }
        set {
            try? keychain.save(newValue, for: "spotify_client_secret")
        }
    }

    var redirectURI: String {
        "timor://spotify-callback"
    }

    func authenticate() {
        SpotifyWebAPI.shared.authenticate()
    }

    func logout() {
        SpotifyWebAPI.shared.logout()
        isAuthenticated = false
        playlists = []
        currentTrack = ""
    }

    func fetchPlaylists() {
        Task {
            let webPlaylists = await SpotifyWebAPI.shared.fetchUserPlaylists()
            await MainActor.run {
                self.playlists = webPlaylists
            }
        }
    }
}

