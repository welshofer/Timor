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

    // Cached filtered results to avoid recomputation
    @State private var cachedFilteredTracks: [SpotifyManager.Track] = []
    @State private var lastTrackCount: Int = 0
    @State private var lastSearchText: String = ""

    // Sorting state
    @State private var sortOrder: [KeyPathComparator<SpotifyManager.Track>] = []

    // Advanced filter state
    @State private var trackFilter = TrackFilter()
    @State private var showFilterPopover = false

    var filteredTracks: [SpotifyManager.Track] {
        // Use cached results if inputs haven't changed
        let currentTrackCount = spotifyManager.currentPlaylistTracks.count
        if debouncedSearchText == lastSearchText && currentTrackCount == lastTrackCount && !trackFilter.isActive {
            return cachedFilteredTracks
        }

        var result = spotifyManager.currentPlaylistTracks

        // Apply text search filter
        if !debouncedSearchText.isEmpty {
            let lowercasedSearch = debouncedSearchText.lowercased()
            result = result.filter { track in
                track.name.lowercased().contains(lowercasedSearch) ||
                track.artist.lowercased().contains(lowercasedSearch) ||
                track.album.lowercased().contains(lowercasedSearch)
            }
        }

        // Apply advanced filter
        if trackFilter.isActive {
            result = result.filter { trackFilter.matches($0) }
        }

        return result
    }

    /// Sorted and filtered tracks for display
    var sortedFilteredTracks: [SpotifyManager.Track] {
        if sortOrder.isEmpty {
            return filteredTracks
        }
        return filteredTracks.sorted(using: sortOrder)
    }
    
    // Safe selection that only includes tracks in current filtered results
    var safeSelection: Binding<Set<SpotifyManager.Track.ID>> {
        Binding(
            get: {
                let validIDs = Set(sortedFilteredTracks.map { $0.id })
                return selectedTracks.intersection(validIDs)
            },
            set: { newSelection in
                selectedTracks = newSelection
                // Update selected track for inspector
                if let firstId = newSelection.first,
                   newSelection.count == 1,
                   let track = sortedFilteredTracks.first(where: { $0.id == firstId }) {
                    selectedTrack = track
                } else if newSelection.isEmpty {
                    selectedTrack = nil
                }
            }
        )
    }

    /// Tracks that are currently selected (for drag & drop)
    var selectedTrackObjects: [SpotifyManager.Track] {
        sortedFilteredTracks.filter { selectedTracks.contains($0.id) }
    }

    /// Whether sorting is currently active
    var isSortingActive: Bool {
        !sortOrder.isEmpty
    }

    var body: some View {
        Table(sortedFilteredTracks, selection: safeSelection, sortOrder: $sortOrder) {
            // ATTR-5: album-art thumbnail column (cached via ImageCache).
            TableColumn("") { track in
                TrackArtworkThumbnail(urlString: track.albumArtURL)
            }
            .width(40)
            TableColumn("Title", value: \.name)
                .width(min: 200)
            TableColumn("Artist", value: \.artist)
                .width(min: 150)
            TableColumn("Album", value: \.album)
                .width(min: 150)
            TableColumn("Release Date", value: \.releaseDate)
                .width(120)
            // FUNC-2: sort by numeric durationSeconds; display the "M:SS" string.
            TableColumn("Duration", value: \.durationSeconds) { track in
                Text(track.duration)
                    .monospacedDigit()
            }
            .width(80)
            TableColumn(Text(Image(systemName: "heart.fill")).font(.caption)) { track in
                LikeButton(track: track, spotifyManager: spotifyManager)
            }
            .width(30)
        }
        .onDrag {
            // Create an NSItemProvider with the selected tracks
            let tracks = selectedTrackObjects
            guard !tracks.isEmpty else {
                return NSItemProvider()
            }

            // Encode tracks as JSON data
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(tracks) {
                let provider = NSItemProvider()
                provider.registerDataRepresentation(
                    forTypeIdentifier: "xsf.welshofer.Timor.spotifytrack",
                    visibility: .all
                ) { completion in
                    completion(data, nil)
                    return nil
                }
                return provider
            }
            return NSItemProvider()
        }
        .contextMenu(forSelectionType: SpotifyManager.Track.ID.self) { items in
            TrackContextMenu(
                items: items,
                playlist: playlist,
                spotifyManager: spotifyManager,
                showDeleteConfirmation: $showDeleteConfirmation,
                searchText: debouncedSearchText,
                isSortingActive: isSortingActive
            )
        }
        .onDeleteCommand {
            // USE-2: ⌫ deletes the current selection (standard Mac idiom).
            if !selectedTracks.isEmpty, playlist?.isEditable == true {
                showDeleteConfirmation = true
            }
        }
        // Optimized ID: only includes playlist ID and search text, not count
        // This prevents full table rebuild on track additions/removals
        .id("\(playlist?.id ?? "")-\(debouncedSearchText)-\(trackFilter.activeFilterCount)")
        .safeAreaInset(edge: .top) {
            HStack(spacing: 12) {
                if trackFilter.isActive {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                            .foregroundStyle(.blue)
                        Text("\(trackFilter.activeFilterCount) filter\(trackFilter.activeFilterCount == 1 ? "" : "s") active")
                            .font(.caption)
                        Text("(\(sortedFilteredTracks.count) tracks)")
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
        .onChange(of: searchText) { oldValue, newValue in
            // Debounce search input - wait 300ms before filtering
            searchDebounceTask?.cancel()
            searchDebounceTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    debouncedSearchText = newValue
                    updateCachedFilteredTracks()
                }
            }
        }
        .onChange(of: spotifyManager.currentPlaylistTracks.count) { _, _ in
            // Update cache when tracks change
            updateCachedFilteredTracks()
        }
        .onAppear {
            debouncedSearchText = searchText
            updateCachedFilteredTracks()
        }
    }

    private func updateCachedFilteredTracks() {
        lastSearchText = debouncedSearchText
        lastTrackCount = spotifyManager.currentPlaylistTracks.count

        if debouncedSearchText.isEmpty {
            cachedFilteredTracks = spotifyManager.currentPlaylistTracks
        } else {
            let lowercasedSearch = debouncedSearchText.lowercased()
            cachedFilteredTracks = spotifyManager.currentPlaylistTracks.filter { track in
                track.name.lowercased().contains(lowercasedSearch) ||
                track.artist.lowercased().contains(lowercasedSearch) ||
                track.album.lowercased().contains(lowercasedSearch)
            }
        }
    }
}

