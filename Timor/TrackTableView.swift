//
//  TrackTableView.swift
//  Timor
//
//  Track table component for displaying playlist tracks (macOS only)
//  iOS uses TrackListView with drag-to-reorder support
//

import SwiftUI
import Combine

#if os(macOS)
struct TrackTableView: View {
    @ObservedObject var spotifyManager: SpotifyManager
    let playlist: SpotifyManager.Playlist?
    @Binding var selectedTracks: Set<SpotifyManager.Track.ID>
    @Binding var searchText: String
    @Binding var showDeleteConfirmation: Bool
    @Binding var selectedTrack: SpotifyManager.Track?

    // Debounced search for performance
    @State private var debouncedSearchText: String = ""
    @State private var searchDebounceTask: Task<Void, Never>?

    // PERF-3: materialized filtered + sorted tracks. Recomputed once when inputs change
    // (search/filter/sort/track-list) instead of re-sorting on every body render and every
    // read of the selection binding. `displayIDs` lets safeSelection avoid rebuilding a Set.
    @State private var displayTracks: [SpotifyManager.Track] = []
    @State private var displayIDs: Set<SpotifyManager.Track.ID> = []

    // Sorting state
    @State private var sortOrder: [KeyPathComparator<SpotifyManager.Track>] = []

    // Advanced filter state
    @State private var trackFilter = TrackFilter()
    @State private var showFilterPopover = false

    /// PERF-3: recomputes the filtered + sorted display list once, when an input changes.
    private func recomputeDisplayTracks() {
        var result = spotifyManager.currentPlaylistTracks

        if !debouncedSearchText.isEmpty {
            let lowercasedSearch = debouncedSearchText.lowercased()
            result = result.filter { track in
                track.name.lowercased().contains(lowercasedSearch) ||
                track.artist.lowercased().contains(lowercasedSearch) ||
                track.album.lowercased().contains(lowercasedSearch)
            }
        }

        if trackFilter.isActive {
            result = result.filter { trackFilter.matches($0) }
        }

        if !sortOrder.isEmpty {
            result.sort(using: sortOrder)
        }

        displayTracks = result
        displayIDs = Set(result.map { $0.id })
    }

    var body: some View {
        // Native NSTableView for smooth scrolling (multi-select, header sort, drag-to-playlist,
        // context menu, like buttons, and inspector selection are handled in TrackTableRepresentable).
        TrackTableRepresentable(
            tracks: displayTracks,
            selection: $selectedTracks,
            sortOrder: $sortOrder,
            selectedTrack: $selectedTrack,
            showDeleteConfirmation: $showDeleteConfirmation,
            playlist: playlist,
            spotifyManager: spotifyManager,
            canReorder: playlist?.isEditable == true
                && sortOrder.isEmpty
                && debouncedSearchText.isEmpty
                && !trackFilter.isActive
        )
        .safeAreaInset(edge: .top) {
            HStack(spacing: 12) {
                if trackFilter.isActive {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                            .foregroundStyle(.blue)
                        Text("\(trackFilter.activeFilterCount) filter\(trackFilter.activeFilterCount == 1 ? "" : "s") active")
                            .font(.caption)
                        Text("(\(displayTracks.count) tracks)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            withAnimation { trackFilter.reset() }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !sortOrder.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down.circle.fill")
                            .foregroundStyle(.orange)
                        Text("Sorted View")
                            .font(.caption)
                        Text("• Reorder disabled")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            withAnimation { sortOrder = [] }
                        } label: {
                            Text("Show Playlist Order")
                                .font(.caption)
                        }
                        .buttonStyle(.link)
                    }
                }

                Spacer()

                Button {
                    showFilterPopover.toggle()
                } label: {
                    Label("Filter", systemImage: trackFilter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(trackFilter.isActive ? .blue : .primary)
                }
                .buttonStyle(.borderless)
                .help("Advanced filters")
                .popover(isPresented: $showFilterPopover) {
                    TrackFilterView(
                        filter: $trackFilter,
                        tracks: spotifyManager.currentPlaylistTracks
                    )
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
        }
        .onChange(of: searchText) { _, newValue in
            // Debounce search input - wait 300ms before filtering
            searchDebounceTask?.cancel()
            searchDebounceTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    debouncedSearchText = newValue
                    recomputeDisplayTracks()
                }
            }
        }
        // PERF-3: recompute only when an actual input changes, not on every body render.
        .onChange(of: spotifyManager.currentPlaylistTracks) { _, _ in
            recomputeDisplayTracks()
        }
        .onChange(of: sortOrder) { _, _ in
            recomputeDisplayTracks()
        }
        .onChange(of: trackFilter) { _, _ in
            recomputeDisplayTracks()
        }
        .onAppear {
            debouncedSearchText = searchText
            recomputeDisplayTracks()
        }
    }
}

#endif