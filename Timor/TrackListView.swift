//
//  TrackListView.swift
//  Timor
//
//  iOS-specific track list with drag-to-reorder support using SwiftUI List
//

import SwiftUI

// MARK: - Track Sort Options

/// Defines available sort options for the track list.
/// Used across both iOS and macOS for consistency.
enum TrackSortOption: String, CaseIterable, Identifiable {
    case title
    case artist
    case album
    case releaseDate
    case duration
    case liked

    var id: String { rawValue }

    /// The user-facing label shown in the sort menu
    var label: String {
        switch self {
        case .title: return "Title"
        case .artist: return "Artist"
        case .album: return "Album"
        case .releaseDate: return "Release Date"
        case .duration: return "Duration"
        case .liked: return "Liked"
        }
    }

    /// SF Symbol icon for the sort option (optional, for menu display)
    var icon: String {
        switch self {
        case .title: return "textformat"
        case .artist: return "person"
        case .album: return "square.stack"
        case .releaseDate: return "calendar"
        case .duration: return "clock"
        case .liked: return "heart"
        }
    }
}

/// Sort direction for track sorting
enum SortDirection {
    case ascending
    case descending

    mutating func toggle() {
        self = (self == .ascending) ? .descending : .ascending
    }

    var icon: String {
        self == .ascending ? "chevron.up" : "chevron.down"
    }
}

#if os(iOS)
struct TrackListView: View {
    @ObservedObject var spotifyManager: SpotifyManager
    let playlist: SpotifyManager.Playlist?
    @Binding var selectedTracks: Set<SpotifyManager.Track.ID>
    @Binding var searchText: String
    @Binding var showDeleteConfirmation: Bool
    @Binding var selectedTrack: SpotifyManager.Track?

    // View mode: nil = playlist order (reorder enabled), non-nil = sorted view
    @State private var activeSortOption: TrackSortOption? = nil
    @State private var sortDirection: SortDirection = .ascending

    @State private var editMode: EditMode = .inactive
    @State private var debouncedSearchText: String = ""
    @State private var searchDebounceTask: Task<Void, Never>?

    // Stable copy of tracks to prevent crashes during iteration
    @State private var stableTracks: [SpotifyManager.Track] = []

    /// Whether we're in playlist order mode (reordering allowed)
    private var isPlaylistOrderMode: Bool {
        activeSortOption == nil
    }

    private var canReorder: Bool {
        guard let playlist = playlist else { return false }
        return playlist.isEditable && isPlaylistOrderMode && debouncedSearchText.isEmpty
    }

    /// Tracks after filtering and sorting - uses stable copy
    private var displayTracks: [SpotifyManager.Track] {
        var tracks = stableTracks

        // Apply search filter
        if !debouncedSearchText.isEmpty {
            let search = debouncedSearchText.lowercased()
            tracks = tracks.filter {
                $0.name.lowercased().contains(search) ||
                $0.artist.lowercased().contains(search) ||
                $0.album.lowercased().contains(search)
            }
        }

        // Apply sorting if active
        if let sortOption = activeSortOption {
            tracks = sortTracks(tracks, by: sortOption, direction: sortDirection)
        }

        return tracks
    }

    private var isEditable: Bool {
        playlist?.isEditable ?? false
    }

    var body: some View {
        listContent
    }

