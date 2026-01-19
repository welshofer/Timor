# API Reference

This document provides a complete reference for Timor's public APIs, including SpotifyManager, SpotifyWebAPI, and supporting classes.

## SpotifyManager

The central state manager and business logic coordinator. Singleton accessed via `SpotifyManager.shared`.

### Published Properties

```swift
@MainActor
class SpotifyManager: ObservableObject {
    // Authentication
    @Published var isAuthenticated: Bool
    @Published var hasCredentials: Bool

    // Playlists
    @Published var playlists: [Playlist]
    @Published var selectedPlaylist: Playlist?
    @Published var isViewingLikedSongs: Bool

    // Tracks
    @Published var currentPlaylistTracks: [Track]
    @Published var currentTrack: String

    // Loading States
    @Published var isLoadingTracks: Bool
    @Published var loadingProgress: (current: Int, total: Int)
    @Published var isShuffling: Bool

    // Caching
    @Published var lastCacheUpdate: Date?
    @Published var isUsingCache: Bool
    @Published var modelContainerFailed: Bool

    // Network
    @Published var isOnline: Bool
    @Published var connectionType: ConnectionType

    // Errors
    @Published var lastError: String?
    @Published var lastErrorRecovery: String?
    @Published var showError: Bool

    // Export
    @Published var exportSuccess: Bool?
    @Published var exportMessage: String?
}
```

### Playlist Operations

#### fetchPlaylists()

Fetches all playlists from Spotify API, updating the local cache.

```swift
func fetchPlaylists()
```

**Behavior:**
- Fetches playlists in batches of 50
- Updates `playlists` published property
- Caches results to SwiftData
- Triggers background track count sync

---

#### loadPlaylistTracks(_ playlistId: String)

Loads tracks for a specific playlist with caching.

```swift
func loadPlaylistTracks(_ playlistId: String) async
```

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `playlistId` | `String` | Spotify playlist ID |

**Behavior:**
- Checks cache first, returns immediately if valid
- Validates cache via snapshot ID comparison
- Uses atomic operation tracking for race condition prevention
- Updates `currentPlaylistTracks` and loading state

---

#### createPlaylist(name:description:)

Creates a new playlist on Spotify.

```swift
func createPlaylist(name: String, description: String) async -> Bool
```

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `name` | `String` | Playlist name |
| `description` | `String` | Playlist description |

**Returns:** `Bool` indicating success

---

#### deletePlaylist(_:)

Unfollows (deletes) a playlist from the user's library.

```swift
func deletePlaylist(_ playlistId: String) async -> Bool
```

**Returns:** `Bool` indicating success

---

#### shuffleAndSavePlaylist(_:)

Randomizes track order and saves to Spotify.

```swift
func shuffleAndSavePlaylist(_ playlistId: String) async -> Bool
```

**Behavior:**
- Registers undo action before shuffling
- Uses Fisher-Yates shuffle algorithm
- Clears and re-adds all tracks in new order
- Returns success status

---

### Track Operations

#### deleteTracksFromPlaylist(_:tracks:)

Removes selected tracks from a playlist.

```swift
func deleteTracksFromPlaylist(_ playlistId: String, tracks: Set<Track>) async -> Bool
```

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `playlistId` | `String` | Target playlist |
| `tracks` | `Set<Track>` | Tracks to remove |

**Behavior:**
- Registers undo action with track positions
- Removes tracks via Spotify API
- Updates local cache
- Supports bulk deletion

---

#### addTracksToPlaylist(_:trackUris:)

Adds tracks to a playlist.

```swift
func addTracksToPlaylist(_ playlistId: String, trackUris: [String]) async -> Bool
```

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `playlistId` | `String` | Target playlist |
| `trackUris` | `[String]` | Spotify track URIs |

**Returns:** `Bool` indicating success

---

#### reorderTracks(in:from:to:)

Moves tracks within a playlist.

```swift
func reorderTracks(in playlistId: String, from source: IndexSet, to destination: Int) async
```

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `playlistId` | `String` | Target playlist |
| `source` | `IndexSet` | Source positions |
| `destination` | `Int` | Target position |

---

#### likeTrack(_:) / unlikeTrack(_:)

Manages the user's Liked Songs library.

