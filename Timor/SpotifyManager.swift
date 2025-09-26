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
    @Published var selectedPlaylist: Playlist?
    @Published var isViewingLikedSongs = false
    @Published var lastError: String?
    @Published var showError = false
    @Published var lastCacheUpdate: Date?
    @Published var isUsingCache = false

    private let keychain = KeychainManager.shared
    private var modelContainer: ModelContainer?
    private var modelContext: ModelContext?
    private var shuffleTask: Task<Bool, Never>?
    private var fetchTask: Task<Void, Never>?
    private var currentFetchId = UUID()

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
        var isLiked: Bool = false

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
            let url = URL.applicationSupportDirectory.appending(path: Constants.Cache.cacheStoreFileName)
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
            updateAuthenticationState()
        }

        // Monitor Web API authentication state changes
        Task {
            for await _ in NotificationCenter.default.notifications(named: .init("SpotifyWebAPIAuthChanged")) {
                updateAuthenticationState()
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
            (try? keychain.retrieve(for: Constants.Keychain.clientIdKey)) ?? ""
        }
        set {
            try? keychain.save(newValue, for: Constants.Keychain.clientIdKey)
        }
    }

    var clientSecret: String {
        get {
            (try? keychain.retrieve(for: Constants.Keychain.clientSecretKey)) ?? ""
        }
        set {
            try? keychain.save(newValue, for: Constants.Keychain.clientSecretKey)
        }
    }

    var redirectURI: String {
        Constants.Spotify.redirectURI
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
            do {
                let webPlaylists = await SpotifyWebAPI.shared.fetchUserPlaylists()
                await MainActor.run {
                    self.playlists = webPlaylists
                    if webPlaylists.isEmpty && SpotifyWebAPI.shared.isAuthenticated {
                        self.lastError = "Failed to fetch playlists. Check your connection and try again."
                        self.showError = true
                    }
                }
            }
        }
    }

    func createPlaylist(name: String, description: String = "") async -> Bool {
        let playlistId = await SpotifyWebAPI.shared.createPlaylist(name: name, description: description, isPublic: false)

        if playlistId != nil {
            // Refresh playlists to show the new one
            fetchPlaylists()
            return true
        }
        return false
    }

    func deletePlaylist(_ playlistId: String) async -> Bool {
        let success = await SpotifyWebAPI.shared.deletePlaylist(playlistId: playlistId)
        if success {
            // Remove from local list
            await MainActor.run {
                self.playlists.removeAll { $0.id == playlistId }
            }
        }
        return success
    }

    func updatePlaylistTrackCount(_ playlistId: String, addedCount: Int) {
        // Update the track count for the playlist in our local list
        if let index = playlists.firstIndex(where: { $0.id == playlistId }) {
            let playlist = playlists[index]
            let updatedPlaylist = Playlist(
                id: playlist.id,
                name: playlist.name,
                totalTracks: playlist.totalTracks + addedCount,
                owner: playlist.owner,
                isEditable: playlist.isEditable
            )
            playlists[index] = updatedPlaylist
        }
    }

    func likeTrack(_ track: Track) async -> Bool {
        print("Attempting to like track: \(track.name) (ID: \(track.trackId))")
        let success = await SpotifyWebAPI.shared.saveTracks(trackIds: [track.trackId])
        if success {
            print("Successfully liked track: \(track.name)")
            // Update the local track's liked status
            await MainActor.run {
                if let index = self.currentPlaylistTracks.firstIndex(where: { $0.id == track.id }) {
                    self.currentPlaylistTracks[index].isLiked = true
                }
            }

            // Don't auto-refresh Liked Songs to avoid overwriting cache
        } else {
            print("Failed to like track: \(track.name)")
        }
        return success
    }

    func unlikeTrack(_ track: Track) async -> Bool {
        let success = await SpotifyWebAPI.shared.removeSavedTracks(trackIds: [track.trackId])
        if success {
            // Update the local track's liked status
            await MainActor.run {
                if let index = self.currentPlaylistTracks.firstIndex(where: { $0.id == track.id }) {
                    self.currentPlaylistTracks[index].isLiked = false
                }
            }

            // If viewing Liked Songs, just remove from current list
            if isViewingLikedSongs {
                await MainActor.run {
                    self.currentPlaylistTracks.removeAll { $0.trackId == track.trackId }
                }
            }
        }
        return success
    }

    func checkTracksLikedStatus() async {
        // Capture a snapshot of tracks to avoid range errors if the array changes
        let tracksSnapshot = currentPlaylistTracks
        guard !tracksSnapshot.isEmpty else { return }

        // Check all tracks in batches (Spotify API limit)
        for startIndex in stride(from: 0, to: tracksSnapshot.count, by: Constants.Spotify.trackCheckBatchSize) {
            let endIndex = min(startIndex + Constants.Spotify.trackCheckBatchSize, tracksSnapshot.count)
            let batch = Array(tracksSnapshot[startIndex..<endIndex])
            let trackIds = batch.map { $0.trackId }

            let likedStatuses = await SpotifyWebAPI.shared.checkSavedTracks(trackIds: trackIds)

            // Update the liked status for this batch
            await MainActor.run {
                for (batchIndex, isLiked) in likedStatuses.enumerated() {
                    let trackIndex = startIndex + batchIndex
                    // Find the track by ID to update it, in case the array order changed
                    if trackIndex < tracksSnapshot.count {
                        let trackToUpdate = tracksSnapshot[trackIndex]
                        if let currentIndex = self.currentPlaylistTracks.firstIndex(where: { $0.id == trackToUpdate.id }) {
                            self.currentPlaylistTracks[currentIndex].isLiked = isLiked
                        }
                    }
                }
            }
        }
    }

    func fetchLikedSongs() {
        print("Starting to fetch liked songs...")
        
        // Cancel any existing fetch operation
        fetchTask?.cancel()
        
        // Generate new fetch ID for this request
        let fetchId = UUID()
        currentFetchId = fetchId
        
        fetchTask = Task {
            // First, try to load from cache
            if let cachedTracks = loadLikedSongsFromCache() {
                print("Loaded \(cachedTracks.count) liked songs from cache")
                await MainActor.run {
                    self.currentPlaylistTracks = cachedTracks
                    self.isUsingCache = true
                    // Try to get cache date
                    if let cached = try? self.modelContext?.fetch(
                        FetchDescriptor<CachedPlaylist>(
                            predicate: #Predicate { $0.playlistId == "LIKED_SONGS" }
                        )
                    ).first {
                        self.lastCacheUpdate = cached.lastSynced
                    }
                }

                // Still fetch from API to check for updates
                await fetchAndUpdateLikedSongs()
            } else {
                // No cache, show loading and fetch
                isLoadingTracks = true
                loadingProgress = (0, 0)
                currentPlaylistTracks = []
                await fetchAndUpdateLikedSongs()
            }
        }
    }

    private func fetchAndUpdateLikedSongs() async {
        var allTracks: [Track] = []
        var offset = 0
        let limit = Constants.Spotify.likedSongsBatchSize
        var hasMore = true
        
        // Store the current fetch ID to check for cancellation
        let fetchId = currentFetchId

        while hasMore {
            // Check if this request was cancelled
            guard fetchId == currentFetchId else {
                print("Liked songs fetch cancelled")
                return
            }
            print("Fetching batch at offset \(offset)...")
            let result = await SpotifyWebAPI.shared.fetchLikedSongs(limit: limit, offset: offset)
            print("Got \(result.tracks.count) tracks in this batch")
            allTracks.append(contentsOf: result.tracks)

            // Update progress
            await MainActor.run {
                self.loadingProgress = (allTracks.count, result.total)
            }

            hasMore = allTracks.count < result.total && !result.tracks.isEmpty
            offset += limit
        }

        print("Finished fetching liked songs. Total: \(allTracks.count)")

        // Only cache if we got tracks (prevent overwriting with empty data)
        if !allTracks.isEmpty {
            cacheLikedSongs(allTracks)
        } else {
            print("WARNING: Received 0 liked songs from API - not updating cache")
        }

        await MainActor.run {
            self.currentPlaylistTracks = allTracks
            self.isLoadingTracks = false
            self.isUsingCache = false
            self.lastCacheUpdate = Date() // Fresh from API
        }
    }

    private func loadLikedSongsFromCache() -> [Track]? {
        guard let modelContext = modelContext else { return nil }

        let descriptor = FetchDescriptor<CachedPlaylist>(
            predicate: #Predicate { playlist in
                playlist.playlistId == "LIKED_SONGS"
            }
        )

        do {
            let cachedPlaylists = try modelContext.fetch(descriptor)
            guard let cached = cachedPlaylists.first,
                  let tracks = cached.tracks else {
                return nil
            }

            // Convert cached tracks to Track objects
            let sortedTracks = tracks.sorted { $0.position < $1.position }
            return sortedTracks.map { $0.toTrack() }
        } catch {
            print("Error loading liked songs from cache: \(error)")
            return nil
        }
    }

    private func cacheLikedSongs(_ tracks: [Track]) {
        guard let modelContext = modelContext else { return }

        let descriptor = FetchDescriptor<CachedPlaylist>(
            predicate: #Predicate { playlist in
                playlist.playlistId == "LIKED_SONGS"
            }
        )

        do {
            // Delete old cached liked songs
            let existing = try modelContext.fetch(descriptor)
            for cached in existing {
                if let tracks = cached.tracks {
                    for track in tracks {
                        modelContext.delete(track)
                    }
                }
                modelContext.delete(cached)
            }

            // Create new cached playlist for liked songs
            let cachedPlaylist = CachedPlaylist(
                playlistId: "LIKED_SONGS",
                name: "Liked Songs",
                owner: "You",
                totalTracks: tracks.count
            )

            // Create cached tracks
            let cachedTracks = tracks.enumerated().map { index, track in
                CachedTrack(
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
            }

            cachedPlaylist.tracks = cachedTracks
            for track in cachedTracks {
                track.playlist = cachedPlaylist
            }

            modelContext.insert(cachedPlaylist)
            try modelContext.save()

            print("Successfully cached \(tracks.count) liked songs")
        } catch {
            print("Error caching liked songs: \(error)")
        }
    }

    func fetchTracksForPlaylist(_ playlistId: String) {
        // Cancel any existing fetch operation
        fetchTask?.cancel()
        
        // Generate new fetch ID for this request
        let fetchId = UUID()
        currentFetchId = fetchId
        
        fetchTask = Task {
            // CRITICAL: Store the playlist ID we're fetching for validation
            let targetPlaylistId = playlistId

            guard currentFetchId == fetchId else { return } // Check if cancelled
            
            isLoadingTracks = true
            loadingProgress = (0, 0)
            currentPlaylistTracks = []  // Always clear current tracks first

            // First, try to load from cache WITH VALIDATION
            if let cachedTracks = await loadCachedTracks(for: targetPlaylistId) {
                // VALIDATE: Check we're still on the same playlist and not cancelled
                guard currentFetchId == fetchId && selectedPlaylist?.id == targetPlaylistId else {
                    print("Playlist changed or request cancelled during cache load")
                    return
                }

                await MainActor.run {
                    self.currentPlaylistTracks = cachedTracks
                    self.isLoadingTracks = false
                    self.isUsingCache = true
                    // Get cache date from SwiftData
                    if let cached = try? self.modelContext?.fetch(
                        FetchDescriptor<CachedPlaylist>(
                            predicate: #Predicate { $0.playlistId == targetPlaylistId }
                        )
                    ).first {
                        self.lastCacheUpdate = cached.lastSynced
                    }
                }

                // Check liked status for visible tracks
                Task {
                    await self.checkTracksLikedStatus()
                }

                // Fetch fresh data in background WITH PROPER VALIDATION
                Task.detached { [weak self] in
                    await self?.syncPlaylistInBackground(targetPlaylistId)
                }
            } else {
                // No cache, fetch from API
                let tracks = await SpotifyWebAPI.shared.fetchPlaylistTracks(
                    playlistId: targetPlaylistId,
                    progressHandler: { current, total in
                        Task { @MainActor in
                            self.loadingProgress = (current, total)
                        }
                    }
                )
                
                // Check if we got no tracks when we expected some
                if tracks.isEmpty && (selectedPlaylist?.totalTracks ?? 0) > 0 {
                    await MainActor.run {
                        self.lastError = "Failed to load playlist tracks. Please try again."
                        self.showError = true
                    }
                }

                // VALIDATE: Check we're still on the same playlist and not cancelled
                let stillValid = await MainActor.run { self.selectedPlaylist?.id == targetPlaylistId }
                guard currentFetchId == fetchId && stillValid else {
                    print("Playlist changed or request cancelled during API fetch")
                    return
                }

                await MainActor.run {
                    self.currentPlaylistTracks = tracks
                    self.isLoadingTracks = false
                    self.isUsingCache = false
                    self.lastCacheUpdate = Date() // Fresh from API
                }

                // Check liked status for visible tracks
                Task {
                    await self.checkTracksLikedStatus()
                }

                // Cache ONLY if we're still on the same playlist and not cancelled
                if currentFetchId == fetchId && selectedPlaylist?.id == targetPlaylistId {
                    await cachePlaylistTracks(playlistId: targetPlaylistId, tracks: tracks)
                }
            }
        }
    }

    private func loadCachedTracks(for playlistId: String) async -> [Track]? {
        guard let modelContext = modelContext else { return nil }

        // CRITICAL: Verify we're still trying to load the right playlist
        guard await MainActor.run(body: { self.selectedPlaylist?.id == playlistId }) else {
            print("WARNING: Attempting to load cache for playlist \(playlistId) but selected playlist has changed")
            return nil
        }

        let descriptor = FetchDescriptor<CachedPlaylist>(
            predicate: #Predicate { $0.playlistId == playlistId }
        )

        do {
            let cachedPlaylists = try modelContext.fetch(descriptor)
            if let cachedPlaylist = cachedPlaylists.first,
               let tracks = cachedPlaylist.tracks {

                // DOUBLE CHECK: Verify the playlist ID matches what we requested
                guard cachedPlaylist.playlistId == playlistId else {
                    print("CRITICAL ERROR: Cache returned wrong playlist! Requested: \(playlistId), Got: \(cachedPlaylist.playlistId)")
                    return nil
                }

                // Log what we're loading for debugging
                print("Loading \(tracks.count) cached tracks for playlist: \(cachedPlaylist.name) (ID: \(playlistId))")

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
        // CRITICAL VALIDATION: Only sync if this is still the selected playlist
        guard await MainActor.run(body: { self.selectedPlaylist?.id == playlistId }) else {
            print("Background sync aborted: playlist \(playlistId) is no longer selected")
            return
        }

        // Fetch fresh data from API
        let freshTracks = await SpotifyWebAPI.shared.fetchPlaylistTracks(
            playlistId: playlistId,
            progressHandler: nil
        )

        // SECOND VALIDATION: Check again before updating anything
        guard await MainActor.run(body: { self.selectedPlaylist?.id == playlistId }) else {
            print("Background sync aborted after fetch: playlist changed")
            return
        }

        // Compare with current tracks (but DON'T push changes to Spotify!)
        let currentTracks = await MainActor.run { self.currentPlaylistTracks }
        if freshTracks.count != currentTracks.count ||
           freshTracks.first?.trackId != currentTracks.first?.trackId ||
           freshTracks.last?.trackId != currentTracks.last?.trackId {

            // Playlist has changed on Spotify, update our LOCAL view only
            print("Playlist \(playlistId) has changed on Spotify, updating local view")

            // FINAL VALIDATION before updating
            guard await MainActor.run(body: { self.selectedPlaylist?.id == playlistId }) else {
                print("Background sync aborted before UI update: playlist changed")
                return
            }

            await MainActor.run {
                // Only update if we're STILL on this playlist
                if self.selectedPlaylist?.id == playlistId {
                    self.currentPlaylistTracks = freshTracks
                    // Update cache with fresh data from Spotify
                    Task {
                        await self.cachePlaylistTracks(playlistId: playlistId, tracks: freshTracks)
                    }
                }
            }
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
                // Update track count in sidebar
                self.updatePlaylistTrackCount(playlistId, addedCount: -tracks.count)
            }

            // Update cache with the modified playlist
            await cachePlaylistTracks(playlistId: playlistId, tracks: currentPlaylistTracks)
        }

        return success
    }

    func shuffleAndSavePlaylist(_ playlistId: String) async -> Bool {
        print("shuffleAndSavePlaylist called for playlist: \(playlistId)")

        // CRITICAL SAFETY CHECK: Verify playlist ID matches selected playlist
        guard let currentSelectedPlaylist = selectedPlaylist,
              currentSelectedPlaylist.id == playlistId else {
            print("ERROR: Playlist ID mismatch! Aborting shuffle to prevent overwrite.")
            return false
        }

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

            // SECOND SAFETY CHECK: Verify we're still on the same playlist
            guard let currentSelectedPlaylist = self.selectedPlaylist,
                  currentSelectedPlaylist.id == playlistId else {
                print("ERROR: Playlist changed during shuffle! Aborting.")
                return false
            }

            // Store original tracks in case we need to revert
            let originalTracks = currentPlaylistTracks
            let originalCount = originalTracks.count

            // Ensure we have tracks to shuffle
            guard !originalTracks.isEmpty else {
                print("No tracks to shuffle")
                return false
            }

            // VERIFY TRACK COUNT MATCHES PLAYLIST (skip for playlists we just modified)
            // Allow some flexibility for recently modified playlists
            let trackCountDifference = abs(originalCount - currentSelectedPlaylist.totalTracks)
            if trackCountDifference > Constants.Validation.trackCountDifferenceThreshold && currentSelectedPlaylist.totalTracks > 0 {
                print("WARNING: Large track count difference! Playlist reports \(currentSelectedPlaylist.totalTracks) but we have \(originalCount)")
                // Don't abort - the local count is likely more accurate if we just added/deleted tracks
            }

            // Shuffle the tracks
            let shuffledTracks = originalTracks.shuffled()
            print("Shuffled \(originalCount) tracks for playlist: \(currentSelectedPlaylist.name)")

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

            // FINAL SAFETY CHECK before API call
            guard self.selectedPlaylist?.id == playlistId else {
                print("ERROR: Playlist changed before API call! Reverting local changes.")
                self.currentPlaylistTracks = originalTracks
                return false
            }

            // Update the playlist on Spotify
            let success = await SpotifyWebAPI.shared.replacePlaylistTracks(
                playlistId: playlistId,
                trackUris: trackUris
            )

            if success {
                // Update cache with the modified playlist
            await cachePlaylistTracks(playlistId: playlistId, tracks: currentPlaylistTracks)

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
            // Update cache with the modified playlist
            await cachePlaylistTracks(playlistId: playlistId, tracks: currentPlaylistTracks)
        } else {
            // Revert on failure
            fetchTracksForPlaylist(playlistId)
        }
    }

    func exportPlaylistToCSV(playlistName: String) {
        // This function is already @MainActor, no need for thread check

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
                        let alert = NSAlert()
                        alert.messageText = "Export Successful"
                        alert.informativeText = "Playlist exported to: \(url.lastPathComponent)"
                        alert.alertStyle = .informational
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    } catch {
                        print("Error exporting CSV: \(error)")
                        // Show error alert
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