    @ViewBuilder
    private var listContent: some View {
        List {
            ForEach(displayTracks) { track in
                row(for: track)
            }
            .onMove { from, to in
                guard let playlist = playlist else { return }
                // Update local stable copy for immediate UI feedback
                stableTracks.move(fromOffsets: from, toOffset: to)
                Task {
                    await spotifyManager.reorderTracks(in: playlist.id, from: from, to: to)
                }
            }
            .onDelete { offsets in
                let toDelete = offsets.map { displayTracks[$0] }
                selectedTracks = Set(toDelete.map { $0.id })
                showDeleteConfirmation = true
            }
            .moveDisabled(!canReorder)
            .deleteDisabled(!canReorder)
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // Sort menu
                Menu {
                    // Playlist Order option (enables reordering)
                    Button {
                        withAnimation {
                            activeSortOption = nil
                            editMode = .inactive
                        }
                    } label: {
                        Label("Playlist Order", systemImage: isPlaylistOrderMode ? "checkmark" : "list.number")
                    }

                    Divider()

                    // Sort options
                    ForEach(TrackSortOption.allCases) { option in
                        Button {
                            withAnimation {
                                if activeSortOption == option {
                                    sortDirection.toggle()
                                } else {
                                    activeSortOption = option
                                    sortDirection = .ascending
                                }
                                editMode = .inactive
                            }
                        } label: {
                            HStack {
                                Label(option.label, systemImage: option.icon)
                                if activeSortOption == option {
                                    Image(systemName: sortDirection.icon)
                                }
                            }
                        }
                    }
                } label: {
                    Label(
                        activeSortOption?.label ?? "Sort",
                        systemImage: isPlaylistOrderMode ? "list.number" : "arrow.up.arrow.down"
                    )
                }

                // Edit button (only in playlist order mode for editable playlists)
                if canReorder {
                    EditButton()
                }
            }
        }
        .safeAreaInset(edge: .top) {
            // Mode indicator banner
            if !isPlaylistOrderMode {
                sortModeBanner
            }
        }
        .onChange(of: searchText) { _, newValue in
            debounceSearch(newValue)
        }
        .onChange(of: activeSortOption) { _, newValue in
            // Exit edit mode when switching to sorted view
            if newValue != nil {
                editMode = .inactive
            }
        }
        .onChange(of: spotifyManager.currentPlaylistTracks) { _, newTracks in
            // Update stable copy when source data changes
            // Use async to avoid mutation during render cycle
            Task { @MainActor in
                stableTracks = newTracks
            }
        }
        .onAppear {
            debouncedSearchText = searchText
            // Initialize stable tracks copy if not already set
            if stableTracks.isEmpty && !spotifyManager.currentPlaylistTracks.isEmpty {
                stableTracks = spotifyManager.currentPlaylistTracks
            }
        }
        .task {
            // Ensure tracks are synced when view loads
            stableTracks = spotifyManager.currentPlaylistTracks
        }
    }

    /// Banner shown when in sorted view mode
    private var sortModeBanner: some View {
        HStack {
            Image(systemName: "arrow.up.arrow.down.circle.fill")
                .foregroundStyle(.orange)
            Text("Sorted by \(activeSortOption?.label ?? "")")
                .font(.caption)
            Text("• Reorder disabled")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                withAnimation {
                    activeSortOption = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func row(for track: SpotifyManager.Track) -> some View {
        HStack(spacing: 12) {
            artwork(for: track)
            info(for: track)
            Spacer()
            if track.isLiked {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            Text(track.duration)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: isEditable) {
            if isEditable {
                let trackId = track.id
                Button(role: .destructive) {
                    selectedTracks = [trackId]
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .swipeActions(edge: .leading) {
            let trackId = track.id
            let isCurrentlyLiked = track.isLiked
            Button {
                Task {
                    // Re-fetch track from current state to avoid stale reference
                    guard let currentTrack = spotifyManager.currentPlaylistTracks.first(where: { $0.id == trackId }) else { return }
                    if currentTrack.isLiked {
                        _ = await spotifyManager.unlikeTrack(currentTrack)
                    } else {
                        _ = await spotifyManager.likeTrack(currentTrack)
                    }
                }
            } label: {
                Label(isCurrentlyLiked ? "Unlike" : "Like",
                      systemImage: isCurrentlyLiked ? "heart.slash" : "heart")
            }
            .tint(isCurrentlyLiked ? .gray : .red)
        }
    }

    @ViewBuilder
    private func artwork(for track: SpotifyManager.Track) -> some View {
        let url: URL? = {
            guard let urlString = track.albumArtURL, !urlString.isEmpty else { return nil }
            return URL(string: urlString)
        }()

        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            case .failure, .empty:
                placeholderImage
            @unknown default:
                placeholderImage
            }
        }
        .frame(width: 50, height: 50)
        .cornerRadius(4)
    }

    private var placeholderImage: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.3))
            .overlay {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
            }
    }

    private func info(for track: SpotifyManager.Track) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.name)
                .font(.body)
                .lineLimit(1)
            Text(track.artist)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(track.album)
                if !track.releaseDate.isEmpty {
                    Text("•")
                    Text(track.releaseDate)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
    }

    private func debounceSearch(_ value: String) {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                debouncedSearchText = value
                if !value.isEmpty { editMode = .inactive }
            }
        }
    }

    /// Sorts tracks by the given option and direction
    private func sortTracks(
        _ tracks: [SpotifyManager.Track],
        by option: TrackSortOption,
        direction: SortDirection
    ) -> [SpotifyManager.Track] {
        let sorted = tracks.sorted { a, b in
            let comparison: Bool
            switch option {
            case .title:
                comparison = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .artist:
                comparison = a.artist.localizedCaseInsensitiveCompare(b.artist) == .orderedAscending
            case .album:
                comparison = a.album.localizedCaseInsensitiveCompare(b.album) == .orderedAscending
            case .releaseDate:
                comparison = a.releaseDate.localizedCaseInsensitiveCompare(b.releaseDate) == .orderedAscending
            case .duration:
                // Duration is formatted as "M:SS" - compare the underlying milliseconds if available
                // For now, string comparison works for same-length durations
                comparison = a.duration.localizedCaseInsensitiveCompare(b.duration) == .orderedAscending
            case .liked:
                // Liked tracks first (true > false), then by name for stability
                if a.isLiked != b.isLiked {
                    comparison = a.isLiked && !b.isLiked
                } else {
                    comparison = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
            }
            return direction == .ascending ? comparison : !comparison
        }
        return sorted
    }
}
#endif