```swift
func likeTrack(_ track: Track) async -> Bool
func unlikeTrack(_ track: Track) async -> Bool
```

**Behavior:**
- Updates track's `isLiked` property
- Syncs with Spotify library
- Registers undo action

---

### Search Operations

#### searchTracks(query:)

Searches Spotify's catalog.

```swift
func searchTracks(query: String) async -> [Track]
```

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `query` | `String` | Search query |

**Returns:** Array of matching tracks (up to 50)

---

### Export Operations

#### exportPlaylistToCSV(playlistName:)

Exports current playlist tracks to CSV.

```swift
func exportPlaylistToCSV(playlistName: String)
```

**Behavior:**
- Uses TabularData framework
- Opens save panel (macOS) or share sheet (iOS)
- Includes: name, artist, album, duration, release date, URI

---

### Import Operations

#### importTracksFromCSV(url:playlistId:skipDuplicates:)

Imports tracks from a CSV file.

```swift
func importTracksFromCSV(
    url: URL,
    playlistId: String,
    skipDuplicates: Bool
) async -> ImportResults
```

**Returns:**
```swift
struct ImportResults {
    let added: Int
    let skipped: Int
    let failed: Int
    let errors: [String]
}
```

---

### Folder Operations

#### createFolder(name:)

Creates a local playlist folder.

```swift
func createFolder(name: String)
```

---

#### deleteFolder(_:)

Deletes a playlist folder (playlists remain).

```swift
func deleteFolder(_ folder: PlaylistFolder)
```

---

#### addPlaylistToFolder(_:folder:)

Adds a playlist to a folder.

```swift
func addPlaylistToFolder(_ playlistId: String, folder: PlaylistFolder)
```

---

## SpotifyWebAPI

Handles OAuth authentication and HTTP communication with Spotify.

### Published Properties

```swift
@MainActor
class SpotifyWebAPI: ObservableObject {
    @Published var isAuthenticated: Bool
    @Published var accessToken: String?
    @Published var refreshToken: String?
    @Published var tokenExpiryDate: Date?
    @Published var isRateLimited: Bool
    @Published var rateLimitSecondsRemaining: Int
}
```

### Authentication Methods

#### authenticate()

Initiates OAuth authorization flow.

```swift
func authenticate()
```

**Behavior:**
- Opens browser for Spotify login
- Handles callback via URL scheme
- Exchanges code for tokens
- Stores tokens in Keychain

---

#### refreshAccessToken()

Refreshes the access token using stored refresh token.

```swift
func refreshAccessToken() async -> Bool
```

**Returns:** `Bool` indicating success

---

#### logout()

Clears all authentication state.

```swift
func logout()
```

---

### API Methods

#### fetchPlaylists()

```swift
func fetchPlaylists() async -> [PlaylistData]
```

---

#### fetchPlaylistTracks(playlistId:offset:)

```swift
func fetchPlaylistTracks(
    playlistId: String,
    offset: Int = 0
) async -> (tracks: [TrackData], total: Int, snapshotId: String?)?
```

---

#### searchTracks(query:)

```swift
func searchTracks(query: String) async -> [TrackData]
```

---

#### addTracksToPlaylist(playlistId:trackUris:)

```swift
func addTracksToPlaylist(
    playlistId: String,
    trackUris: [String]
) async -> Bool
```

---

#### deletePlaylistTracks(playlistId:trackUris:positions:)

```swift
func deletePlaylistTracks(
    playlistId: String,
    trackUris: [String],
    positions: [[Int]]
) async -> Bool
```

---

#### reorderPlaylistTracks(playlistId:rangeStart:insertBefore:rangeLength:)

```swift
func reorderPlaylistTracks(
    playlistId: String,
    rangeStart: Int,
    insertBefore: Int,
    rangeLength: Int = 1
) async -> Bool
```

---

## RateLimiter

Actor managing API rate limiting with exponential backoff.

```swift
actor RateLimiter {
    var isRateLimited: Bool { get }
    var rateLimitRemaining: TimeInterval? { get }

    func waitIfNeeded() async throws
    func handleRateLimit(retryAfterHeader: String?)
    func recordSuccess()

    func executeWithRetry(
        maxRetries: Int? = nil,
        operation: @escaping () async throws -> (Data, URLResponse)
    ) async throws -> (Data, URLResponse)
}
```

