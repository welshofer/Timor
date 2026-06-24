//
//  TimorApp.swift
//  Timor
//
//  Created by Jay Welshofer on 9/24/25.
//

import SwiftUI
import SwiftData
import os.log

@main
struct TimorApp: App {
    @State private var showingSettings = false

    private static let logger = Logger(subsystem: "com.timor", category: "TimorApp")

    var sharedModelContainer: ModelContainer = {
        // STAB-2: schema must declare every related model. CachedPlaylist has a
        // relationship to CachedTrack, so CachedTrack must be present or init throws.
        let schema = Schema([
            CachedPlaylist.self,
            CachedTrack.self,
            PlaylistFolder.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            // STAB-1: never hard-crash on launch. A migration/IO failure falls back to
            // an in-memory container so the app stays usable (the persistent cache is
            // owned by SpotifyManager's own store; this container only backs the
            // SwiftUI environment, which no view currently reads from).
            let reason = error.localizedDescription
            TimorApp.logger.error("ModelContainer init failed: \(reason, privacy: .public). Using in-memory fallback.")
            do {
                let memoryConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                return try ModelContainer(for: schema, configurations: [memoryConfiguration])
            } catch {
                // In-memory init only fails if the schema itself is invalid — a
                // programmer error that would surface in development, not in the field.
                fatalError("In-memory ModelContainer init failed (invalid schema): \(error)")
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)

        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}
