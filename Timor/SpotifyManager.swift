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
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import UniformTypeIdentifiers
import SwiftData
import os.log
import Network

extension UTType {
    static var spotifyTrack: UTType {
        UTType(exportedAs: "xsf.welshofer.Timor.spotifytrack")
    }
}

// MARK: - Logging
private nonisolated(unsafe) let spotifyLogger = Logger(subsystem: "com.timor", category: "spotify-manager")

// MARK: - Concurrency Primitives

/// Represents an atomic playlist loading operation to prevent race conditions.
///
/// ## Race Condition Prevention Pattern
///
/// When users rapidly switch between playlists, multiple async fetch operations can
/// overlap. Without coordination, a slow fetch for Playlist A could complete after
/// a fast fetch for Playlist B, causing Playlist A's tracks to appear when viewing B.
///
/// This struct provides operation identity for validation at critical checkpoints:
///
/// ```
/// 1. Create operation with unique UUID
/// 2. Store as currentLoadOperation
/// 3. Start async fetch
/// 4. At each state mutation point, verify:
///    - currentLoadOperation?.id == operation.id (operation still valid)
///    - currentLoadOperation?.playlistId == expectedId (playlist unchanged)
/// 5. If validation fails, abort silently (newer operation supersedes)
/// ```
///
/// **Checkpoint Locations** (search for `currentLoadOperation?.id ==`):
/// - Before updating `currentPlaylistTracks`
/// - Before updating `isLoadingTracks`
/// - Before caching fetched tracks
/// - Before updating `loadingProgress`
///
/// - Note: This is a defensive pattern for UI-bound async operations where user
///   intent (which playlist to view) can change during long-running network requests.
private struct PlaylistLoadOperation: Equatable {
    /// Unique identifier for this specific fetch operation
    let id: UUID

    /// The playlist being fetched (used for double-validation)
    let playlistId: String

    /// When the operation started (for debugging/metrics)
    let startTime: Date

    static func == (lhs: PlaylistLoadOperation, rhs: PlaylistLoadOperation) -> Bool {
        lhs.id == rhs.id && lhs.playlistId == rhs.playlistId
    }
}

@MainActor
class SpotifyManager: ObservableObject {
    static let shared = SpotifyManager()

    // MARK: - Logging
    private static let logger = Logger(subsystem: "com.timor.spotify", category: "SpotifyManager")

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
    @Published var lastErrorRecovery: String?
    @Published var showError = false
    /// USE-5: transient, non-error status message (e.g. the result of a bulk like/unlike).
    @Published var infoMessage: String?
    @Published var lastCacheUpdate: Date?
    @Published var isUsingCache = false
    @Published var modelContainerFailed = false

    /// Export status for cross-platform alert handling
    @Published var exportSuccess: Bool?
    @Published var exportMessage: String?

    /// Network connectivity state
    @Published var isOnline = true
    @Published var connectionType: ConnectionType = .unknown

    /// Tracks whether credentials are configured (for UI reactivity)
    @Published var hasCredentials = false

    enum ConnectionType {
        case unknown
        case wifi
        case cellular
        case wired
        case other

        var description: String {
            switch self {
            case .unknown: return "Unknown"
            case .wifi: return "Wi-Fi"
            case .cellular: return "Cellular"
            case .wired: return "Ethernet"
            case .other: return "Connected"
            }
        }
    }

    /// Undo manager for playlist operations
    let playlistUndoManager = PlaylistUndoManager()

    private let keychain = KeychainManager.shared
    private var modelContainer: ModelContainer?
    private var modelContext: ModelContext?
    private var shuffleTask: Task<Bool, Never>?
    private var fetchTask: Task<Void, Never>?
    private var currentLoadOperation: PlaylistLoadOperation?
    private var authObserverTask: Task<Void, Never>?
    private var networkMonitor: NWPathMonitor?
    private let networkQueue = DispatchQueue(label: "com.timor.network-monitor")

    struct Playlist: Identifiable {
        let id: String
        let name: String
        let totalTracks: Int
        let owner: String
        let description: String?
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
        let albumArtURL: String?
        var isLiked: Bool = false

        /// FUNC-2: parsed duration in seconds, for correct *numeric* sorting. The `duration`
        /// string is "M:SS", which sorts incorrectly as text ("10:05" before "9:30").
        var durationSeconds: Int {
            let parts = duration.split(separator: ":")
            guard parts.count == 2,
                  let minutes = Int(parts[0]),
                  let seconds = Int(parts[1]) else {
                return 0
            }
            return minutes * 60 + seconds
        }

        /// FUNC-1: human-readable release date. `releaseDate` itself stores the RAW Spotify
        /// value ("2023-10-15") so year/decade extraction and chronological sort work; this
        /// formats it for display ("Oct 15, 2023").
        var displayReleaseDate: String {
            SpotifyDateFormatters.formatRelease(releaseDate)
        }

        static var transferRepresentation: some TransferRepresentation {
            CodableRepresentation(contentType: .spotifyTrack)
        }
    }

    private init() {
        setupModelContainer()
        setupWebAPIObserver()
        setupNetworkMonitor()
        updateHasCredentials()
    }

    deinit {
        authObserverTask?.cancel()
        networkMonitor?.cancel()
    }

    // MARK: - Network Monitoring

