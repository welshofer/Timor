//
//  SpotifyManager.swift
//  Timor
//
//  Manages Spotify authentication using Web API for macOS
//

import Foundation
import SwiftUI
import Combine
import TabularData
import AppKit
import UniformTypeIdentifiers
import SwiftData

@MainActor
class SpotifyManager: ObservableObject {
    static let shared = SpotifyManager()

    @Published var isAuthenticated = false
    @Published var playlists: [Playlist] = []
    @Published var currentTrack: String = ""
    @Published var currentPlaylistTracks: [Track] = []
    @Published var isLoadingTracks = false
    @Published var loadingProgress: (current: Int, total: Int) = (0, 0)

    private let keychain = KeychainManager.shared
    private var modelContainer: ModelContainer?
    private var modelContext: ModelContext?

    struct Playlist: Identifiable {
        let id: String
        let name: String
        let totalTracks: Int
        let owner: String
    }

    struct Track: Identifiable, Hashable {
        let id: String
        let trackId: String  // Original Spotify track ID
        let name: String
        let artist: String
        let album: String
        let releaseDate: String
        let duration: String
        let uri: String
    }

    private init() {
        setupWebAPIObserver()
        setupModelContainer()
    }

    private func setupModelContainer() {
        do {
            let schema = Schema([
                CachedPlaylist.self,
                CachedTrack.self
            ])
            // Use a separate store file to avoid conflicts with existing Item model
            let url = URL.applicationSupportDirectory.appending(path: "SpotifyCache.store")
            let modelConfiguration = ModelConfiguration(
                schema: schema,
                url: url,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
            modelContext = modelContainer?.mainContext
        } catch {
            print("Failed to create ModelContainer: \(error)")
        }
    }

    private func setupWebAPIObserver() {
        // Check initial authentication state
        Task {
            await updateAuthenticationState()
        }

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

    func fetchTracksForPlaylist(_ playlistId: String) {
        Task {
            isLoadingTracks = true
            loadingProgress = (0, 0)

            // First, try to load from cache
            if let cachedTracks = await loadCachedTracks(for: playlistId) {
                await MainActor.run {
                    self.currentPlaylistTracks = cachedTracks
                    self.isLoadingTracks = false
                }

                // Fetch fresh data in background to check for updates
                Task.detached { [weak self] in
                    await self?.syncPlaylistInBackground(playlistId)
                }
            } else {
                // No cache, fetch from API
                currentPlaylistTracks = []

                let tracks = await SpotifyWebAPI.shared.fetchPlaylistTracks(
                    playlistId: playlistId,
                    progressHandler: { current, total in
                        Task { @MainActor in
                            self.loadingProgress = (current, total)
                        }
                    }
                )

                await MainActor.run {
                    self.currentPlaylistTracks = tracks
                    self.isLoadingTracks = false
                }

                // Cache the fetched tracks
                await cachePlaylistTracks(playlistId: playlistId, tracks: tracks)
            }
        }
    }

    private func loadCachedTracks(for playlistId: String) async -> [Track]? {
        guard let modelContext = modelContext else { return nil }

        let descriptor = FetchDescriptor<CachedPlaylist>(
            predicate: #Predicate { $0.playlistId == playlistId }
        )

        do {
            let cachedPlaylists = try modelContext.fetch(descriptor)
            if let cachedPlaylist = cachedPlaylists.first,
               let tracks = cachedPlaylist.tracks {
                // Return tracks sorted by position
                return tracks
                    .sorted { $0.position < $1.position }
                    .map { $0.toTrack() }
            }
        } catch {
            print("Failed to load cached tracks: \(error)")
        }

        return nil
    }

    private func cachePlaylistTracks(playlistId: String, tracks: [Track]) async {
        guard let modelContext = modelContext else { return }

        // Find or create the cached playlist
        let descriptor = FetchDescriptor<CachedPlaylist>(
            predicate: #Predicate { $0.playlistId == playlistId }
        )

        do {
            let cachedPlaylists = try modelContext.fetch(descriptor)
            let cachedPlaylist: CachedPlaylist

            if let existing = cachedPlaylists.first {
                // Update existing playlist
                cachedPlaylist = existing
                // Delete old tracks properly
                if let oldTracks = cachedPlaylist.tracks {
                    for track in oldTracks {
                        modelContext.delete(track)
                    }
                }
                cachedPlaylist.tracks = []
            } else {
                // Create new cached playlist
                let playlist = playlists.first { $0.id == playlistId }
                cachedPlaylist = CachedPlaylist(
                    playlistId: playlistId,
                    name: playlist?.name ?? "",
                    owner: playlist?.owner ?? "",
                    totalTracks: tracks.count
                )
                modelContext.insert(cachedPlaylist)
            }

            // Add tracks to cache
            for (index, track) in tracks.enumerated() {
                let cachedTrack = CachedTrack(
                    trackId: track.trackId,
                    uniqueId: track.id,
                    name: track.name,
                    artist: track.artist,
                    album: track.album,
                    releaseDate: track.releaseDate,
                    duration: track.duration,
                    uri: track.uri,
                    position: index
                )
                cachedTrack.playlist = cachedPlaylist
                modelContext.insert(cachedTrack)
            }

            cachedPlaylist.lastSynced = Date()
            cachedPlaylist.totalTracks = tracks.count

            try modelContext.save()
        } catch {
            print("Failed to cache playlist tracks: \(error)")
        }
    }

    private func syncPlaylistInBackground(_ playlistId: String) async {
        // Fetch fresh data from API
        let freshTracks = await SpotifyWebAPI.shared.fetchPlaylistTracks(
            playlistId: playlistId,
            progressHandler: nil
        )

        // Compare with current tracks (simple comparison by count and first/last track)
        if freshTracks.count != currentPlaylistTracks.count ||
           freshTracks.first?.id != currentPlaylistTracks.first?.id ||
           freshTracks.last?.id != currentPlaylistTracks.last?.id {
            // Playlist has changed, update UI and cache
            await MainActor.run {
                self.currentPlaylistTracks = freshTracks
            }
            await cachePlaylistTracks(playlistId: playlistId, tracks: freshTracks)
        }
    }

    func deleteTracksFromPlaylist(_ playlistId: String, tracks: Set<Track>) async -> Bool {
        // Group tracks by URI and collect their positions
        var trackPositions: [String: [Int]] = [:]

        for (index, track) in currentPlaylistTracks.enumerated() {
            if tracks.contains(where: { $0.id == track.id }) {
                if trackPositions[track.uri] == nil {
                    trackPositions[track.uri] = []
                }
                trackPositions[track.uri]?.append(index)
            }
        }

        // Prepare arrays for the API call
        let trackUris = Array(trackPositions.keys)
        let positions = trackUris.map { trackPositions[$0] ?? [] }

        // Call the API to delete tracks
        let success = await SpotifyWebAPI.shared.deletePlaylistTracks(
            playlistId: playlistId,
            trackUris: trackUris,
            positions: positions
        )

        if success {
            // Remove deleted tracks from our local copy
            await MainActor.run {
                self.currentPlaylistTracks.removeAll { track in
                    tracks.contains(where: { $0.id == track.id })
                }
            }

            // Update the cache
            await cachePlaylistTracks(playlistId: playlistId, tracks: currentPlaylistTracks)
        }

        return success
    }

    func shuffleAndSavePlaylist(_ playlistId: String) async -> Bool {
        // Shuffle the tracks
        let shuffledTracks = currentPlaylistTracks.shuffled()
        let trackUris = shuffledTracks.map { $0.uri }

        // Update our local copy IMMEDIATELY for responsive UI
        await MainActor.run {
            self.currentPlaylistTracks = shuffledTracks
        }

        // Update the playlist on Spotify
        let success = await SpotifyWebAPI.shared.replacePlaylistTracks(
            playlistId: playlistId,
            trackUris: trackUris
        )

        if success {
            // Update the cache with shuffled order
            await cachePlaylistTracks(playlistId: playlistId, tracks: shuffledTracks)
        } else {
            // Revert if failed
            await MainActor.run {
                // Fetch the original order again
                self.fetchTracksForPlaylist(playlistId)
            }
        }

        return success
    }

    func exportPlaylistToCSV(playlistName: String) {
        // Ensure we're on the main thread for UI operations
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.exportPlaylistToCSV(playlistName: playlistName)
            }
            return
        }

        // Show save panel
        let savePanel = NSSavePanel()
        savePanel.title = "Export Playlist as CSV"
        savePanel.prompt = "Export"
        savePanel.nameFieldStringValue = "\(playlistName).csv"
        savePanel.allowedContentTypes = [.commaSeparatedText]
        savePanel.allowsOtherFileTypes = false
        savePanel.canCreateDirectories = true

        savePanel.begin { [weak self] response in
            guard let self = self else { return }

            if response == .OK, let url = savePanel.url {
                Task {
                    do {
                        // Create a DataFrame from the current playlist tracks
                        var dataFrame = DataFrame()

                        // Create columns with the track data
                        let tracks = await MainActor.run {
                            self.currentPlaylistTracks
                        }

                        let titles = tracks.map { $0.name }
                        let artists = tracks.map { $0.artist }
                        let albums = tracks.map { $0.album }
                        let releaseDates = tracks.map { $0.releaseDate }
                        let durations = tracks.map { $0.duration }
                        let spotifyURIs = tracks.map { $0.uri }

                        // Add columns to DataFrame
                        dataFrame.append(column: Column(name: "Title", contents: titles))
                        dataFrame.append(column: Column(name: "Artist", contents: artists))
                        dataFrame.append(column: Column(name: "Album", contents: albums))
                        dataFrame.append(column: Column(name: "Release Date", contents: releaseDates))
                        dataFrame.append(column: Column(name: "Duration", contents: durations))
                        dataFrame.append(column: Column(name: "Spotify URI", contents: spotifyURIs))

                        // Write CSV data to file
                        try dataFrame.writeCSV(to: url)
                        print("Successfully exported playlist to: \(url.path)")

                        // Show success message
                        await MainActor.run {
                            let alert = NSAlert()
                            alert.messageText = "Export Successful"
                            alert.informativeText = "Playlist exported to: \(url.lastPathComponent)"
                            alert.alertStyle = .informational
                            alert.addButton(withTitle: "OK")
                            alert.runModal()
                        }
                    } catch {
                        print("Error exporting CSV: \(error)")
                        // Show error alert
                        await MainActor.run {
                            let alert = NSAlert()
                            alert.messageText = "Export Failed"
                            alert.informativeText = "Failed to export playlist: \(error.localizedDescription)"
                            alert.alertStyle = .warning
                            alert.addButton(withTitle: "OK")
                            alert.runModal()
                        }
                    }
                }
            }
        }
    }
}

