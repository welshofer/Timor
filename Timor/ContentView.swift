//
//  ContentView.swift
//  Timor
//
//  Created by Jay Welshofer on 9/24/25.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var items: [Item]
    @StateObject private var spotifyManager = SpotifyManager.shared
    @State private var showingSettings = false

    var body: some View {
        NavigationSplitView {
            List {
                // Spotify Section
                Section("Spotify") {
                    if spotifyManager.isAuthenticated {
                        Button {
                            spotifyManager.logout()
                        } label: {
                            Label("Logout from Spotify", systemImage: "arrow.left.circle")
                        }
                        .foregroundColor(.red)

                        if !spotifyManager.playlists.isEmpty {
                            ForEach(spotifyManager.playlists) { playlist in
                                NavigationLink {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text(playlist.name)
                                            .font(.title)
                                        Text("Owner: \(playlist.owner)")
                                            .foregroundStyle(.secondary)
                                        Text("\(playlist.totalTracks) tracks")
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(playlist.name)
                                            .font(.headline)
                                        Text("\(playlist.totalTracks) tracks")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } else {
                        Button {
                            spotifyManager.authenticate()
                        } label: {
                            Label("Connect to Spotify", systemImage: "music.note.list")
                        }
                        .disabled(spotifyManager.clientID.isEmpty || spotifyManager.clientSecret.isEmpty)

                        if spotifyManager.clientID.isEmpty || spotifyManager.clientSecret.isEmpty {
                            Text("Configure Client ID and Secret in Preferences first")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Uses Spotify Web API")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Original Items Section
                Section("Items") {
                    ForEach(items) { item in
                        NavigationLink {
                            Text("Item at \(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))")
                        } label: {
                            Text(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))
                        }
                    }
                    .onDelete(perform: deleteItems)
                }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 300)
            .toolbar {
                ToolbarItem {
                    Button(action: addItem) {
                        Label("Add Item", systemImage: "plus")
                    }
                }
            }
        } detail: {
            Text("Select an item or playlist")
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .onAppear {
            if spotifyManager.isAuthenticated {
                spotifyManager.fetchPlaylists()
            }
        }
    }

    private func addItem() {
        withAnimation {
            let newItem = Item(timestamp: Date())
            modelContext.insert(newItem)
        }
    }

    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(items[index])
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
