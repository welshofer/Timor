//
//  TrackSearchView.swift
//  Timor
//
//  Modal view for searching and adding tracks to playlists
//

import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
    @State private var showAddError = false
    // FUNC-5: pagination
    @State private var searchOffset = 0
    @State private var canLoadMore = false
    private let searchPageSize = 50

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
            #if os(macOS)
            .background(Color(NSColor.controlBackgroundColor))
            #else
            .background(Color(UIColor.secondarySystemBackground))
            #endif

            Divider()

            // Result count
            if !searchResults.isEmpty && !isSearching {
                HStack {
                    Text("\(searchResults.count) results")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if canLoadMore {
                        Button("Load More") { Task { await loadMore() } }
                            .font(.caption)
                            .buttonStyle(.link)
                            .disabled(isSearching)
                    }
                    Spacer()
                    Text("Click column headers to sort")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                #if os(macOS)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                #else
                .background(Color(UIColor.secondarySystemBackground).opacity(0.5))
                #endif
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
                    Text("Up to 50 results will be shown")
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
                        .width(100)
                    TableColumn("Duration", value: \.duration)
                        .width(80)
                }
                .onChange(of: sortOrder) { oldValue, newValue in
                    searchResults.sort(using: newValue)
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
        .alert("Failed to Add Tracks", isPresented: $showAddError) {
            Button("OK") { }
        } message: {
            Text("Could not add the selected tracks to the playlist. Please try again.")
        }
    }

    private func performSearch() {
        Task {
            isSearching = true
            selectedTracks = []
            searchOffset = 0

            let tracks = await searchPage(offset: 0)

            await MainActor.run {
                searchResults = tracks
                canLoadMore = tracks.count >= searchPageSize  // FUNC-5: more may exist
                isSearching = false
            }
        }
    }

    /// FUNC-5: fetch the next page of results and append.
    private func loadMore() async {
        guard !isSearching else { return }
        isSearching = true
        let nextOffset = searchOffset + searchPageSize
        let tracks = await searchPage(offset: nextOffset)
        await MainActor.run {
            searchResults.append(contentsOf: tracks)
            searchResults.sort(using: sortOrder)
            searchOffset = nextOffset
            canLoadMore = tracks.count >= searchPageSize
            isSearching = false
        }
    }

    private func searchPage(offset: Int) async -> [SpotifyManager.Track] {
        await SpotifyWebAPI.shared.searchTracks(
            title: titleSearch.trimmingCharacters(in: .whitespacesAndNewlines),
            artist: artistSearch.trimmingCharacters(in: .whitespacesAndNewlines),
            album: albumSearch.trimmingCharacters(in: .whitespacesAndNewlines),
            year: yearSearch.trimmingCharacters(in: .whitespacesAndNewlines),
            limit: searchPageSize,
            offset: offset
        )
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
                    // Update track count in sidebar
                    SpotifyManager.shared.updatePlaylistTrackCount(playlistId, addedCount: tracksToAdd.count)
                    // Refresh the playlist to show new tracks
                    SpotifyManager.shared.fetchTracksForPlaylist(playlistId)
                    isPresented = false
                } else {
                    showAddError = true
                }
                isAdding = false
            }
        }
    }
}