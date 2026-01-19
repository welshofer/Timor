# Timor Architecture

This document provides a comprehensive overview of Timor's architecture, design patterns, and system interactions.

## System Overview

```mermaid
graph TB
    subgraph "Presentation Layer"
        CV[ContentView]
        PSV[PlaylistSidebarView]
        PDV[PlaylistDetailView]
        TTV[TrackTableView or TrackListView]
        TIV[TrackInspectorView]
        SV[SettingsView]
    end

    subgraph "State Management Layer"
        SM[SpotifyManager]
        PUM[PlaylistUndoManager]
    end

    subgraph "API Layer"
        SWAPI[SpotifyWebAPI]
        RL[RateLimiter]
    end

    subgraph "Persistence Layer"
        SD[(SwiftData)]
        KC[(Keychain)]
        IC[ImageCache]
    end

    subgraph "External Services"
        SAPI[Spotify Web API]
    end

    CV --> PSV
    CV --> PDV
    PDV --> TTV
    PDV --> TIV
    CV --> SV

    PSV --> SM
    PDV --> SM
    TTV --> SM
    SV --> SM

    SM --> SWAPI
    SM --> PUM
    SM --> SD
    SM --> IC

    SWAPI --> RL
    SWAPI --> KC
    SWAPI --> SAPI

    RL --> SAPI
```

## Component Responsibilities

### Presentation Layer

| Component | Platform | Responsibility |
|-----------|----------|----------------|
| `ContentView` | Both | Main coordinator, NavigationSplitView layout |
| `PlaylistSidebarView` | Both | Playlist navigation, folder management |
| `PlaylistDetailView` | Both | Track list container, toolbar actions |
| `TrackTableView` | macOS | NSTableView-style track display |
| `TrackListView` | iOS | SwiftUI List with swipe actions |
| `TrackInspectorView` | Both | Track metadata panel |
| `SettingsView` | Both | OAuth credentials, preferences |

### State Management Layer

| Component | Responsibility |
|-----------|----------------|
| `SpotifyManager` | Central state store, business logic, caching |
| `PlaylistUndoManager` | Undo/redo stack for destructive operations |

### API Layer

| Component | Responsibility |
|-----------|----------------|
| `SpotifyWebAPI` | OAuth flow, HTTP requests, token management |
| `RateLimiter` | Request throttling, exponential backoff |

### Persistence Layer

| Component | Responsibility |
|-----------|----------------|
| SwiftData | Local playlist/track cache |
| Keychain | Secure credential storage |
| `ImageCache` | Album artwork caching |

## Data Flow

```mermaid
sequenceDiagram
    participant User
    participant View
    participant SpotifyManager
    participant SpotifyWebAPI
    participant RateLimiter
    participant SwiftData
    participant SpotifyAPI

    User->>View: Select playlist
    View->>SpotifyManager: loadPlaylistTracks(id)

    SpotifyManager->>SwiftData: Check cache
    alt Cache hit & valid
        SwiftData-->>SpotifyManager: Cached tracks
        SpotifyManager-->>View: Update UI immediately
        SpotifyManager->>SpotifyWebAPI: Verify snapshot ID
    else Cache miss or stale
        SpotifyManager->>SpotifyWebAPI: fetchPlaylistTracks(id)
    end

    SpotifyWebAPI->>RateLimiter: waitIfNeeded()
    RateLimiter-->>SpotifyWebAPI: OK to proceed
    SpotifyWebAPI->>SpotifyAPI: GET /playlists/{id}/tracks
    SpotifyAPI-->>SpotifyWebAPI: Track data
    SpotifyWebAPI-->>SpotifyManager: Parsed tracks

    SpotifyManager->>SwiftData: Update cache
    SpotifyManager-->>View: Update UI
    View-->>User: Display tracks
```

## Threading Model