struct LikeButton: View {
    let track: SpotifyManager.Track
    let spotifyManager: SpotifyManager
    
    var body: some View {
        Button(action: {
            Task {
                if track.isLiked {
                    _ = await spotifyManager.unlikeTrack(track)
                } else {
                    _ = await spotifyManager.likeTrack(track)
                }
            }
        }) {
            Image(systemName: track.isLiked ? "heart.fill" : "heart")
                .foregroundColor(track.isLiked ? .red : .secondary)
                .contentTransition(.symbolEffect(.replace))   // ATTR-4: animated toggle
                .symbolEffect(.bounce, value: track.isLiked)
        }
        .buttonStyle(.borderless)
        .help(track.isLiked ? "Remove from Liked Songs" : "Add to Liked Songs")
        .accessibilityLabel(track.isLiked ? "Liked" : "Not liked")   // USE-3
        .accessibilityHint("Toggles whether this track is in your Liked Songs")
    }
}

/// ATTR-5: Small album-art thumbnail for the macOS track table. Uses ImageCache's
/// DOWNSAMPLED thumbnail path so disk IO and decoding happen off the main thread and the
/// cached image is tiny — this is what keeps the table scrolling smoothly (decoding full
/// 640×640 art per row on the main thread is what made it janky).
struct TrackArtworkThumbnail: View {
    let urlString: String?
    @State private var image: PlatformImage?

    /// Target thumbnail size in pixels (32pt cell at up to ~3× Retina).
    private static let maxPixel: CGFloat = 96