### Backoff Formula

```
totalWait = retryAfterHeader × 2^(min(failures-1, 4))
```

| Failures | Multiplier | Example (1s header) |
|----------|------------|---------------------|
| 1 | 1× | 1 second |
| 2 | 2× | 2 seconds |
| 3 | 4× | 4 seconds |
| 4 | 8× | 8 seconds |
| 5+ | 16× (cap) | 16 seconds |

---

## PlaylistUndoManager

Manages undo/redo operations for playlist modifications.

```swift
@MainActor
class PlaylistUndoManager: ObservableObject {
    let undoManager: UndoManager
    @Published var isUndoRedoInProgress: Bool
    @Published private(set) var currentPlaylistId: String?

    var canUndo: Bool { get }
    var canRedo: Bool { get }
    var undoActionName: String? { get }
    var redoActionName: String? { get }

    func setPlaylist(_ playlistId: String?)
    func clear()
    func undo()
    func redo()

    // Registration methods
    func registerTrackDeletion(...)
    func registerShuffle(...)
    func registerReorder(...)
    func registerLike(...)
    func registerUnlike(...)
}
```

---

## KeychainManager

Secure credential storage using macOS Keychain.

```swift
final class KeychainManager: @unchecked Sendable {
    static let shared: KeychainManager

    func save(_ value: String, for key: String, protection: ProtectionLevel) throws
    func retrieve(for key: String) throws -> String
    func delete(for key: String) throws
    func exists(for key: String) -> Bool
    func deleteAll() throws

    enum ProtectionLevel {
        case standard   // When Unlocked
        case high       // When Unlocked, This Device Only
        case sensitive  // User Presence Required
    }

    enum KeychainError: Error {
        case itemNotFound
        case duplicateItem
        case invalidData
        case accessControlCreationFailed
        case unhandledError(status: OSStatus)
    }
}
```

---

## ImageCache

Album artwork caching.

```swift
actor ImageCache {
    static let shared: ImageCache

    func image(for url: URL) async -> Image?
    func prefetch(urls: [URL]) async
    func clear()
}
```

---

## SpotifyError

Comprehensive error type for API operations.

```swift
enum SpotifyError: Error, LocalizedError {
    // Authentication
    case notAuthenticated
    case authenticationFailed(reason: String)
    case tokenRefreshFailed
    case invalidCredentials

    // Network
    case networkUnavailable
    case connectionFailed(underlying: Error?)
    case requestTimeout
    case serverError(statusCode: Int)

    // Rate Limiting
    case rateLimited(retryAfter: TimeInterval)

    // API
    case invalidResponse
    case playlistNotFound
    case trackNotFound
    case permissionDenied(operation: String)
    case quotaExceeded

    // Data
    case decodingFailed(context: String)
    case invalidData(reason: String)

    var errorDescription: String? { get }
    var recoverySuggestion: String? { get }

    static func fromStatusCode(_ code: Int, data: Data?) -> SpotifyError?
}
```

---

## Constants

Centralized configuration values.

```swift
enum Constants {
    enum Spotify {
        static let playlistFetchLimit: Int = 50
        static let trackFetchLimit: Int = 100
        static let searchResultLimit: Int = 50
        static let likedSongsBatchSize: Int = 50
        static let bulkLikeLimit: Int = 50
        static let minRequestInterval: TimeInterval = 0.1
        static let maxRetries: Int = 5
        static let baseBackoffSeconds: TimeInterval = 1.0
        static let baseURL: String
        static let tokenURL: String
        static let authURL: String
        static let redirectURI: String
        static let scopes: String
    }

    enum UI {
        static let sidebarMinWidth: CGFloat = 250
        static let sidebarIdealWidth: CGFloat = 300
        static let trackSearchWidth: CGFloat = 800
        static let trackSearchHeight: CGFloat = 600
        // ... more UI constants
    }

    enum Cache {
        static let playlistCacheKey: String
        static let likedSongsCacheId: String
        static let cacheStoreFileName: String
    }

    enum Keychain {
        static let service: String
        static let clientIdKey: String
        static let clientSecretKey: String
        static let accessTokenKey: String
        static let refreshTokenKey: String
    }

    enum Validation {
        static let trackCountDifferenceThreshold: Int = 10
    }
}
```
