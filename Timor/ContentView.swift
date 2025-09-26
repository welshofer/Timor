//
//  ContentView.swift
//  Timor
//
//  Created by Jay Welshofer on 9/24/25.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @StateObject private var spotifyManager = SpotifyManager.shared
    @State private var showingSettings = false
    @State private var selectedPlaylist: SpotifyManager.Playlist?
    @State private var showShuffleAlert = false
    @State private var shuffleResult = false
    @State private var searchText = ""
    @State private var selectedTracks: Set<SpotifyManager.Track.ID> = []
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var showOnlyEditablePlaylists = true
    @State private var showTrackSearch = false
    @State private var showCreatePlaylist = false
    @State private var isViewingLikedSongs = false
    @State private var newPlaylistName = ""
    @State private var newPlaylistDescription = ""
    @State private var isCreatingPlaylist = false

    var filteredPlaylists: [SpotifyManager.Playlist] {
        if showOnlyEditablePlaylists {
            return spotifyManager.playlists.filter { $0.isEditable }
        }
        return spotifyManager.playlists
    }

    var filteredTracks: [SpotifyManager.Track] {
        if searchText.isEmpty {
            return spotifyManager.currentPlaylistTracks
        }

        let lowercasedSearch = searchText.lowercased()
        return spotifyManager.currentPlaylistTracks.filter { track in
            track.name.lowercased().contains(lowercasedSearch) ||
            track.artist.lowercased().contains(lowercasedSearch) ||
            track.album.lowercased().contains(lowercasedSearch)
        }
    }

    // Safe selection that only includes tracks in current filtered results
    var safeSelection: Binding<Set<SpotifyManager.Track.ID>> {
        Binding(
            get: {
                let validIDs = Set(filteredTracks.map { $0.id })
                return selectedTracks.intersection(validIDs)
            },
            set: { newSelection in
                selectedTracks = newSelection
            }
        )
    }


    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Spotify Playlists")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                // Playlists List
                List {
                    if spotifyManager.isAuthenticated {
                        // Liked Songs special item
                        Button {
                            selectedPlaylist = nil  // Clear selected playlist
                            spotifyManager.selectedPlaylist = nil
                            spotifyManager.isViewingLikedSongs = true
                            searchText = ""
                            selectedTracks = []
                            isViewingLikedSongs = true
                            spotifyManager.fetchLikedSongs()
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    HStack {
                                        Image(systemName: "heart.fill")
                                            .foregroundColor(.red)
                                        Text("Liked Songs")
                                            .font(.headline)
                                    }
                                    Text("Your liked tracks")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(isViewingLikedSongs ? Color.accentColor.opacity(0.1) : Color.clear)

                        Divider()

                        ForEach(filteredPlaylists) { playlist in
                            Button {
                                selectedPlaylist = playlist
                                spotifyManager.selectedPlaylist = playlist  // Keep in sync
                                spotifyManager.isViewingLikedSongs = false
                                searchText = ""
                                selectedTracks = []
                                isViewingLikedSongs = false  // Clear liked songs view
                                spotifyManager.fetchTracksForPlaylist(playlist.id)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        HStack {
                                            Text(playlist.name)
                                                .font(.headline)
                                            if !playlist.isEditable {
                                                Image(systemName: "lock.fill")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Text("\(playlist.totalTracks) tracks • \(playlist.owner)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(selectedPlaylist?.id == playlist.id ? Color.accentColor.opacity(0.1) : Color.clear)
                            .contextMenu {
                                if playlist.isEditable {
                                    Button(role: .destructive) {
                                        Task {
                                            let alert = NSAlert()
                                            alert.messageText = "Delete Playlist?"
                                            alert.informativeText = "Are you sure you want to delete \"\(playlist.name)\"? This cannot be undone."
                                            alert.alertStyle = .warning
                                            alert.addButton(withTitle: "Delete")
                                            alert.addButton(withTitle: "Cancel")

                                            if alert.runModal() == .alertFirstButtonReturn {
                                                let success = await spotifyManager.deletePlaylist(playlist.id)
                                                if !success {
                                                    await MainActor.run {
                                                        let errorAlert = NSAlert()
                                                        errorAlert.messageText = "Failed to Delete"
                                                        errorAlert.informativeText = "Could not delete the playlist. Please try again."
                                                        errorAlert.alertStyle = .warning
                                                        errorAlert.addButton(withTitle: "OK")
                                                        errorAlert.runModal()
                                                    }
                                                } else if selectedPlaylist?.id == playlist.id {
                                                    await MainActor.run {
                                                        selectedPlaylist = nil
                                                    }
                                                }
                                            }
                                        }
                                    } label: {
                                        Label("Delete Playlist", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    } else {
                        // Show empty state when not authenticated
                        VStack {
                            Spacer()
                            Text("Connect to Spotify to see your playlists")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding()
                            Spacer()
                        }
                    }
                }
                .listStyle(.sidebar)

                Divider()

                // Bottom controls section
                VStack(spacing: 12) {
                    // Spotify section label
                    HStack {
                        Text("Spotify")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }

                    // Login/Logout button
                    if spotifyManager.isAuthenticated {
                        Button {
                            spotifyManager.logout()
                        } label: {
                            HStack {
                                Image(systemName: "stop.circle")
                                    .foregroundColor(.red)
                                Text("Logout from Spotify")
                                    .foregroundColor(.red)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            spotifyManager.authenticate()
                        } label: {
                            HStack {
                                Image(systemName: "music.note.list")
                                Text("Connect to Spotify")
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(spotifyManager.clientID.isEmpty || spotifyManager.clientSecret.isEmpty)

                        if spotifyManager.clientID.isEmpty || spotifyManager.clientSecret.isEmpty {
                            Text("Configure Client ID and Secret in Preferences first")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                    }

                    // Only Editable toggle - now at the bottom
                    if spotifyManager.isAuthenticated {
                        Toggle("Only Editable", isOn: $showOnlyEditablePlaylists)
                            .toggleStyle(.switch)
                            .font(.caption)
                    }
                }
                .padding(12)
                .background(Color(NSColor.controlBackgroundColor))
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 300)
            .toolbar {
                if spotifyManager.isAuthenticated {
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: { showCreatePlaylist = true }) {
                            Label("Create Playlist", systemImage: "text.badge.plus")
                        }
                        .help("Create a new Spotify playlist")
                    }
                }
            }
        } detail: {
            if selectedPlaylist != nil || isViewingLikedSongs {
                VStack(alignment: .leading, spacing: 0) {
                    // Playlist header
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                if isViewingLikedSongs {
                                    Image(systemName: "heart.fill")
                                        .foregroundColor(.red)
                                        .font(.largeTitle)
                                }
                                Text(isViewingLikedSongs ? "Liked Songs" : (selectedPlaylist?.name ?? ""))
                                    .font(.largeTitle)
                                    .bold()
                            }
                            HStack(spacing: 4) {
                                if isViewingLikedSongs {
                                    Text("\(spotifyManager.currentPlaylistTracks.count) liked songs")
                                } else if let playlist = selectedPlaylist {
                                    Text("By \(playlist.owner) • \(playlist.totalTracks) tracks")
                                }
                                if !searchText.isEmpty {
                                    Text("• Showing \(filteredTracks.count)")
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .padding()

                    Divider()

                    // Tracks table
                    if spotifyManager.isLoadingTracks {
                        VStack(spacing: 16) {
                            ProgressView()
                            if spotifyManager.loadingProgress.total > 0 {
                                Text("Loading \(spotifyManager.loadingProgress.current) of \(spotifyManager.loadingProgress.total) tracks...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Loading tracks...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if spotifyManager.currentPlaylistTracks.isEmpty {
                        Text("No tracks in this playlist")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        // Always use Table with resizable columns
                        Table(filteredTracks, selection: safeSelection) {
                            TableColumn("Title", value: \.name)
                                .width(min: 200)
                            TableColumn("Artist", value: \.artist)
                                .width(min: 150)
                            TableColumn("Album", value: \.album)
                                .width(min: 150)
                            TableColumn("Release Date", value: \.releaseDate)
                                .width(120)
                            TableColumn("Duration", value: \.duration)
                                .width(80)
                            TableColumn(Text(Image(systemName: "heart.fill")).font(.caption)) { track in
                                Button(action: {
                                    print("Heart button clicked for track: \(track.name)")
                                    Task {
                                        if track.isLiked {
                                            print("Track is liked, unliking...")
                                            _ = await spotifyManager.unlikeTrack(track)
                                        } else {
                                            print("Track is not liked, liking...")
                                            _ = await spotifyManager.likeTrack(track)
                                        }
                                    }
                                }) {
                                    Image(systemName: track.isLiked ? "heart.fill" : "heart")
                                        .foregroundColor(track.isLiked ? .red : .secondary)
                                }
                                .buttonStyle(.borderless)
                                .help(track.isLiked ? "Remove from Liked Songs" : "Add to Liked Songs")
                            }
                            .width(30)
                        }
                        .contextMenu(forSelectionType: SpotifyManager.Track.ID.self) { items in
                            if items.isEmpty {
                                Text("No selection")
                            } else if items.count == 1, searchText.isEmpty {
                                // Single track - allow liking and reordering via context menu
                                if let trackId = items.first,
                                   let track = spotifyManager.currentPlaylistTracks.first(where: { $0.id == trackId }) {
                                    Button {
                                        print("Context menu like action for track: \(track.name)")
                                        Task {
                                            if track.isLiked {
                                                print("Track is liked, removing from liked songs...")
                                                _ = await spotifyManager.unlikeTrack(track)
                                            } else {
                                                print("Track is not liked, adding to liked songs...")
                                                _ = await spotifyManager.likeTrack(track)
                                            }
                                        }
                                    } label: {
                                        Label(track.isLiked ? "Remove from Liked Songs" : "Add to Liked Songs",
                                              systemImage: track.isLiked ? "heart.fill" : "heart")
                                    }

                                    Divider()
                                }

                                Button("Move to Top") {
                                    if let trackId = items.first,
                                       let index = spotifyManager.currentPlaylistTracks.firstIndex(where: { $0.id == trackId }),
                                       index > 0 {
                                        Task {
                                            await spotifyManager.reorderTracks(
                                                in: selectedPlaylist!.id,
                                                from: IndexSet(integer: index),
                                                to: 0
                                            )
                                        }
                                    }
                                }
                                Button("Move Up") {
                                    if let trackId = items.first,
                                       let index = spotifyManager.currentPlaylistTracks.firstIndex(where: { $0.id == trackId }),
                                       index > 0 {
                                        Task {
                                            await spotifyManager.reorderTracks(
                                                in: selectedPlaylist!.id,
                                                from: IndexSet(integer: index),
                                                to: index - 1
                                            )
                                        }
                                    }
                                }
                                .keyboardShortcut("↑", modifiers: [.command])
                                Button("Move Down") {
                                    if let trackId = items.first,
                                       let index = spotifyManager.currentPlaylistTracks.firstIndex(where: { $0.id == trackId }),
                                       index < spotifyManager.currentPlaylistTracks.count - 1 {
                                        Task {
                                            await spotifyManager.reorderTracks(
                                                in: selectedPlaylist!.id,
                                                from: IndexSet(integer: index),
                                                to: index + 2
                                            )
                                        }
                                    }
                                }
                                .keyboardShortcut("↓", modifiers: [.command])
                                Button("Move to Bottom") {
                                    if let trackId = items.first,
                                       let index = spotifyManager.currentPlaylistTracks.firstIndex(where: { $0.id == trackId }),
                                       index < spotifyManager.currentPlaylistTracks.count - 1 {
                                        Task {
                                            await spotifyManager.reorderTracks(
                                                in: selectedPlaylist!.id,
                                                from: IndexSet(integer: index),
                                                to: spotifyManager.currentPlaylistTracks.count
                                            )
                                        }
                                    }
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    showDeleteConfirmation = true
                                }
                            } else {
                                Button("Delete \(items.count) tracks", role: .destructive) {
                                    showDeleteConfirmation = true
                                }
                            }
                        }
                        .id("\(selectedPlaylist?.id ?? "")-\(searchText)-\(spotifyManager.currentPlaylistTracks.count)") // Force table recreation on playlist or search change
                    }
                }
                .searchable(text: $searchText, prompt: "Search tracks")
                .onChange(of: searchText) { _ in
                    // Clear selection when search changes to prevent crash
                    selectedTracks.removeAll()
                }
                .toolbar {
                    if selectedPlaylist?.isEditable ?? false {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                showTrackSearch = true
                            } label: {
                                Label("Add Tracks", systemImage: "plus.square.fill.on.square.fill")
                            }
                            .help("Search and add tracks to this playlist")
                        }
                    }

                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            searchText = ""
                            if let playlistId = selectedPlaylist?.id {
                                spotifyManager.fetchTracksForPlaylist(playlistId)
                            } else {
                                // Refresh Liked Songs
                                spotifyManager.fetchLikedSongs()
                            }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(spotifyManager.isLoadingTracks)
                        .help("Refresh tracks")
                    }

                    if !selectedTracks.isEmpty && (selectedPlaylist?.isEditable ?? false) {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                showDeleteConfirmation = true
                            } label: {
                                Label("Delete \(selectedTracks.count)", systemImage: "trash")
                            }
                            .help("Delete selected tracks from playlist")
                        }
                    }

                    if !spotifyManager.currentPlaylistTracks.isEmpty {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                let playlistName = selectedPlaylist?.name ?? "Liked Songs"
                                spotifyManager.exportPlaylistToCSV(playlistName: playlistName)
                            } label: {
                                Label("Export", systemImage: "square.and.arrow.down")
                            }
                            .help("Export to CSV file")
                        }

                        if let playlist = selectedPlaylist, playlist.isEditable {
                            ToolbarItem(placement: .primaryAction) {
                                Button {
                                    Task {
                                        shuffleResult = await spotifyManager.shuffleAndSavePlaylist(playlist.id)
                                        showShuffleAlert = true
                                    }
                                } label: {
                                    Label("Shuffle", systemImage: "shuffle")
                                }
                                .disabled(spotifyManager.isShuffling || spotifyManager.isLoadingTracks)
                                .help("Shuffle and save playlist order")
                            }
                        }
                    }
                }
            } else {
                Text("Select a playlist to view tracks")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showTrackSearch) {
            if let playlist = selectedPlaylist {
                TrackSearchView(
                    isPresented: $showTrackSearch,
                    playlistId: playlist.id,
                    playlistName: playlist.name
                )
            }
        }
        .sheet(isPresented: $showCreatePlaylist) {
            VStack(spacing: 20) {
                Text("Create New Playlist")
                    .font(.title2)
                    .bold()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Playlist Name")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("My Awesome Playlist", text: $newPlaylistName)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Description (Optional)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("A great collection of songs", text: $newPlaylistDescription)
                        .textFieldStyle(.roundedBorder)
                }

                Spacer()

                HStack {
                    Button("Cancel") {
                        newPlaylistName = ""
                        newPlaylistDescription = ""
                        showCreatePlaylist = false
                    }
                    .keyboardShortcut(.escape)

                    Spacer()

                    Button("Create") {
                        isCreatingPlaylist = true
                        Task {
                            let success = await spotifyManager.createPlaylist(
                                name: newPlaylistName,
                                description: newPlaylistDescription
                            )

                            await MainActor.run {
                                isCreatingPlaylist = false
                                if success {
                                    let playlistNameToSelect = newPlaylistName  // Save before clearing
                                    newPlaylistName = ""
                                    newPlaylistDescription = ""
                                    showCreatePlaylist = false
                                    // Wait a moment for the playlist list to refresh, then select the new playlist
                                    Task {
                                        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
                                        if let newPlaylist = spotifyManager.playlists.first(where: { $0.name == playlistNameToSelect }) {
                                            selectedPlaylist = newPlaylist
                                            spotifyManager.selectedPlaylist = newPlaylist  // Keep in sync
                                            spotifyManager.fetchTracksForPlaylist(newPlaylist.id)
                                        }
                                    }
                                } else {
                                    // Show error
                                    let alert = NSAlert()
                                    alert.messageText = "Failed to Create Playlist"
                                    alert.informativeText = "Could not create the playlist. Please try again."
                                    alert.alertStyle = .warning
                                    alert.addButton(withTitle: "OK")
                                    alert.runModal()
                                }
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newPlaylistName.isEmpty || isCreatingPlaylist)
                }
            }
            .padding()
            .frame(width: 400, height: 250)
        }
        .alert("Playlist Shuffle", isPresented: $showShuffleAlert) {
            Button("OK") { }
        } message: {
            if shuffleResult {
                Text("Successfully shuffled and saved the playlist! The new order has been permanently saved to Spotify.")
            } else {
                Text("Failed to save shuffled playlist. Please check your permissions and try again.")
            }
        }
        .confirmationDialog(
            "Delete Tracks",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectedTracks.count) track\(selectedTracks.count == 1 ? "" : "s")", role: .destructive) {
                Task {
                    guard let playlist = selectedPlaylist else { return }
                    isDeleting = true
                    // Convert selected IDs to tracks
                    let tracksToDelete = Set(spotifyManager.currentPlaylistTracks.filter { selectedTracks.contains($0.id) })
                    let success = await spotifyManager.deleteTracksFromPlaylist(playlist.id, tracks: tracksToDelete)
                    isDeleting = false

                    if success {
                        // Only clear selection, keep search term
                        await MainActor.run {
                            selectedTracks.removeAll()
                        }
                    } else {
                        // Show error alert
                        await MainActor.run {
                            let alert = NSAlert()
                            alert.messageText = "Delete Failed"
                            alert.informativeText = "Failed to delete tracks from playlist. Please try again."
                            alert.alertStyle = .warning
                            alert.addButton(withTitle: "OK")
                            alert.runModal()
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will permanently remove the selected track\(selectedTracks.count == 1 ? "" : "s") from your Spotify playlist. This action cannot be undone.")
        }
        // Playlists load automatically on authentication
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
