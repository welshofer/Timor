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

extension UTType {
    static var spotifyTrack: UTType = UTType(exportedAs: "xsf.welshofer.Timor.spotifytrack")
}

@MainActor
class SpotifyManager: ObservableObject {
    static let shared = SpotifyManager()

    @Published var isAuthenticated = false
    @Published var playlists: [Playlist] = []
    @Published var currentTrack: String = ""
    @Published var currentPlaylistTracks: [Track] = []
    @Published var isLoadingTracks = false
    @Published var loadingProgress: (current: Int, total: Int) = (0, 0)
    @Published var isShuffling = false

    private let keychain = KeychainManager.shared
    private var modelContainer: ModelContainer?
    private var modelContext: ModelContext?
    private var shuffleTask: Task<Bool, Never>?

    struct Playlist: Identifiable {
        let id: String
        let name: String
        let totalTracks: Int
        let owner: String
        let isEditable: Bool
    }

    struct Track: Identifiable, Hashable, Codable, Transferable {
        let id: String
        let trackId: String  // Original Spotify track ID
        let name: String
        let artist: String
        let album: String
        let releaseDate: String
        let duration: String
        let uri: String

        static var transferRepresentation: some TransferRepresentation {
            CodableRepresentation(contentType: .spotifyTrack)
        }
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

        // Important: Verify track count before caching
        let trackCount = tracks.count
        guard trackCount > 0 else {
            print("WARNING: Attempting to cache empty track list, aborting")
            return
        }

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

                // Delete old tracks properly in batch
                if let oldTracks = cachedPlaylist.tracks {
                    print("Deleting \(oldTracks.count) old cached tracks for playlist update")
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
                    totalTracks: trackCount
                )
                modelContext.insert(cachedPlaylist)
            }

            // Create all new cached tracks
            var newTracks: [CachedTrack] = []
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
                newTracks.append(cachedTrack)
            }

            cachedPlaylist.tracks = newTracks
            cachedPlaylist.lastSynced = Date()
            cachedPlaylist.totalTracks = trackCount

            // Save atomically
            try modelContext.save()
            print("Successfully cached \(trackCount) tracks for playlist \(playlistId)")

            // Verify the save was successful
            let verifyDescriptor = FetchDescriptor<CachedPlaylist>(
                predicate: #Predicate { $0.playlistId == playlistId }
            )
            let verifyResult = try modelContext.fetch(verifyDescriptor)
            if let savedPlaylist = verifyResult.first,
               let savedTracks = savedPlaylist.tracks {
                print("Verified: \(savedTracks.count) tracks saved in cache")
                if savedTracks.count != trackCount {
                    print("ERROR: Track count mismatch after save! Expected: \(trackCount), Got: \(savedTracks.count)")
                }
            }
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
        print("shuffleAndSavePlaylist called for playlist: \(playlistId)")

        // Cancel any existing shuffle operation
        shuffleTask?.cancel()

        // Check and set shuffling state
        let canProceed = await MainActor.run {
            if self.isShuffling {
                print("Shuffle already in progress, ignoring request")
                return false
            }
            self.isShuffling = true
            print("Setting isShuffling to true")
            return true
        }

        guard canProceed else {
            return false
        }

        // Create new shuffle task
        let task = Task<Bool, Never> { @MainActor in
            defer {
                self.isShuffling = false
            }

            // Store original tracks in case we need to revert
            let originalTracks = currentPlaylistTracks
            let originalCount = originalTracks.count

            // Ensure we have tracks to shuffle
            guard !originalTracks.isEmpty else {
                print("No tracks to shuffle")
                return false
            }

            // Shuffle the tracks
            let shuffledTracks = originalTracks.shuffled()
            print("Shuffled \(originalCount) tracks")

            // Verify we didn't lose tracks
            guard shuffledTracks.count == originalCount else {
                print("Track count mismatch during shuffle! Original: \(originalCount), Shuffled: \(shuffledTracks.count)")
                return false
            }

            let trackUris = shuffledTracks.map { $0.uri }

            // Check for cancellation
            if Task.isCancelled {
                return false
            }

            // Update our local copy IMMEDIATELY for responsive UI
            self.currentPlaylistTracks = shuffledTracks

            // Update the playlist on Spotify
            let success = await SpotifyWebAPI.shared.replacePlaylistTracks(
                playlistId: playlistId,
                trackUris: trackUris
            )

            if success {
                // Update the cache with shuffled order
                await cachePlaylistTracks(playlistId: playlistId, tracks: shuffledTracks)

                // Final verification
                let finalCount = self.currentPlaylistTracks.count
                if finalCount != originalCount {
                    print("WARNING: Track count changed after shuffle! Expected: \(originalCount), Got: \(finalCount)")
                }
            } else {
                // Revert to original tracks if failed
                self.currentPlaylistTracks = originalTracks
            }

            return success
        }

        shuffleTask = task
        return await task.value
    }

    func reorderTracks(in playlistId: String, from source: IndexSet, to destination: Int) async {
        // Convert indices to track positions
        var tracks = currentPlaylistTracks

        // Perform the move locally first for immediate UI feedback
        tracks.move(fromOffsets: source, toOffset: destination)

        await MainActor.run {
            self.currentPlaylistTracks = tracks
        }

        // Calculate the API parameters
        // source contains the original indices, destination is where they should go
        guard let firstIndex = source.first else { return }
        let rangeLength = source.count

        // Adjust destination index based on move direction
        let insertBefore = destination > firstIndex ? destination - rangeLength : destination

        // Call Spotify API to persist the change
        let success = await SpotifyWebAPI.shared.reorderPlaylistTracks(
            playlistId: playlistId,
            rangeStart: firstIndex,
            insertBefore: insertBefore,
            rangeLength: rangeLength
        )

        if success {
            // Update cache with new order
            await cachePlaylistTracks(playlistId: playlistId, tracks: tracks)
        } else {
            // Revert on failure
            await fetchTracksForPlaylist(playlistId)
        }
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

