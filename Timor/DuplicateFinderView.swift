//
//  DuplicateFinderView.swift
//  Timor
//
//  Duplicate track detection and removal functionality
//

import SwiftUI

/// Represents a group of duplicate tracks (same trackId appearing multiple times)
struct DuplicateGroup: Identifiable {
    let id: String  // The trackId
    let trackName: String
    let artist: String
    let album: String
    let occurrences: [DuplicateOccurrence]

    var count: Int { occurrences.count }
    var duplicateCount: Int { occurrences.count - 1 }

    /// The first occurrence (which we typically keep)
    var firstOccurrence: DuplicateOccurrence? { occurrences.first }

    /// All occurrences except the first (duplicates to potentially remove)
    var duplicates: [DuplicateOccurrence] { Array(occurrences.dropFirst()) }
}

/// Represents a single occurrence of a track in the playlist
struct DuplicateOccurrence: Identifiable, Hashable {
    let id: String  // The unique track.id (includes position)
    let trackId: String
    let position: Int
    let track: SpotifyManager.Track
}

/// View for finding and removing duplicate tracks in a playlist
struct DuplicateFinderView: View {
    @ObservedObject var spotifyManager: SpotifyManager
    let playlist: SpotifyManager.Playlist?
    @Binding var isPresented: Bool

    @State private var duplicateGroups: [DuplicateGroup] = []
    @State private var selectedForRemoval: Set<String> = []  // Track IDs to remove
    @State private var isRemoving = false
    @State private var showRemoveConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Content
            if duplicateGroups.isEmpty {
                noDuplicatesView
            } else {
                duplicateListView
            }

            Divider()

            // Footer with actions
            footerView
        }
        .frame(width: Constants.UI.duplicateFinderWidth, height: Constants.UI.duplicateFinderHeight)
        .onAppear {
            findDuplicates()
        }
        .confirmationDialog(
            "Remove Duplicates",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove \(selectedForRemoval.count) Duplicate(s)", role: .destructive) {
                Task {
                    await removeDuplicates()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove the selected duplicate tracks from the playlist. This action cannot be undone.")
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Find Duplicates")
                    .font(.headline)
                if let playlist = playlist {
                    Text(playlist.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !duplicateGroups.isEmpty {
                Text("\(duplicateGroups.count) duplicate group(s) found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: - No Duplicates View

    private var noDuplicatesView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("No Duplicates Found")
                .font(.headline)
            Text("This playlist has no duplicate tracks.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No duplicates found. This playlist has no duplicate tracks.")
    }

    // MARK: - Duplicate List View

    private var duplicateListView: some View {
        List {
            ForEach(duplicateGroups) { group in
                duplicateGroupSection(group)
            }
        }
        .listStyle(.inset)
    }

    private func duplicateGroupSection(_ group: DuplicateGroup) -> some View {
        Section {
            // First occurrence (kept)
            if let first = group.firstOccurrence {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading) {
                        Text("Position \(first.position + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Keep this one")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            // Duplicates (can be removed)
            ForEach(group.duplicates) { occurrence in
                HStack {
                    Toggle(isOn: Binding(
                        get: { selectedForRemoval.contains(occurrence.id) },
                        set: { isSelected in
                            if isSelected {
                                selectedForRemoval.insert(occurrence.id)
                            } else {
                                selectedForRemoval.remove(occurrence.id)
                            }
                        }
                    )) {
                        VStack(alignment: .leading) {
                            Text("Position \(occurrence.position + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Duplicate")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #endif
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        } header: {
            HStack {
                VStack(alignment: .leading) {
                    Text(group.trackName)
                        .font(.headline)
                    Text("\(group.artist) - \(group.album)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(group.count) occurrences")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.2))
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            // Select all duplicates button
            if !duplicateGroups.isEmpty {
                Button("Select All Duplicates") {
                    selectAllDuplicates()
                }
                #if os(macOS)
                .buttonStyle(.link)
                #else
                .buttonStyle(.borderless)
                #endif

                Button("Deselect All") {
                    selectedForRemoval.removeAll()
                }
                #if os(macOS)
                .buttonStyle(.link)
                #else
                .buttonStyle(.borderless)
                #endif
            }

            Spacer()

            Button("Close") {
                isPresented = false
            }
            .keyboardShortcut(.escape)

            if !selectedForRemoval.isEmpty {
                Button("Remove Selected (\(selectedForRemoval.count))") {
                    showRemoveConfirmation = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isRemoving)
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func findDuplicates() {
        let tracks = spotifyManager.currentPlaylistTracks

        // Group tracks by trackId
        var trackIdToOccurrences: [String: [DuplicateOccurrence]] = [:]

        for (index, track) in tracks.enumerated() {
            let occurrence = DuplicateOccurrence(
                id: track.id,
                trackId: track.trackId,
                position: index,
                track: track
            )

            if trackIdToOccurrences[track.trackId] == nil {
                trackIdToOccurrences[track.trackId] = []
            }
            trackIdToOccurrences[track.trackId]?.append(occurrence)
        }

        // Filter to only groups with duplicates (count > 1)
        duplicateGroups = trackIdToOccurrences
            .filter { $0.value.count > 1 }
            .map { (trackId, occurrences) in
                let firstTrack = occurrences.first!.track
                return DuplicateGroup(
                    id: trackId,
                    trackName: firstTrack.name,
                    artist: firstTrack.artist,
                    album: firstTrack.album,
                    occurrences: occurrences.sorted { $0.position < $1.position }
                )
            }
            .sorted { $0.count > $1.count }  // Sort by most duplicates first

        // Auto-select all duplicates (all except first occurrence in each group)
        selectAllDuplicates()
    }

    private func selectAllDuplicates() {
        selectedForRemoval.removeAll()
        for group in duplicateGroups {
            for duplicate in group.duplicates {
                selectedForRemoval.insert(duplicate.id)
            }
        }
    }

    private func removeDuplicates() async {
        guard let playlist = playlist, !selectedForRemoval.isEmpty else { return }

        isRemoving = true
        defer { isRemoving = false }

        // Get the tracks to remove
        let tracksToRemove = Set(
            spotifyManager.currentPlaylistTracks.filter { selectedForRemoval.contains($0.id) }
        )

        // Delete them
        let success = await spotifyManager.deleteTracksFromPlaylist(
            playlist.id,
            tracks: tracksToRemove
        )

        if success {
            // Refresh the duplicate list
            findDuplicates()

            // If no more duplicates, close the sheet
            if duplicateGroups.isEmpty {
                isPresented = false
            }
        }
    }
}

// MARK: - SpotifyManager Extension

extension SpotifyManager {
    /// Returns the count of duplicate tracks in the current playlist
    var duplicateTrackCount: Int {
        let trackIdCounts = Dictionary(grouping: currentPlaylistTracks) { $0.trackId }
            .mapValues { $0.count }

        return trackIdCounts.values.filter { $0 > 1 }.reduce(0) { $0 + ($1 - 1) }
    }

    /// Returns true if the current playlist has any duplicate tracks
    var hasDuplicates: Bool {
        duplicateTrackCount > 0
    }
}
