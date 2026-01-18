# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Timor** is a production-grade **macOS Spotify playlist management application** built with SwiftUI and SwiftData. The app provides comprehensive playlist management capabilities including track operations, search, filtering, analytics, and local caching for performance.

### Core Features
- **Full Spotify OAuth 2.0 Authentication** (Authorization Code Flow with PKCE-ready implementation)
- **Complete Playlist Management** (create, edit, delete, shuffle, reorder)
- **Advanced Track Operations** (like/unlike, bulk operations, drag & drop, delete with undo)
- **Local Caching** (SwiftData-backed cache for playlists and tracks)
- **Liked Songs Integration** (view and manage Spotify library)
- **Search & Filtering** (find tracks across playlists, add new tracks)
- **Playlist Organization** (custom local folders for categorization)
- **Data Export** (CSV export using TabularData framework)
- **Analytics** (playlist statistics, duplicate detection)
- **Import/Export** (playlist data management)

## Build and Development Commands

### Building the Project
```bash
# Build using Xcode command line tools
xcodebuild -project Timor.xcodeproj -scheme Timor -configuration Debug build

# Build for specific platform
xcodebuild -project Timor.xcodeproj -scheme Timor -destination 'platform=macOS' build

# Clean build (recommended after schema changes)
xcodebuild -project Timor.xcodeproj -scheme Timor -configuration Debug clean build
```

### Running the Application
```bash
# Open in Xcode
open Timor.xcodeproj

# Run on macOS
xcodebuild -project Timor.xcodeproj -scheme Timor -configuration Debug -destination 'platform=macOS' run

# Run tests (when implemented)
xcodebuild -project Timor.xcodeproj -scheme Timor -destination 'platform=macOS' test
```

## Architecture Overview

### Core Technologies
- **SwiftUI**: Declarative UI framework for all views
- **SwiftData**: Modern persistence framework for local caching
- **Combine**: Reactive programming for state management
- **async/await**: Modern Swift concurrency for API calls
- **AuthenticationServices**: OAuth 2.0 flow implementation
- **Platform**: macOS 14+ (primary target)

### Project Structure (21 Swift Files)

#### Application Core
- **TimorApp.swift**: App entry point, SwiftData container setup with CachedPlaylist and PlaylistFolder models
- **ContentView.swift**: Main UI coordinator using NavigationSplitView architecture
- **Constants.swift**: Centralized configuration (API limits, UI constants, keychain keys)

#### Spotify Integration (~2,767 lines)
- **SpotifyManager.swift** (1,455 lines): Central state manager, playlist operations, caching logic
- **SpotifyWebAPI.swift** (1,423 lines): OAuth flow, API calls, rate limiting with exponential backoff

