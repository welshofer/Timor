//
//  TimorApp.swift
//  Timor
//
//  Created by Jay Welshofer on 9/24/25.
//

import SwiftUI
import SwiftData

@main
struct TimorApp: App {
    @State private var showingSettings = false

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            CachedPlaylist.self,
            PlaylistFolder.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
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