    var body: some View {
        Group {
            if let image = image {
                platformImage(image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityHidden(true)
        .task(id: urlString) {
            guard let urlString = urlString, !urlString.isEmpty else {
                image = nil
                return
            }
            // Instant for recycled rows (memory only, no IO); otherwise decode off-main.
            if let cached = ImageCache.shared.cachedThumbnail(for: urlString, maxPixel: Self.maxPixel) {
                image = cached
            } else {
                image = await ImageCache.shared.thumbnail(for: urlString, maxPixel: Self.maxPixel)
            }
        }
    }
}

struct TrackContextMenu: View {
    let items: Set<SpotifyManager.Track.ID>
    let playlist: SpotifyManager.Playlist?
    let spotifyManager: SpotifyManager
    @Binding var showDeleteConfirmation: Bool
    let searchText: String
    let isSortingActive: Bool

    /// Get the selected tracks
    var selectedTracks: [SpotifyManager.Track] {
        spotifyManager.currentPlaylistTracks.filter { items.contains($0.id) }
    }

    /// Count of unliked tracks in selection
    var unlikedCount: Int {
        selectedTracks.filter { !$0.isLiked }.count
    }

    /// Count of liked tracks in selection
    var likedCount: Int {
        selectedTracks.filter { $0.isLiked }.count
    }

    var body: some View {
        if items.isEmpty {
            Text("No selection")
        } else if items.count == 1, searchText.isEmpty, let trackId = items.first {
            SingleTrackContextMenu(
                trackId: trackId,
                playlist: playlist,
                spotifyManager: spotifyManager,
                showDeleteConfirmation: $showDeleteConfirmation,
                isSortingActive: isSortingActive
            )
        } else {
            // Multiple selection context menu
            if unlikedCount > 0 {
                Button {
                    Task {
                        let _ = await spotifyManager.bulkLikeTracks(selectedTracks)
                    }
                } label: {
                    Label("Like \(unlikedCount) Track\(unlikedCount == 1 ? "" : "s")",
                          systemImage: "heart")
                }
            }

            if likedCount > 0 {
                Button {
                    Task {
                        let _ = await spotifyManager.bulkUnlikeTracks(selectedTracks)
                    }
                } label: {
                    Label("Unlike \(likedCount) Track\(likedCount == 1 ? "" : "s")",
                          systemImage: "heart.slash")
                }
            }

            Divider()

            if let playlist = playlist, playlist.isEditable {
                Button("Delete \(items.count) Track\(items.count == 1 ? "" : "s")", role: .destructive) {
                    showDeleteConfirmation = true
                }
            }
        }
    }
}

struct SingleTrackContextMenu: View {
    let trackId: SpotifyManager.Track.ID
    let playlist: SpotifyManager.Playlist?
    let spotifyManager: SpotifyManager
    @Binding var showDeleteConfirmation: Bool
    let isSortingActive: Bool

    var track: SpotifyManager.Track? {
        spotifyManager.currentPlaylistTracks.first(where: { $0.id == trackId })
    }

    /// Can reorder only when not sorting and playlist is editable
    var canReorder: Bool {
        guard let playlist = playlist else { return false }
        return playlist.isEditable && !isSortingActive
    }

    var body: some View {
        if let track = track {
            Button {
                Task {
                    if track.isLiked {
                        _ = await spotifyManager.unlikeTrack(track)
                    } else {
                        _ = await spotifyManager.likeTrack(track)
                    }
                }
            } label: {
                Label(track.isLiked ? "Remove from Liked Songs" : "Add to Liked Songs",
                      systemImage: track.isLiked ? "heart.fill" : "heart")
            }

            Divider()

            if let playlist = playlist, playlist.isEditable {
                // Move options - disabled when sorting is active
                Button("Move to Top") {
                    moveTrack(to: 0)
                }
                .disabled(!canReorder)

                Button("Move Up") {
                    if let index = spotifyManager.currentPlaylistTracks.firstIndex(where: { $0.id == trackId }),
                       index > 0 {
                        moveTrack(to: index - 1)
                    }
                }
                .keyboardShortcut("↑", modifiers: [.command])
                .disabled(!canReorder)

                Button("Move Down") {
                    if let index = spotifyManager.currentPlaylistTracks.firstIndex(where: { $0.id == trackId }),
                       index < spotifyManager.currentPlaylistTracks.count - 1 {
                        moveTrack(to: index + 2)
                    }
                }
                .keyboardShortcut("↓", modifiers: [.command])
                .disabled(!canReorder)

                Button("Move to Bottom") {
                    moveTrack(to: spotifyManager.currentPlaylistTracks.count)
                }
                .disabled(!canReorder)

                if isSortingActive {
                    Text("Clear sorting to reorder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Button("Delete", role: .destructive) {
                    showDeleteConfirmation = true
                }
            }
        }
    }
    
    private func moveTrack(to destination: Int) {
        guard let playlist = playlist,
              let index = spotifyManager.currentPlaylistTracks.firstIndex(where: { $0.id == trackId }) else {
            return
        }

        Task {
            await spotifyManager.reorderTracks(
                in: playlist.id,
                from: IndexSet(integer: index),
                to: destination
            )
        }
    }
}
#endif