#### Data Models
- **CachedPlaylist.swift**: SwiftData model for local playlist/track caching
- **PlaylistFolder.swift**: Local-only playlist organization (Spotify doesn't support folders via API)

#### UI Components
- **PlaylistSidebarView.swift**: Playlist navigation sidebar
- **PlaylistDetailView.swift**: Track list display with toolbar
- **TrackTableView.swift**: Custom track table with multi-selection
- **TrackInspectorView.swift**: Track metadata inspector panel
- **TrackFilterView.swift**: Search and filter UI
- **TrackSearchView.swift**: Add tracks to playlists
- **DuplicateFinderView.swift**: Detect and manage duplicate tracks
- **ImportView.swift**: Import playlist data
- **PlaylistStatsView.swift**: Analytics and statistics display
- **SettingsView.swift**: OAuth credentials configuration (Cmd+,)

#### Utilities
- **KeychainManager.swift**: Secure credential storage (Client ID, tokens)
- **ImageCache.swift**: Album artwork caching
- **PlaylistUndoManager.swift**: Undo/redo system for destructive operations

### Key Architectural Patterns

#### State Management
- **SpotifyManager as @StateObject**: Single source of truth for Spotify data
- **Observable pattern**: SpotifyManager conforms to ObservableObject
- **SwiftData for persistence**: CachedPlaylist and PlaylistFolder models

#### Concurrency & Performance
- **TaskGroup for parallel operations**: 5 concurrent requests for bulk operations (SpotifyManager.swift:409-443)
- **Atomic load operations**: PlaylistLoadOperation struct prevents race conditions (SpotifyManager.swift:24-32)
- **Rate limiting actor**: Exponential backoff with retry logic (SpotifyWebAPI.swift:19-153)
- **Local caching**: Reduces API calls by ~80% for frequently accessed data

#### Data Integrity
- **Empty track list protection**: Never overwrites cache with empty data (SpotifyManager.swift:718-738)
- **Track count validation**: Warns when cache diverges from API (SpotifyManager.swift:815-818)
- **Post-save verification**: Validates operations after completion (SpotifyManager.swift:881-893)
- **Undo/Redo system**: For track deletions and modifications

### Data Flow Pattern
1. **UI Layer**: SwiftUI views trigger actions via SpotifyManager
2. **Manager Layer**: SpotifyManager coordinates API calls and cache updates
3. **API Layer**: SpotifyWebAPI handles OAuth, rate limiting, and HTTP requests
4. **Cache Layer**: SwiftData persists playlists/tracks locally
5. **Security Layer**: KeychainManager stores credentials securely

### Platform Considerations
- **macOS-first design**: Uses AppKit for some features (NSAlert, native controls)
- **App Sandbox enabled**: Network entitlements required (see below)
- **No external dependencies**: Pure Apple framework stack

## Network Entitlements (Important for macOS)

The app requires network access for Spotify API. Ensure these entitlements are configured:

1. In Xcode, select the Timor target
2. Go to "Signing & Capabilities" tab
3. Verify "App Sandbox" capability is present
4. Ensure "Outgoing Connections (Client)" is checked
5. The app includes **Timor.entitlements** with required network permissions

## Spotify Integration

### Setup Requirements
1. Create a Spotify app at https://developer.spotify.com/dashboard
2. Add redirect URI: `timor://spotify-callback`
3. Note your Client ID and Client Secret
4. The app handles OAuth 2.0 flow automatically

### OAuth 2.0 Flow
1. User enters Client ID and Client Secret in Settings (Cmd+,)
2. Click "Connect to Spotify" to initiate OAuth flow
3. Browser opens for user authorization
4. Spotify redirects to `timor://spotify-callback` with authorization code
5. App exchanges code for access token and refresh token
6. Tokens stored securely in macOS Keychain
7. Access token auto-refreshes 5 minutes before expiration

### API Rate Limiting
- **Minimum request interval**: 100ms between requests
- **Max retries**: 5 attempts with exponential backoff
- **Batch sizes**: 100 tracks/request for playlists, 50 tracks/request for liked songs
- **Concurrent operations**: Limited to 5 parallel requests for bulk operations

### Security Features
- **Keychain storage**: All credentials stored in macOS Keychain (service: "com.timor.spotify")
- **Certificate pinning ready**: Infrastructure in place (SpotifyWebAPI.swift:159-163, currently disabled with TODO)
- **Token refresh automation**: Proactive refresh 5 minutes before expiration (SpotifyWebAPI.swift:320-329)
- **Secure credential handling**: Minimizes secret exposure time

### Caching Strategy
- **SwiftData models**: CachedPlaylist and CachedTrack for persistent storage
- **Cache invalidation**: Snapshot ID comparison detects playlist changes
- **Background sync**: Updates cached playlists in background without blocking UI
- **Atomic operations**: Operation UUIDs prevent race conditions when switching playlists

## Key Configuration Constants

Located in `Constants.swift`:

### Spotify API
- Playlist fetch limit: 50
- Track fetch limit: 100
- Search result limit: 50
- Liked songs batch size: 50
- Bulk like/unlike limit: 50
- Min request interval: 100ms
- Max retries: 5
- Base backoff: 1.0s

### UI Layout
- Sidebar min width: 250pt
- Sidebar ideal width: 300pt
- Track search sheet: 800×600pt
- Create playlist sheet: 400×250pt

### Cache
- Playlist cache key: "cached_playlists"
- Liked songs ID: "LIKED_SONGS"
- Cache store filename: "SpotifyCache.store"

## Development Guidelines

### Code Style
- Use SwiftUI best practices (prefer @State over @StateObject for local state)
- Follow async/await patterns for concurrency
- Use Constants.swift for magic numbers
- Prefer Logger over print() for debugging (migration in progress)

### Security
- Never commit Spotify credentials
- Use KeychainManager for all sensitive data
- Implement certificate pinning for production (TODO: SpotifyWebAPI.swift:162)

### Performance
- Cache aggressively but validate with snapshot IDs
- Use TaskGroup for parallel operations (limit to 5 concurrent)
- Implement rate limiting for all API calls
- Profile with Instruments before optimizing

### Testing (TODO)
- No test coverage currently
- Priority: SpotifyManager business logic, caching, undo system
- Consider integration tests for OAuth flow
- UI testing for critical user flows

## Troubleshooting

### Build Issues
- Clean DerivedData: `rm -rf ~/Library/Developer/Xcode/DerivedData`
- Clean build: `xcodebuild clean build`
- Verify SwiftData schema matches models (CachedPlaylist, PlaylistFolder)

### Network Errors
- Check App Sandbox entitlements (Outgoing Connections)
- Verify Spotify credentials in Settings
- Check rate limiting (429 errors indicate too many requests)

### OAuth Issues
- Verify redirect URI matches: `timor://spotify-callback`
- Check Spotify app settings at https://developer.spotify.com/dashboard
- Clear Keychain items: Service "com.timor.spotify"

### Cache Issues
- Delete cache: Remove SpotifyCache.store from app container
- Reset SwiftData: Delete ~/Library/Containers/com.timor.Timor/Data

## Future Enhancements

See GitHub issues for planned features:
- [ ] Unit and integration tests
- [ ] Enable certificate pinning with Spotify's actual certificate hashes
- [ ] Migrate remaining print() statements to Logger
- [ ] iOS companion app (codebase is 90% ready)
- [ ] Smart playlists with auto-update rules
- [ ] Advanced analytics dashboard
- [ ] Playlist sharing/collaboration features