```mermaid
graph LR
    subgraph "Main Thread (@MainActor)"
        SM[SpotifyManager]
        SWAPI[SpotifyWebAPI]
        PUM[PlaylistUndoManager]
        Views[All SwiftUI Views]
    end

    subgraph "Background Actors"
        RL[RateLimiter Actor]
    end

    subgraph "Background Queues"
        NM[Network Monitor Queue]
        URL[URLSession Delegate Queue]
    end

    SM -->|async/await| RL
    SWAPI -->|async/await| RL
    RL -->|suspended until ready| URL
    NM -->|DispatchQueue.main.async| SM
```

### Key Threading Decisions

1. **`@MainActor` for State Classes**: `SpotifyManager`, `SpotifyWebAPI`, and `PlaylistUndoManager` are all `@MainActor` to ensure thread-safe UI updates.

2. **Actor for Rate Limiting**: `RateLimiter` uses Swift's `actor` type to safely manage mutable state (`retryAfter`, `consecutiveFailures`) across concurrent requests.

3. **Background Network Monitoring**: `NWPathMonitor` runs on a dedicated dispatch queue, dispatching state updates back to main.

## Module Dependency Graph

```mermaid
graph TD
    TA[TimorApp] --> CV[ContentView]
    TA --> SM[SpotifyManager]

    CV --> PSV[PlaylistSidebarView]
    CV --> PDV[PlaylistDetailView]
    CV --> TIV[TrackInspectorView]
    CV --> SV[SettingsView]

    PDV --> TTV[TrackTableView]
    PDV --> TLV[TrackListView]
    PDV --> TFV[TrackFilterView]
    PDV --> TSV[TrackSearchView]
    PDV --> DFV[DuplicateFinderView]
    PDV --> IV[ImportView]
    PDV --> PStat[PlaylistStatsView]

    SM --> SWAPI[SpotifyWebAPI]
    SM --> PUM[PlaylistUndoManager]
    SM --> CP[CachedPlaylist]
    SM --> PF[PlaylistFolder]
    SM --> IC[ImageCache]

    SWAPI --> KC[KeychainManager]
    SWAPI --> RL[RateLimiter]
    SWAPI --> Const[Constants]

    KC --> Const
    SM --> Const
```

## Platform Abstraction

Timor uses compile-time platform conditionals for native experiences:

```mermaid
graph TB
    subgraph "Shared Code (~90%)"
        SM[SpotifyManager]
        SWAPI[SpotifyWebAPI]
        Models[Data Models]
        Logic[Business Logic]
    end

    subgraph "macOS Specific"
        TTV[TrackTableView]
        NSA[NSAlert dialogs]
        AppK[AppKit integrations]
    end

    subgraph "iOS Specific"
        TLV[TrackListView]
        Swipe[Swipe Actions]
        UIK[UIKit integrations]
    end

    subgraph "Conditional Compilation"
        CV[ContentView]
        SV[SettingsView]
    end

    SM --> TTV
    SM --> TLV
    CV -->|"#if os(macOS)"| TTV
    CV -->|"#if os(iOS)"| TLV
```

### Platform-Specific Patterns

```swift
// Import pattern
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// View pattern
#if os(macOS)
TrackTableView(...)  // NSTableView-backed
#else
TrackListView(...)   // SwiftUI List with EditMode
#endif

// Dialog pattern
#if os(macOS)
NSAlert().runModal()
#else
.alert(isPresented: ...)
#endif
```

## Error Handling Architecture

```mermaid
graph TD
    subgraph "Error Sources"
        NET[Network Errors]
        API[API Errors]
        AUTH[Auth Errors]
        DATA[Data Errors]
    end

    subgraph "Error Types"
        SE[SpotifyError enum]
    end

    subgraph "Error Handling"
        SM[SpotifyManager.displayError]
        SWAPI[SpotifyWebAPI error mapping]
    end

    subgraph "User Feedback"
        Alert[Error Alert]
        Recovery[Recovery Suggestion]
        Retry[Automatic Retry]
    end

    NET --> SE
    API --> SE
    AUTH --> SE
    DATA --> SE

    SE --> SWAPI
    SWAPI --> SM
    SM --> Alert
    SM --> Recovery

    SE -->|429 Rate Limit| Retry
    SE -->|5xx Server| Retry
```

