//
//  TrackSearchView.swift
//  Timor
//
//  Modal view for searching and adding tracks to playlists
//

import SwiftUI

struct TrackSearchView: View {
    @Binding var isPresented: Bool
    let playlistId: String
    let playlistName: String

    @State private var titleSearch = ""
    @State private var artistSearch = ""
    @State private var albumSearch = ""
    @State private var yearSearch = ""
    @State private var searchResults: [SpotifyManager.Track] = []
    @State private var selectedTracks: Set<SpotifyManager.Track.ID> = []
    @State private var isSearching = false
    @State private var isAdding = false
    @State private var sortOrder = [KeyPathComparator(\SpotifyManager.Track.name)]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Text("Add Tracks to \(playlistName)")
                    .font(.title2)
                    .bold()

                // Search fields
                HStack(spacing: 12) {
                    VStack(alignment: .leading) {
                        Text("Title")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Song title", text: $titleSearch)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { performSearch() }
                    }

                    VStack(alignment: .leading) {
                        Text("Artist")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Artist name", text: $artistSearch)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { performSearch() }
                    }
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading) {
                        Text("Album")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Album name", text: $albumSearch)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { performSearch() }
                    }

                    VStack(alignment: .leading) {
                        Text("Year")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Release year", text: $yearSearch)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { performSearch() }
                    }
                    .frame(maxWidth: 100)
                }

                HStack {
                    Button("Clear") {
                        titleSearch = ""
                        artistSearch = ""
                        albumSearch = ""
                        yearSearch = ""
                        searchResults = []
                        selectedTracks = []
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button("Search") {
                        performSearch()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSearching || (titleSearch.isEmpty && artistSearch.isEmpty && albumSearch.isEmpty && yearSearch.isEmpty))
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Result count
            if !searchResults.isEmpty && !isSearching {
                HStack {
                    Text("\(searchResults.count) results")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("Click column headers to sort")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            }

            // Results table
            if isSearching {
                VStack {
                    ProgressView()
                    Text("Searching...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if searchResults.isEmpty {
                VStack {
                    Text("Enter search terms and click Search")
                        .foregroundColor(.secondary)
                    Text("Up to 100 results will be shown")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(searchResults, selection: $selectedTracks, sortOrder: $sortOrder) {
                    TableColumn("Title", value: \.name)
                        .width(min: 200)
                    TableColumn("Artist", value: \.artist)
                        .width(min: 150)
                    TableColumn("Album", value: \.album)
                        .width(min: 150)
                    TableColumn("Year", value: \.releaseDate)
                        .width(ideal: 80, max: 100)
                    TableColumn("Duration", value: \.duration)
                        .width(ideal: 60, max: 80)
                }
                .onChange(of: sortOrder) { newOrder in
                    searchResults.sort(using: newOrder)
                }
            }

            Divider()

            // Footer buttons
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.escape)

                Spacer()

                if !selectedTracks.isEmpty {
                    Text("\(selectedTracks.count) track\(selectedTracks.count == 1 ? "" : "s") selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button("Add Selected") {
                    addSelectedTracks()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedTracks.isEmpty || isAdding)
            }
            .padding()
        }
        .frame(width: 800, height: 600)
    }

    private func performSearch() {
        Task {
            isSearching = true
            selectedTracks = []

            let tracks = await SpotifyWebAPI.shared.searchTracks(
                title: titleSearch.trimmingCharacters(in: .whitespacesAndNewlines),
                artist: artistSearch.trimmingCharacters(in: .whitespacesAndNewlines),
                album: albumSearch.trimmingCharacters(in: .whitespacesAndNewlines),
                year: yearSearch.trimmingCharacters(in: .whitespacesAndNewlines)
            )

            await MainActor.run {
                searchResults = tracks
                isSearching = false
            }
        }
    }

    private func addSelectedTracks() {
        Task {
            isAdding = true

            let tracksToAdd = searchResults.filter { selectedTracks.contains($0.id) }
            let trackUris = tracksToAdd.map { $0.uri }

            let success = await SpotifyWebAPI.shared.addTracksToPlaylist(
                playlistId: playlistId,
                trackUris: trackUris
            )

            await MainActor.run {
                if success {
                    // Refresh the playlist to show new tracks
                    SpotifyManager.shared.fetchTracksForPlaylist(playlistId)
                    isPresented = false
                } else {
                    // Show error
                    let alert = NSAlert()
                    alert.messageText = "Failed to Add Tracks"
                    alert.informativeText = "Could not add the selected tracks to the playlist. Please try again."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
                isAdding = false
            }
        }
    }
}