    private func setupNetworkMonitor() {
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.updateNetworkStatus(path)
            }
        }
        networkMonitor?.start(queue: networkQueue)
    }

    private func updateNetworkStatus(_ path: NWPath) {
        let wasOnline = isOnline
        isOnline = path.status == .satisfied

        // Determine connection type
        if path.usesInterfaceType(.wifi) {
            connectionType = .wifi
        } else if path.usesInterfaceType(.cellular) {
            connectionType = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            connectionType = .wired
        } else if path.status == .satisfied {
            connectionType = .other
        } else {
            connectionType = .unknown
        }

        // Log transitions
        if wasOnline && !isOnline {
            spotifyLogger.info("Network went offline")
        } else if !wasOnline && isOnline {
            spotifyLogger.info("Network came back online via \(self.connectionType.description)")
            // Refresh data when coming back online
            if isAuthenticated {
                fetchPlaylists()
            }
        }
    }

    private func setupModelContainer() {
        do {
            let schema = Schema([
                CachedPlaylist.self,
                CachedTrack.self,
                PlaylistFolder.self
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
            Self.logger.info("ModelContainer initialized successfully")
        } catch {
            Self.logger.error("Failed to create ModelContainer: \(error.localizedDescription, privacy: .public)")
            modelContainerFailed = true

            // Try once more with a fresh database
            retryModelContainerSetup()
        }
    }

    private func retryModelContainerSetup() {
        Self.logger.info("Attempting ModelContainer recovery...")
        do {
            let schema = Schema([
                CachedPlaylist.self,
                CachedTrack.self,
                PlaylistFolder.self
            ])
            let url = URL.applicationSupportDirectory.appending(path: Constants.Cache.cacheStoreFileName)

            // STAB-4: don't destroy the user's cache on a single transient failure.
            // Move the (possibly recoverable) store aside instead of deleting it, so the
            // data can be recovered/inspected later rather than being silently lost.
            let backupURL = url.appendingPathExtension("corrupt")
            let fileManager = FileManager.default
            for suffix in ["", "shm", "wal"] {
                let source = suffix.isEmpty ? url : url.appendingPathExtension(suffix)
                let destination = suffix.isEmpty ? backupURL : backupURL.appendingPathExtension(suffix)
                try? fileManager.removeItem(at: destination)  // clear any prior backup
                try? fileManager.moveItem(at: source, to: destination)
            }

            let modelConfiguration = ModelConfiguration(
                schema: schema,
                url: url,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
            modelContext = modelContainer?.mainContext
            modelContainerFailed = false
            Self.logger.info("ModelContainer recovery successful")
        } catch {
            Self.logger.error("ModelContainer recovery failed: \(error.localizedDescription, privacy: .public)")
            // Continue without caching - app will still work but slower
            displayError(
                "Cache initialization failed",
                recovery: "The app will still work, but playlists won't be cached locally."
            )
        }
    }

    private func setupWebAPIObserver() {
        // Check initial authentication state
        Task {
            updateAuthenticationState()
        }

        // Monitor Web API authentication state changes with proper lifecycle
        authObserverTask = Task {
            for await _ in NotificationCenter.default.notifications(named: .init("SpotifyWebAPIAuthChanged")) {
                guard !Task.isCancelled else { break }
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
            do {
                try keychain.save(newValue, for: Constants.Keychain.clientIdKey)
                Self.logger.info("Successfully saved clientID to keychain")
                updateHasCredentials()
            } catch {
                Self.logger.error("Failed to save clientID to keychain: \(error.localizedDescription)")
            }
        }
    }

    var clientSecret: String {
        get {
            (try? keychain.retrieve(for: Constants.Keychain.clientSecretKey)) ?? ""
        }
        set {
            do {
                try keychain.save(newValue, for: Constants.Keychain.clientSecretKey)
                Self.logger.info("Successfully saved clientSecret to keychain")
                updateHasCredentials()
            } catch {
                Self.logger.error("Failed to save clientSecret to keychain: \(error.localizedDescription)")
            }
        }
    }

    /// Updates the hasCredentials published property for UI reactivity
    private func updateHasCredentials() {
        hasCredentials = !clientID.isEmpty && !clientSecret.isEmpty
    }

    /// STAB-3: Saves credentials to the Keychain, surfacing any failure to the caller.
    /// Unlike the `clientID`/`clientSecret` setters (which swallow errors), this throws so
    /// the UI can avoid reporting a false "saved" success when the Keychain write fails.
    func saveCredentials(clientID newClientID: String, clientSecret newClientSecret: String) throws {
        try keychain.save(newClientID, for: Constants.Keychain.clientIdKey)
        try keychain.save(newClientSecret, for: Constants.Keychain.clientSecretKey)
        updateHasCredentials()
        Self.logger.info("Saved Spotify credentials to keychain")
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

    // MARK: - Error Handling

    /// Display a user-facing error with optional recovery suggestion
    func displayError(_ error: Error) {
        if let spotifyError = error as? SpotifyError {
            lastError = spotifyError.localizedDescription
            lastErrorRecovery = spotifyError.recoverySuggestion
        } else if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                lastError = "No internet connection"
                lastErrorRecovery = "Check your connection and try again."
            case .timedOut:
                lastError = "Request timed out"
                lastErrorRecovery = "Spotify may be slow. Try again."
            case .cancelled:
                // Don't show error for cancelled requests
                return
            default:
                lastError = "Network error"
                lastErrorRecovery = "Check your connection and try again."
            }
        } else {
            lastError = error.localizedDescription
            lastErrorRecovery = nil
        }
        showError = true
    }

    /// Display a user-facing error with a custom message and optional recovery
    func displayError(_ message: String, recovery: String? = nil) {
        lastError = message
        lastErrorRecovery = recovery
        showError = true
    }

    func fetchPlaylists() {
        Task {
            do {
                let webPlaylists = await SpotifyWebAPI.shared.fetchUserPlaylists()
                await MainActor.run {
                    self.playlists = webPlaylists
                    if webPlaylists.isEmpty && SpotifyWebAPI.shared.isAuthenticated {
                        self.displayError(
                            "Couldn't fetch your playlists",
                            recovery: "Check your internet connection and try refreshing."
                        )
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
                description: playlist.description,
                isEditable: playlist.isEditable
            )
            playlists[index] = updatedPlaylist
        }
    }

    func likeTrack(_ track: Track) async -> Bool {
        spotifyLogger.debug("Attempting to like track: \(track.name) (ID: \(track.trackId))")
        let success = await SpotifyWebAPI.shared.saveTracks(trackIds: [track.trackId])
        if success {
            spotifyLogger.info("Successfully liked track: \(track.name)")
            // Update the local track's liked status
            await MainActor.run {
                if let index = self.currentPlaylistTracks.firstIndex(where: { $0.id == track.id }) {
                    self.currentPlaylistTracks[index].isLiked = true
                }
            }

            // Don't auto-refresh Liked Songs to avoid overwriting cache
        } else {
            spotifyLogger.error("Failed to like track: \(track.name)")
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

    // MARK: - Bulk Like/Unlike

    /// Likes multiple tracks at once (max 50 per batch)
    func bulkLikeTracks(_ tracks: [Track]) async -> (succeeded: Int, failed: Int) {
        guard !tracks.isEmpty else { return (0, 0) }

        let batchSize = Constants.Spotify.bulkLikeLimit
        var succeeded = 0
        var failed = 0

        // Filter to only unlike tracks
        let tracksToLike = tracks.filter { !$0.isLiked }
        guard !tracksToLike.isEmpty else { return (0, 0) }

        // Process in batches
        for batchStart in stride(from: 0, to: tracksToLike.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, tracksToLike.count)
            let batch = Array(tracksToLike[batchStart..<batchEnd])
            let trackIds = batch.map { $0.trackId }

            let success = await SpotifyWebAPI.shared.saveTracks(trackIds: trackIds)
            if success {
                succeeded += batch.count
                // Update local liked status
                await MainActor.run {
                    for track in batch {
                        if let index = self.currentPlaylistTracks.firstIndex(where: { $0.id == track.id }) {
                            self.currentPlaylistTracks[index].isLiked = true
                        }
                    }
                }
            } else {
                failed += batch.count
            }
        }

        Self.logger.info("Bulk like completed: \(succeeded) succeeded, \(failed) failed")
        infoMessage = failed == 0
            ? "Liked \(succeeded) track\(succeeded == 1 ? "" : "s")"
            : "Liked \(succeeded) of \(succeeded + failed) — \(failed) failed"
        return (succeeded, failed)
    }

    /// Unlikes multiple tracks at once (max 50 per batch)
    func bulkUnlikeTracks(_ tracks: [Track]) async -> (succeeded: Int, failed: Int) {
        guard !tracks.isEmpty else { return (0, 0) }

        let batchSize = Constants.Spotify.bulkLikeLimit
        var succeeded = 0
        var failed = 0

        // Filter to only liked tracks
        let tracksToUnlike = tracks.filter { $0.isLiked }
        guard !tracksToUnlike.isEmpty else { return (0, 0) }

        // Process in batches
        for batchStart in stride(from: 0, to: tracksToUnlike.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, tracksToUnlike.count)
            let batch = Array(tracksToUnlike[batchStart..<batchEnd])
            let trackIds = batch.map { $0.trackId }

            let success = await SpotifyWebAPI.shared.removeSavedTracks(trackIds: trackIds)
            if success {
                succeeded += batch.count
                // Update local liked status
                await MainActor.run {
                    for track in batch {
                        if let index = self.currentPlaylistTracks.firstIndex(where: { $0.id == track.id }) {
                            self.currentPlaylistTracks[index].isLiked = false
                        }
                    }

                    // If viewing Liked Songs, remove from current list
                    if self.isViewingLikedSongs {
                        let trackIdsToRemove = Set(batch.map { $0.trackId })
                        self.currentPlaylistTracks.removeAll { trackIdsToRemove.contains($0.trackId) }
                    }
                }
            } else {
                failed += batch.count
            }
        }

        Self.logger.info("Bulk unlike completed: \(succeeded) succeeded, \(failed) failed")
        infoMessage = failed == 0
            ? "Removed \(succeeded) track\(succeeded == 1 ? "" : "s") from Liked Songs"
            : "Removed \(succeeded) of \(succeeded + failed) — \(failed) failed"
        return (succeeded, failed)
    }

    /// Checks liked/saved status for all tracks in the current playlist.
    ///
    /// ## Bounded Parallel Execution Pattern
    ///
    /// This method demonstrates a common pattern for concurrent API calls with rate limiting:
    ///
    /// **Problem**: Checking 500 tracks sequentially takes ~50 seconds (100ms per request).
    /// Unbounded parallelism could trigger Spotify's rate limits (429 errors).
    ///
    /// **Solution**: Bounded parallelism with a "worker pool" pattern:
    /// ```
    /// ┌─────────────────────────────────────────────────────────────┐
    /// │  maxConcurrency = 5                                         │
    /// │  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐                   │
    /// │  │Slot1│ │Slot2│ │Slot3│ │Slot4│ │Slot5│  ← Active tasks   │
    /// │  └──┬──┘ └──┬──┘ └──┬──┘ └──┬──┘ └──┬──┘                   │
    /// │     │       │       │       │       │                       │
    /// │     ▼       ▼       ▼       ▼       ▼                       │
    /// │  [Batch1] [Batch2] [Batch3] [Batch4] [Batch5]               │
    /// │                                                             │
    /// │  When Batch1 completes → Slot1 starts Batch6                │
    /// │  When Batch2 completes → Slot2 starts Batch7                │
    /// │  ... until pendingBatches is empty                          │
    /// └─────────────────────────────────────────────────────────────┘
    /// ```
    ///
    /// **Performance**: 5x speedup (10 seconds for 500 tracks vs 50 seconds sequential)
    ///
    /// **Thread Safety**:
    /// - `tracksSnapshot` captures array state before async work (avoids mutation during iteration)
    /// - Results collected in `allResults`, then applied atomically on MainActor
    /// - Uses track ID matching to handle array reordering during fetch
    ///
    /// - Note: The RateLimiter actor in SpotifyWebAPI provides additional protection against 429s.
    func checkTracksLikedStatus() async {
        // Capture a snapshot of tracks to avoid range errors if the array changes during async work
        let tracksSnapshot = currentPlaylistTracks
        guard !tracksSnapshot.isEmpty else { return }

        // Create batches for concurrent processing (50 tracks per batch = Spotify API limit)
        let batchSize = Constants.Spotify.trackCheckBatchSize
        var batches: [(startIndex: Int, trackIds: [String])] = []

        for startIndex in stride(from: 0, to: tracksSnapshot.count, by: batchSize) {
            let endIndex = min(startIndex + batchSize, tracksSnapshot.count)
            let batch = Array(tracksSnapshot[startIndex..<endIndex])
            let trackIds = batch.map { $0.trackId }
            batches.append((startIndex, trackIds))
        }

        // Bounded parallelism: max 5 concurrent requests to respect rate limits while maximizing throughput
        let maxConcurrency = 5
        var allResults: [(startIndex: Int, statuses: [Bool])] = []

        // TaskGroup with manual concurrency control (worker pool pattern)
        await withTaskGroup(of: (Int, [Bool]).self) { group in
            var pendingBatches = batches[...]
            var activeTasks = 0

            // Prime the pump: start initial batch of concurrent tasks
            while activeTasks < maxConcurrency && !pendingBatches.isEmpty {
                let batch = pendingBatches.removeFirst()
                activeTasks += 1
                group.addTask {
                    let statuses = await SpotifyWebAPI.shared.checkSavedTracks(trackIds: batch.trackIds)
                    return (batch.startIndex, statuses)
                }
            }

            // As each task completes, start a new one (maintains concurrency level)
            for await (startIndex, statuses) in group {
                allResults.append((startIndex, statuses))
                activeTasks -= 1

                // Refill: start next batch if available
                if !pendingBatches.isEmpty {
                    let batch = pendingBatches.removeFirst()
                    activeTasks += 1
                    group.addTask {
                        let statuses = await SpotifyWebAPI.shared.checkSavedTracks(trackIds: batch.trackIds)
                        return (batch.startIndex, statuses)
                    }
                }
            }
        }

        // Update all liked statuses at once for better UI performance
        await MainActor.run {
            for (startIndex, likedStatuses) in allResults {
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

    func fetchLikedSongs(forceRefresh: Bool = false) {
        Self.logger.info("Starting to fetch liked songs...")

        // Cancel any existing fetch operation
        fetchTask?.cancel()

        // Create operation for liked songs (using special ID)
        let operation = PlaylistLoadOperation(id: UUID(), playlistId: Constants.Cache.likedSongsCacheId, startTime: Date())
        currentLoadOperation = operation

        fetchTask = Task { @MainActor [weak self] in
            guard let self = self else { return }

            // Helper to validate operation
            @MainActor func isOperationValid() -> Bool {
                return self.currentLoadOperation == operation && self.isViewingLikedSongs
            }

            // First, try to load from cache (unless force refresh)
            if !forceRefresh, let cachedTracks = self.loadLikedSongsFromCache() {
                guard isOperationValid() else { return }

                Self.logger.info("Loaded \(cachedTracks.count) liked songs from cache")
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

                // Still fetch from API to check for updates
                await self.fetchAndUpdateLikedSongs(operation: operation)
            } else {
                // No cache, show loading and fetch
                self.isLoadingTracks = true
                self.loadingProgress = (0, 0)
                self.currentPlaylistTracks = []
                await self.fetchAndUpdateLikedSongs(operation: operation)
            }
        }
    }

    private func fetchAndUpdateLikedSongs(operation: PlaylistLoadOperation) async {
        var allTracks: [Track] = []
        var offset = 0
        let limit = Constants.Spotify.likedSongsBatchSize
        var hasMore = true
        // REL-3: track whether pagination finished cleanly. A mid-pagination API failure
        // returns an empty batch (total 0), which must NOT be cached as the full library.
        var knownTotal: Int?
        var completedCleanly = true

        while hasMore {
            // Check if this request was cancelled
            guard currentLoadOperation == operation && isViewingLikedSongs else {
                Self.logger.debug("Liked songs fetch cancelled")
                return
            }
            Self.logger.debug("Fetching liked songs batch at offset \(offset)...")
            let result = await SpotifyWebAPI.shared.fetchLikedSongs(limit: limit, offset: offset)
            Self.logger.debug("Got \(result.tracks.count) tracks in this batch")

            if knownTotal == nil && result.total > 0 {
                knownTotal = result.total
            }

            // An empty batch before reaching the known total means a failed/short fetch.
            if result.tracks.isEmpty {
                if let total = knownTotal, allTracks.count < total {
                    completedCleanly = false
                    Self.logger.warning("Liked songs fetch incomplete at \(allTracks.count)/\(total) — not caching")
                }
                break
            }

            allTracks.append(contentsOf: result.tracks)

            // Update progress only if still valid
            if currentLoadOperation == operation && isViewingLikedSongs {
                self.loadingProgress = (allTracks.count, result.total)
            }

            hasMore = allTracks.count < result.total
            offset += limit
        }

        Self.logger.info("Finished fetching liked songs. Total: \(allTracks.count)")

        // Final validation before updating state
        guard currentLoadOperation == operation && isViewingLikedSongs else {
            Self.logger.debug("Liked songs operation no longer valid, discarding results")
            return
        }

        // Only cache a COMPLETE, non-empty result (REL-3: never overwrite the cache with a
        // partial library caused by a mid-pagination failure). The partial set is still shown.
        if !allTracks.isEmpty && completedCleanly {
            cacheLikedSongs(allTracks)
        } else if !completedCleanly {
            Self.logger.warning("Liked songs fetch incomplete - keeping existing cache")
        } else {
            Self.logger.warning("Received 0 liked songs from API - not updating cache")
        }

        self.currentPlaylistTracks = allTracks
        self.isLoadingTracks = false
        self.isUsingCache = false
        self.lastCacheUpdate = Date() // Fresh from API
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
            spotifyLogger.error("Error loading liked songs from cache: \(error)")
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
                    albumArtURL: track.albumArtURL,
                    position: index
                )
            }

            cachedPlaylist.tracks = cachedTracks
            for track in cachedTracks {
                track.playlist = cachedPlaylist
            }

            modelContext.insert(cachedPlaylist)
            try modelContext.save()

            spotifyLogger.info("Successfully cached \(tracks.count) liked songs")
        } catch {
            spotifyLogger.error("Error caching liked songs: \(error)")
        }
    }

    func fetchTracksForPlaylist(_ playlistId: String, forceRefresh: Bool = false) {
        // Cancel any existing fetch operation
        fetchTask?.cancel()

        // Update undo context for the new playlist
        playlistUndoManager.setPlaylist(playlistId)

        // Create atomic load operation for race condition prevention
        let operation = PlaylistLoadOperation(id: UUID(), playlistId: playlistId, startTime: Date())
        currentLoadOperation = operation

        fetchTask = Task { @MainActor [weak self] in
            guard let self = self else { return }

            // Inline validation helper (captures self strongly within the check)
            @MainActor func isOperationValid() -> Bool {
                return self.currentLoadOperation == operation && self.selectedPlaylist?.id == playlistId
            }

            guard isOperationValid() else {
                Self.logger.debug("Fetch cancelled before start for playlist: \(playlistId, privacy: .public)")
                return
            }

            self.isLoadingTracks = true
            self.loadingProgress = (0, 0)
            self.currentPlaylistTracks = []  // Always clear current tracks first

            // First, try to load from cache WITH VALIDATION (unless force refresh)
            if !forceRefresh, let cachedTracks = self.loadCachedTracks(for: playlistId, operation: operation) {
                // ATOMIC VALIDATE: Check operation is still current
                guard isOperationValid() else {
                    Self.logger.info("Playlist changed during cache load, discarding results")
                    return
                }

                // Atomic UI update
                self.currentPlaylistTracks = cachedTracks
                self.isLoadingTracks = false
                self.isUsingCache = true
                // Get cache date from SwiftData
                if let cached = try? self.modelContext?.fetch(
                    FetchDescriptor<CachedPlaylist>(
                        predicate: #Predicate { $0.playlistId == playlistId }
                    )
                ).first {
                    self.lastCacheUpdate = cached.lastSynced
                }

                // Check liked status for visible tracks
                Task { @MainActor in
                    await self.checkTracksLikedStatus()
                }

                // Fetch fresh data in background WITH PROPER VALIDATION
                Task.detached {
                    await self.syncPlaylistInBackground(playlistId, operation: operation)
                }
            } else {
                // No cache, fetch from API
                let tracks = await SpotifyWebAPI.shared.fetchPlaylistTracks(
                    playlistId: playlistId,
                    progressHandler: { [weak self] current, total in
                        Task { @MainActor in
                            // Only update progress if still the current operation
                            if self?.currentLoadOperation == operation {
                                self?.loadingProgress = (current, total)
                            }
                        }
                    }
                )

                // ATOMIC VALIDATE: Check operation is still current before ANY state update
                guard isOperationValid() else {
                    Self.logger.info("Playlist changed during API fetch, discarding \(tracks.count) tracks")
                    return
                }

                // EMPTY TRACK LIST PROTECTION
                let expectedTracks = self.selectedPlaylist?.totalTracks ?? 0
                if tracks.isEmpty && expectedTracks > 0 {
                    Self.logger.warning("API returned empty tracks but expected \(expectedTracks)")

                    // Try to load from cache as fallback
                    if let cachedTracks = self.loadCachedTracks(for: playlistId, operation: operation), !cachedTracks.isEmpty {
                        Self.logger.info("Using cached tracks as fallback (\(cachedTracks.count) tracks)")
                        self.currentPlaylistTracks = cachedTracks
                        self.isLoadingTracks = false
                        self.isUsingCache = true
                        self.displayError(
                            "Couldn't refresh playlist",
                            recovery: "Showing cached data. Pull to refresh when back online."
                        )
                        return
                    }

                    // No cache available - show error
                    self.displayError(
                        "Failed to load playlist tracks",
                        recovery: "Check your connection and try selecting the playlist again."
                    )
                    self.isLoadingTracks = false
                    return
                }

                // Final atomic validation and update
                guard isOperationValid() else {
                    Self.logger.info("Playlist changed just before UI update")
                    return
                }

                self.currentPlaylistTracks = tracks
                self.isLoadingTracks = false
                self.isUsingCache = false
                self.lastCacheUpdate = Date() // Fresh from API

                // Check liked status for visible tracks
                Task { @MainActor in
                    await self.checkTracksLikedStatus()
                }

                // Cache ONLY if operation is still valid and we got tracks
                if isOperationValid() && !tracks.isEmpty {
                    await self.cachePlaylistTracks(playlistId: playlistId, tracks: tracks)
                }
            }
        }
    }

    /// Loads cached tracks for a playlist from SwiftData.
    /// This is a synchronous operation that must run on MainActor since SwiftData's ModelContext is not thread-safe.
    private func loadCachedTracks(for playlistId: String, operation: PlaylistLoadOperation? = nil) -> [Track]? {
        guard let modelContext = modelContext else { return nil }

        // CRITICAL: Verify operation is still valid if provided
        if let operation = operation {
            guard currentLoadOperation == operation && selectedPlaylist?.id == playlistId else {
                Self.logger.debug("Cache load cancelled - operation no longer valid")
                return nil
            }
        } else {
            // Fallback to old behavior if no operation provided
            guard selectedPlaylist?.id == playlistId else {
                Self.logger.warning("Attempting to load cache for playlist \(playlistId, privacy: .public) but selected playlist has changed")
                return nil
            }
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
                    Self.logger.error("Cache returned wrong playlist! Requested: \(playlistId, privacy: .public), Got: \(cachedPlaylist.playlistId, privacy: .public)")
                    return nil
                }

                Self.logger.info("Loading \(tracks.count) cached tracks for playlist: \(cachedPlaylist.name, privacy: .public)")

                // Convert to Track objects immediately while still on MainActor
                // This avoids SwiftData threading issues by not holding CachedTrack references
                let sortedTracks = tracks.sorted { $0.position < $1.position }
                return sortedTracks.map { $0.toTrack() }
            }
        } catch {
            spotifyLogger.error("Failed to load cached tracks: \(error)")
        }

        return nil
    }

    private func cachePlaylistTracks(playlistId: String, tracks: [Track]) async {
        guard let modelContext = modelContext else { return }

        // Important: Verify track count before caching
        let trackCount = tracks.count
        guard trackCount > 0 else {
            spotifyLogger.warning("Attempting to cache empty track list, aborting")
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
                    spotifyLogger.debug("Deleting \(oldTracks.count) old cached tracks for playlist update")
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
                    albumArtURL: track.albumArtURL,
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
            spotifyLogger.info("Successfully cached \(trackCount) tracks for playlist \(playlistId)")

            // Verify the save was successful
            let verifyDescriptor = FetchDescriptor<CachedPlaylist>(
                predicate: #Predicate { $0.playlistId == playlistId }
            )
            let verifyResult = try modelContext.fetch(verifyDescriptor)
            if let savedPlaylist = verifyResult.first,
               let savedTracks = savedPlaylist.tracks {
                spotifyLogger.debug("Verified: \(savedTracks.count) tracks saved in cache")
                if savedTracks.count != trackCount {
                    spotifyLogger.error("Track count mismatch after save! Expected: \(trackCount), Got: \(savedTracks.count)")
                }
            }
        } catch {
            spotifyLogger.error("Failed to cache playlist tracks: \(error)")
        }
    }

    private func syncPlaylistInBackground(_ playlistId: String, operation: PlaylistLoadOperation? = nil) async {
        // Helper for atomic validation
        func isOperationValid() async -> Bool {
            await MainActor.run {
                if let operation = operation {
                    return currentLoadOperation == operation && selectedPlaylist?.id == playlistId
                }
                return selectedPlaylist?.id == playlistId
            }
        }

        // CRITICAL VALIDATION: Only sync if operation is still valid
        guard await isOperationValid() else {
            Self.logger.debug("Background sync aborted: operation no longer valid for playlist \(playlistId, privacy: .public)")
            return
        }

        // Fetch fresh data from API
        let freshTracks = await SpotifyWebAPI.shared.fetchPlaylistTracks(
            playlistId: playlistId,
            progressHandler: nil
        )

        // SECOND VALIDATION: Check again before updating anything
        guard await isOperationValid() else {
            Self.logger.debug("Background sync aborted after fetch: operation changed")
            return
        }

        // Compare with current tracks (but DON'T push changes to Spotify!)
        // REL-2: compare the FULL ordered list of track IDs, not just count+first+last —
        // otherwise a track swapped in the middle (same count, same endpoints) is missed and
        // the stale cache persists. (A full-list compare achieves the same goal as a
        // snapshot_id check without the extra API round-trip.)
        let currentTracks = await MainActor.run { self.currentPlaylistTracks }
        if freshTracks.map(\.trackId) != currentTracks.map(\.trackId) {

            // Playlist has changed on Spotify, update our LOCAL view only
            Self.logger.info("Playlist \(playlistId, privacy: .public) has changes on Spotify, updating local view")

            // FINAL VALIDATION before updating
            guard await isOperationValid() else {
                Self.logger.debug("Background sync aborted before UI update: operation changed")
                return
            }

            await MainActor.run {
                // Only update if operation is still valid
                let stillValid: Bool
                if let operation = operation {
                    stillValid = currentLoadOperation == operation && selectedPlaylist?.id == playlistId
                } else {
                    stillValid = selectedPlaylist?.id == playlistId
                }

                if stillValid {
                    self.currentPlaylistTracks = freshTracks
                    self.isUsingCache = false
                    self.lastCacheUpdate = Date()
                    // Update cache with fresh data from Spotify
                    Task {
                        await self.cachePlaylistTracks(playlistId: playlistId, tracks: freshTracks)
                    }
                }
            }
        }
    }

    func deleteTracksFromPlaylist(_ playlistId: String, tracks: Set<Track>) async -> Bool {
        // Capture tracks with their positions BEFORE deletion for undo
        var deletedTracksWithPositions: [(track: Track, position: Int)] = []
        var trackPositions: [String: [Int]] = [:]

        for (index, track) in currentPlaylistTracks.enumerated() {
            if tracks.contains(where: { $0.id == track.id }) {
                deletedTracksWithPositions.append((track: track, position: index))
                if trackPositions[track.uri] == nil {
                    trackPositions[track.uri] = []
                }
                trackPositions[track.uri]?.append(index)
            }
        }

        // Sort by position for proper restoration order
        deletedTracksWithPositions.sort { $0.position < $1.position }

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

            // Register undo action
            playlistUndoManager.registerTrackDeletion(
                playlistId: playlistId,
                deletedTracks: deletedTracksWithPositions
            ) { [weak self] pid, tracksToRestore in
                guard let self = self else { return false }
                return await self.restoreDeletedTracks(playlistId: pid, tracks: tracksToRestore)
            }
        }

        return success
    }

    /// Adds tracks to a playlist (used for drag & drop between playlists)
    func addTracksToPlaylist(_ playlistId: String, tracks: [Track]) async -> Bool {
        guard !tracks.isEmpty else { return false }

        let uris = tracks.map { $0.uri }
        let success = await SpotifyWebAPI.shared.addTracksToPlaylist(
            playlistId: playlistId,
            trackUris: uris
        )

        if success {
            // Update the playlist track count in the sidebar
            updatePlaylistTrackCount(playlistId, addedCount: tracks.count)
        }

        return success
    }

    /// Restores previously deleted tracks at their original positions
    private func restoreDeletedTracks(playlistId: String, tracks: [(track: Track, position: Int)]) async -> Bool {
        guard selectedPlaylist?.id == playlistId else {
            Self.logger.warning("Cannot restore tracks: playlist changed")
            return false
        }

        // Add tracks back via API
        let uris = tracks.map { $0.track.uri }
        let success = await SpotifyWebAPI.shared.addTracksToPlaylist(
            playlistId: playlistId,
            trackUris: uris
        )

        if success {
            // Refresh the playlist to get the restored tracks
            fetchTracksForPlaylist(playlistId, forceRefresh: true)
            updatePlaylistTrackCount(playlistId, addedCount: tracks.count)
        }

        return success
    }

    func shuffleAndSavePlaylist(_ playlistId: String) async -> Bool {
        spotifyLogger.debug("shuffleAndSavePlaylist called for playlist: \(playlistId)")

        // CRITICAL SAFETY CHECK: Verify playlist ID matches selected playlist
        guard let currentSelectedPlaylist = selectedPlaylist,
              currentSelectedPlaylist.id == playlistId else {
            spotifyLogger.error("Playlist ID mismatch! Aborting shuffle to prevent overwrite.")
            return false
        }

        // Cancel any existing shuffle operation
        shuffleTask?.cancel()

        // Check and set shuffling state
        let canProceed = await MainActor.run {
            if self.isShuffling {
                spotifyLogger.warning("Shuffle already in progress, ignoring request")
                return false
            }
            self.isShuffling = true
            spotifyLogger.debug("Setting isShuffling to true")
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
                spotifyLogger.error("Playlist changed during shuffle! Aborting.")
                return false
            }

            // Store original tracks in case we need to revert
            let originalTracks = currentPlaylistTracks
            let originalCount = originalTracks.count

            // Ensure we have tracks to shuffle
            guard !originalTracks.isEmpty else {
                spotifyLogger.warning("No tracks to shuffle")
                return false
            }

            // VERIFY TRACK COUNT MATCHES PLAYLIST (skip for playlists we just modified)
            // Allow some flexibility for recently modified playlists
            let trackCountDifference = abs(originalCount - currentSelectedPlaylist.totalTracks)
            if trackCountDifference > Constants.Validation.trackCountDifferenceThreshold && currentSelectedPlaylist.totalTracks > 0 {
                spotifyLogger.warning("Large track count difference! Playlist reports \(currentSelectedPlaylist.totalTracks) but we have \(originalCount)")
                // Don't abort - the local count is likely more accurate if we just added/deleted tracks
            }

            // Shuffle the tracks
            let shuffledTracks = originalTracks.shuffled()
            spotifyLogger.info("Shuffled \(originalCount) tracks for playlist: \(currentSelectedPlaylist.name)")

            // Verify we didn't lose tracks
            guard shuffledTracks.count == originalCount else {
                spotifyLogger.error("Track count mismatch during shuffle! Original: \(originalCount), Shuffled: \(shuffledTracks.count)")
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
                spotifyLogger.error("Playlist changed before API call! Reverting local changes.")
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
                    spotifyLogger.warning("Track count changed after shuffle! Expected: \(originalCount), Got: \(finalCount)")
                }

                // Register undo action to restore original order
                self.playlistUndoManager.registerShuffle(
                    playlistId: playlistId,
                    originalTracks: originalTracks
                ) { [weak self] pid, tracksToRestore in
                    guard let self = self else { return false }
                    return await self.restoreTrackOrder(playlistId: pid, tracks: tracksToRestore)
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

    /// Restores tracks to a specific order (used for undo shuffle/reorder)
    private func restoreTrackOrder(playlistId: String, tracks: [Track]) async -> Bool {
        guard selectedPlaylist?.id == playlistId else {
            Self.logger.warning("Cannot restore track order: playlist changed")
            return false
        }

        let trackUris = tracks.map { $0.uri }
        let success = await SpotifyWebAPI.shared.replacePlaylistTracks(
            playlistId: playlistId,
            trackUris: trackUris
        )

        if success {
            currentPlaylistTracks = tracks
            await cachePlaylistTracks(playlistId: playlistId, tracks: tracks)
        }

        return success
    }

    func reorderTracks(in playlistId: String, from source: IndexSet, to destination: Int) async {
        // Save original order for undo BEFORE modifying
        let originalTracks = currentPlaylistTracks

        // Convert indices to track positions
        var tracks = currentPlaylistTracks

        // Perform the move locally first for immediate UI feedback
        tracks.move(fromOffsets: source, toOffset: destination)

        await MainActor.run {
            self.currentPlaylistTracks = tracks
        }

        // Calculate the API parameters.
        // source contains the original indices, destination is where they should go.
        guard let firstIndex = source.first, let lastIndex = source.max() else { return }
        let rangeLength = source.count

        // STAB-5: Spotify's reorder endpoint only models a CONTIGUOUS block (range_start +
        // range_length). For a contiguous selection use it; for a non-contiguous selection,
        // persist the exact locally-moved order via replace so the playlist can't be corrupted.
        let isContiguous = (lastIndex - firstIndex + 1) == rangeLength
        let success: Bool
        if isContiguous {
            let insertBefore = destination > firstIndex ? destination - rangeLength : destination
            success = await SpotifyWebAPI.shared.reorderPlaylistTracks(
                playlistId: playlistId,
                rangeStart: firstIndex,
                insertBefore: insertBefore,
                rangeLength: rangeLength
            )
        } else {
            Self.logger.info("Non-contiguous reorder — persisting full order via replace")
            success = await SpotifyWebAPI.shared.replacePlaylistTracks(
                playlistId: playlistId,
                trackUris: tracks.map { $0.uri }
            )
        }

        if success {
            // Update cache with the modified playlist
            await cachePlaylistTracks(playlistId: playlistId, tracks: currentPlaylistTracks)

            // Register undo action to restore original order
            playlistUndoManager.registerReorder(
                playlistId: playlistId,
                originalTracks: originalTracks
            ) { [weak self] pid, tracksToRestore in
                guard let self = self else { return false }
                return await self.restoreTrackOrder(playlistId: pid, tracks: tracksToRestore)
            }
        } else {
            // Revert on failure
            fetchTracksForPlaylist(playlistId)
        }
    }

    #if os(macOS)
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
                        spotifyLogger.info("Successfully exported playlist to: \(url.path)")

                        // Notify success via published property
                        await MainActor.run {
                            self.exportSuccess = true
                            self.exportMessage = "Playlist exported to: \(url.lastPathComponent)"
                        }
                    } catch {
                        spotifyLogger.error("Error exporting CSV: \(error)")
                        // Notify failure via published property
                        await MainActor.run {
                            self.exportSuccess = false
                            self.exportMessage = "Failed to export playlist: \(error.localizedDescription)"
                        }
                    }
                }
            }
        }
    }
    #endif

    // MARK: - Playlist Folders

    /// Published property for folders
    @Published var folders: [PlaylistFolder] = []

    /// Fetches all folders from the local store
    func fetchFolders() {
        guard let modelContext = modelContext else { return }

        let descriptor = FetchDescriptor<PlaylistFolder>(
            sortBy: [SortDescriptor(\.sortOrder)]
        )

        do {
            folders = try modelContext.fetch(descriptor)
            Self.logger.info("Fetched \(self.folders.count) folders")
        } catch {
            Self.logger.error("Failed to fetch folders: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Creates a new folder
    func createFolder(name: String) -> PlaylistFolder? {
        guard let modelContext = modelContext else { return nil }

        let maxSortOrder = folders.map { $0.sortOrder }.max() ?? -1
        let folder = PlaylistFolder(name: name, sortOrder: maxSortOrder + 1)

        modelContext.insert(folder)

        do {
            try modelContext.save()
            fetchFolders()
            Self.logger.info("Created folder: \(name, privacy: .public)")
            return folder
        } catch {
            Self.logger.error("Failed to create folder: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Renames a folder
    func renameFolder(_ folder: PlaylistFolder, newName: String) {
        guard let modelContext = modelContext else { return }

        folder.name = newName

        do {
            try modelContext.save()
            fetchFolders()
            Self.logger.info("Renamed folder to: \(newName, privacy: .public)")
        } catch {
            Self.logger.error("Failed to rename folder: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deletes a folder (playlists become uncategorized)
    func deleteFolder(_ folder: PlaylistFolder) {
        guard let modelContext = modelContext else { return }

        modelContext.delete(folder)

        do {
            try modelContext.save()
            fetchFolders()
            Self.logger.info("Deleted folder")
        } catch {
            Self.logger.error("Failed to delete folder: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Adds a playlist to a folder
    func addPlaylistToFolder(_ playlistId: String, folder: PlaylistFolder) {
        guard let modelContext = modelContext else { return }

        // Remove from any existing folder first
        for existingFolder in folders {
            existingFolder.removePlaylist(playlistId)
        }

        folder.addPlaylist(playlistId)

        do {
            try modelContext.save()
            fetchFolders()
            Self.logger.info("Added playlist \(playlistId, privacy: .public) to folder \(folder.name, privacy: .public)")
        } catch {
            Self.logger.error("Failed to add playlist to folder: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes a playlist from its folder
    func removePlaylistFromFolder(_ playlistId: String) {
        guard let modelContext = modelContext else { return }

        for folder in folders {
            folder.removePlaylist(playlistId)
        }

        do {
            try modelContext.save()
            fetchFolders()
            Self.logger.info("Removed playlist \(playlistId, privacy: .public) from folders")
        } catch {
            Self.logger.error("Failed to remove playlist from folder: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Returns the folder containing a playlist, if any
    func folderForPlaylist(_ playlistId: String) -> PlaylistFolder? {
        folders.first { $0.containsPlaylist(playlistId) }
    }

    /// Returns playlists not in any folder
    func uncategorizedPlaylists() -> [Playlist] {
        let folderPlaylistIds = Set(folders.flatMap { $0.playlistIds })
        return playlists.filter { !folderPlaylistIds.contains($0.id) }
    }

    /// Toggles folder expansion state
    func toggleFolderExpansion(_ folder: PlaylistFolder) {
        guard let modelContext = modelContext else { return }

        folder.isExpanded.toggle()

        do {
            try modelContext.save()
            // Don't need to refetch, just update the local state
            if let index = folders.firstIndex(where: { $0.id == folder.id }) {
                folders[index].isExpanded = folder.isExpanded
            }
        } catch {
            Self.logger.error("Failed to toggle folder expansion: \(error.localizedDescription, privacy: .public)")
        }
    }
}

