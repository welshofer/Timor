# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Timor is a SwiftUI + SwiftData application for macOS/iOS. It's currently a minimal template app with basic item management functionality.

## Build and Development Commands

### Building the Project
```bash
# Build using Xcode command line tools
xcodebuild -project Timor.xcodeproj -scheme Timor -configuration Debug build

# Build for specific platform
xcodebuild -project Timor.xcodeproj -scheme Timor -destination 'platform=macOS' build
xcodebuild -project Timor.xcodeproj -scheme Timor -destination 'platform=iOS Simulator,name=iPhone 15' build
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
- **SwiftData**: Modern persistence framework for data management
- **Platform Support**: Both macOS and iOS with platform-specific UI adaptations

### Key Components

1. **TimorApp.swift**: Main app entry point
   - Configures SwiftData ModelContainer with in-memory or persistent storage
   - Provides the model container to the entire app via environment

2. **ContentView.swift**: Primary user interface
   - Uses NavigationSplitView for master-detail layout
   - Implements CRUD operations for Item entities
   - Platform-specific toolbar configurations for iOS/macOS

3. **Item.swift**: Core data model
   - SwiftData @Model class with timestamp property
   - Serves as the base entity for the application's data layer

### Data Flow Pattern
- SwiftData models are accessed via @Query property wrapper
- ModelContext is injected through @Environment for data mutations
- All data operations (insert, delete) are wrapped in withAnimation for smooth UI updates

### Platform Considerations
- The app uses conditional compilation (#if os(macOS/iOS)) for platform-specific features
- Navigation column widths are configured differently for macOS
- iOS includes an EditButton in the toolbar for list management

## Network Entitlements (Important for macOS)

If you encounter network errors like "A server with the specified hostname could not be found" on macOS:
1. In Xcode, select the Timor target
2. Go to "Signing & Capabilities" tab
3. Add "App Sandbox" capability if not present
4. Ensure "Outgoing Connections (Client)" is checked
5. The app includes a Timor.entitlements file with required network permissions

## Spotify Integration

The app uses Spotify Web API with OAuth 2.0 Authorization Code Flow for authentication and playlist access.

### Spotify App Setup
1. Create a Spotify app at https://developer.spotify.com
2. Add redirect URI: `timor://spotify-callback`
3. Note the Client ID
4. Install Spotify app on the device (required for SDK)

### Key Components
- **SpotifyManager.swift**: Manages SDK connection and delegates
- **KeychainManager.swift**: Secure credential storage using Keychain
- **SettingsView.swift**: UI for entering Client ID (accessible via Cmd+, on macOS)
- **Info.plist**: Configured with URL scheme for OAuth callback
- **Timor-Bridging-Header.h**: Imports Objective-C SDK

### Authentication Flow

1. User enters Client ID and Client Secret in Preferences (Cmd+,)
2. Click "Connect to Spotify" button
3. Opens browser for OAuth 2.0 authorization
4. User authorizes and returns to app with access token
5. Real playlists fetched from Spotify Web API (`/me/playlists`)

### Key Components
- **SpotifyManager.swift**: Manages Spotify authentication state and playlists
- **SpotifyWebAPI.swift**: OAuth 2.0 authorization code flow and Web API calls
- **KeychainManager.swift**: Secure credential storage using Keychain
- **SettingsView.swift**: Settings UI for entering Spotify credentials