### SpotifyError Categories

| Category | Examples | Recovery |
|----------|----------|----------|
| Authentication | `notAuthenticated`, `tokenRefreshFailed` | Reconnect in Settings |
| Network | `networkUnavailable`, `connectionFailed` | Check connection |
| Rate Limiting | `rateLimited(retryAfter:)` | Automatic retry |
| API | `playlistNotFound`, `permissionDenied` | User action required |
| Data | `decodingFailed`, `invalidData` | Report bug |

## Security Architecture

```mermaid
graph TB
    subgraph "Credential Storage"
        KC[Keychain]
        CID[Client ID - Standard]
        CS[Client Secret - High]
        AT[Access Token - Standard]
        RT[Refresh Token - High]
    end

    subgraph "Network Security"
        CERT[Certificate Pinning]
        TLS[TLS 1.3]
    end

    subgraph "Token Lifecycle"
        AUTH[OAuth Flow]
        REFRESH[Proactive Refresh]
        EXPIRE[Expiry Tracking]
    end

    CID --> KC
    CS --> KC
    AT --> KC
    RT --> KC

    CERT --> TLS
    AUTH --> AT
    AUTH --> RT
    REFRESH --> AT
    EXPIRE --> REFRESH
```

### Keychain Protection Levels

| Key | Protection Level | Accessibility |
|-----|------------------|---------------|
| Client ID | Standard | When Unlocked |
| Client Secret | High | When Unlocked, This Device Only |
| Access Token | Standard | When Unlocked |
| Refresh Token | High | When Unlocked, This Device Only |

## Performance Optimizations

### Caching Strategy

```mermaid
graph LR
    subgraph "Request Flow"
        REQ[API Request]
        CACHE[Check Cache]
        API[Spotify API]
        STORE[Store Result]
    end

    subgraph "Cache Validation"
        SNAP[Snapshot ID]
        TIME[Last Synced]
        COUNT[Track Count]
    end

    REQ --> CACHE
    CACHE -->|Hit| SNAP
    SNAP -->|Match| UI[Return Cached]
    SNAP -->|Mismatch| API
    CACHE -->|Miss| API
    API --> STORE
    STORE --> UI
```

### Concurrent Operations

```mermaid
graph TB
    subgraph "Bulk Track Fetch"
        BATCH[Batch Request]
        TG[TaskGroup]
        T1[Task 1: Tracks 0-99]
        T2[Task 2: Tracks 100-199]
        T3[Task 3: Tracks 200-299]
        T4[Task 4: Tracks 300-399]
        T5[Task 5: Tracks 400-499]
        MERGE[Merge Results]
    end

    BATCH --> TG
    TG --> T1
    TG --> T2
    TG --> T3
    TG --> T4
    TG --> T5
    T1 --> MERGE
    T2 --> MERGE
    T3 --> MERGE
    T4 --> MERGE
    T5 --> MERGE
```

**Concurrency Limit**: 5 parallel requests to balance speed vs. rate limiting.

## Build Targets

```mermaid
graph TB
    subgraph "Xcode Project"
        PROJ[Timor.xcodeproj]
    end

    subgraph "Targets"
        MAC[Timor - macOS]
        IOS[Timor iOS]
        TEST[TimorTests]
    end

    subgraph "Shared Sources"
        TIMOR[Timor Sources]
    end

    PROJ --> MAC
    PROJ --> IOS
    PROJ --> TEST

    MAC --> TIMOR
    IOS --> TIMOR
    TEST --> TIMOR
```

| Target | Platform | Min Version | Bundle ID |
|--------|----------|-------------|-----------|
| Timor | macOS | 26.0 | xsf.welshofer.Timor |
| Timor iOS | iOS/iPadOS | 26.0 | xsf.welshofer.Timor |
| TimorTests | macOS | 26.0 | com.timor.TimorTests |
