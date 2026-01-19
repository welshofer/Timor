# Timor

A cross-platform Spotify playlist management app built with SwiftUI and SwiftData.

> ⚠️ **Disclaimer:** This app modifies your Spotify playlists. While safety features are built in (undo system, verification checks, empty-data protection), **always back up important playlists before performing bulk operations**. The authors are not responsible for any data loss. Use at your own risk. See [LICENSE](LICENSE) for full terms.

## Platforms

| Platform | Minimum Version |
|----------|-----------------|
| macOS    | 26.0+           |
| iOS      | 26.0+           |
| iPadOS   | 26.0+           |

## Features

### Spotify Integration
- **OAuth 2.0 Authentication** — Authorization Code Flow with PKCE-ready implementation
- **Secure Token Storage** — Keychain-backed credential management
- **Rate Limiting** — Exponential backoff with automatic retry
- **Network Monitoring** — Connectivity-aware operations

### Playlist Management
- **Full CRUD Operations** — Create, edit, delete, and shuffle playlists
- **Drag & Drop Reordering** — Reorder tracks within editable playlists
- **Bulk Operations** — Select and modify multiple tracks at once
- **Playlist Folders** — Local organization (Spotify API doesn't support folders)

### Track Operations
- **Like/Unlike** — Manage your Spotify library
- **Delete with Undo** — Recover from accidental deletions
- **Track Inspector** — View detailed metadata
- **Swipe Actions** — Quick actions on iOS

### Search & Discovery
- **Cross-Playlist Search** — Find tracks across all playlists
- **Add New Tracks** — Search Spotify catalog and add to playlists
- **Duplicate Detection** — Find and manage duplicate tracks

### Data Management
- **Local Caching** — SwiftData-backed cache reduces API calls by ~80%
- **CSV Export** — Export playlist data using TabularData framework
- **CSV/URL Import** — Import tracks from files or Spotify URLs
- **Analytics** — Playlist statistics and insights

## Safety Features

Timor includes multiple safeguards to protect your data:

- **Undo/Redo System** — Recover from accidental deletions
- **Post-Save Verification** — Validates operations after completion
- **Empty Data Protection** — Never overwrites cache with empty track lists
- **Track Count Validation** — Warns when local data diverges from Spotify
- **Atomic Operations** — Operation IDs prevent race conditions

## Requirements

- macOS 26.0+ / iOS 26.0+
- Xcode 26.0+
- Spotify account
- Spotify Developer App credentials

## Dependencies

**None** — Timor uses only Apple frameworks:

- SwiftUI
- SwiftData
- Combine
- TabularData
- Network
- AuthenticationServices
- UniformTypeIdentifiers
- os.log

## Setup

### 1. Create a Spotify App

1. Go to [Spotify Developer Dashboard](https://developer.spotify.com/dashboard)
2. Click "Create App"
3. Fill in app details:
   - **App name:** Timor (or your preference)
   - **Redirect URI:** `timor://spotify-callback`
4. Save and note your **Client ID** and **Client Secret**

### 2. Configure Timor

1. Open Timor
2. Go to Settings:
   - **macOS:** ⌘, (Command + Comma)
   - **iOS:** Tap the gear icon
3. Enter your Client ID and Client Secret
4. Tap "Connect to Spotify"
5. Authorize in your browser

## Building from Source

### Clone

```bash
git clone https://github.com/welshofer/Timor.git
cd Timor
```

### Build with Xcode

```bash
# Open in Xcode
open Timor.xcodeproj

# Or build from command line
xcodebuild -project Timor.xcodeproj -scheme Timor -configuration Release build

# Build iOS target
xcodebuild -project Timor.xcodeproj -scheme "Timor iOS" -configuration Release -destination 'generic/platform=iOS' build
```

### Run Tests

```bash
xcodebuild -project Timor.xcodeproj -scheme Timor -destination 'platform=macOS' test
```

## Project Structure

```
Timor/
├── TimorApp.swift           # App entry point, SwiftData container
├── ContentView.swift        # Main NavigationSplitView coordinator
├── Constants.swift          # Centralized configuration
│
├── Spotify Integration
│   ├── SpotifyManager.swift # Central state manager (~1,500 lines)
│   └── SpotifyWebAPI.swift  # OAuth, API calls, rate limiting (~1,400 lines)
│
├── Data Models
│   ├── CachedPlaylist.swift # SwiftData model for caching
│   └── PlaylistFolder.swift # Local playlist organization
│
├── Views
│   ├── PlaylistSidebarView.swift
│   ├── PlaylistDetailView.swift
│   ├── TrackTableView.swift    # macOS track table
│   ├── TrackListView.swift     # iOS track list
│   ├── TrackInspectorView.swift
│   ├── TrackFilterView.swift
│   ├── TrackSearchView.swift
│   ├── DuplicateFinderView.swift
│   ├── ImportView.swift
│   ├── PlaylistStatsView.swift
│   └── SettingsView.swift
│
├── Utilities
│   ├── KeychainManager.swift
│   ├── ImageCache.swift
│   └── PlaylistUndoManager.swift
│
└── TimorTests/
    ├── RateLimiterTests.swift
    ├── PlaylistUndoManagerTests.swift
    └── SpotifyErrorTests.swift
```

## Architecture

- **SwiftUI** — Declarative UI with platform-specific adaptations
- **SwiftData** — Modern persistence for local caching
- **Combine** — Reactive state management
- **async/await** — Structured concurrency for API operations
- **@MainActor** — Thread-safe UI updates

### Key Patterns

- **Singleton SpotifyManager** — Single source of truth
- **Atomic Load Operations** — UUID-based race condition prevention
- **Rate Limiting Actor** — Exponential backoff with jitter
- **Platform Conditionals** — `#if os(macOS)` / `#if os(iOS)` for native experiences

## Documentation

Comprehensive technical documentation is available in the [`docs/`](docs/) folder:

| Document | Description |
|----------|-------------|
| [Architecture](docs/ARCHITECTURE.md) | System overview, component diagrams, threading model |
| [Data Models](docs/DATA-MODELS.md) | SwiftData schemas, runtime types, relationships |
| [OAuth Flow](docs/OAUTH-FLOW.md) | Authentication sequence, token management |
| [API Reference](docs/API-REFERENCE.md) | Complete API documentation for all public types |
| [State Management](docs/STATE-MANAGEMENT.md) | Observable patterns, view bindings, state flow |
| [Caching](docs/CACHING.md) | Cache strategy, invalidation, performance |
| [Security](SECURITY.md) | Credential storage, certificate pinning, threat model |

## License

[MIT License](LICENSE) — See LICENSE file for details.

## Contributing

Contributions welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Troubleshooting

### Build Issues
- Clean DerivedData: `rm -rf ~/Library/Developer/Xcode/DerivedData`
- Reset package cache: `xcodebuild -resolvePackageDependencies`

### OAuth Issues
- Verify redirect URI exactly matches: `timor://spotify-callback`
- Check Spotify app settings at developer.spotify.com
- Clear Keychain items (Service: "com.timor.spotify")

### Cache Issues
- Reset SwiftData: Delete app container and restart
