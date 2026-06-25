//
//  PlaylistSidebarView.swift
//  Timor
//
//  Sidebar component for playlist navigation
//

import SwiftUI
import os.log

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Logging
private nonisolated(unsafe) let logger = Logger(subsystem: "com.timor", category: "playlist-sidebar")

struct PlaylistSidebarView: View {
    @ObservedObject var spotifyManager: SpotifyManager
    @Binding var selectedPlaylist: SpotifyManager.Playlist?
    @Binding var isViewingLikedSongs: Bool
    @Binding var searchText: String
    @Binding var selectedTracks: Set<SpotifyManager.Track.ID>
    @Binding var showOnlyEditablePlaylists: Bool
    @Binding var showCreatePlaylist: Bool
    @Binding var showSettings: Bool

    @State private var showCreateFolder = false
    @State private var newFolderName = ""
    @State private var folderToRename: PlaylistFolder?
    @State private var renameFolderText = ""
    @State private var playlistToDelete: SpotifyManager.Playlist?
    @State private var showDeleteConfirmation = false
    @State private var showDeleteError = false
    // FUNC-2: playlist rename
    @State private var playlistToRename: SpotifyManager.Playlist?
    @State private var renamePlaylistText = ""

    var filteredPlaylists: [SpotifyManager.Playlist] {
        if showOnlyEditablePlaylists {
            return spotifyManager.playlists.filter { $0.isEditable }
        }
        return spotifyManager.playlists
    }

    /// Returns filtered playlists not in any folder
    var uncategorizedPlaylists: [SpotifyManager.Playlist] {
        let folderPlaylistIds = Set(spotifyManager.folders.flatMap { $0.playlistIds })
        return filteredPlaylists.filter { !folderPlaylistIds.contains($0.id) }
    }

    /// Returns playlists for a specific folder (filtered)
    func playlistsInFolder(_ folder: PlaylistFolder) -> [SpotifyManager.Playlist] {
        filteredPlaylists.filter { folder.containsPlaylist($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with network status
            HStack {
                Text("Spotify Playlists")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
                NetworkStatusIndicator(spotifyManager: spotifyManager)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Playlists List
            List {
                if spotifyManager.isAuthenticated {
                    // Liked Songs special item
                    LikedSongsRow(
                        isViewingLikedSongs: isViewingLikedSongs,
                        onSelect: {
                            selectedPlaylist = nil
                            spotifyManager.selectedPlaylist = nil
                            spotifyManager.isViewingLikedSongs = true
                            searchText = ""
                            selectedTracks = []
                            isViewingLikedSongs = true
                            spotifyManager.fetchLikedSongs()
                        }
                    )

                    Divider()

                    // Folders with playlists
                    ForEach(spotifyManager.folders) { folder in
                        FolderSection(
                            folder: folder,
                            playlists: playlistsInFolder(folder),
                            selectedPlaylist: selectedPlaylist,
                            currentPlaylistId: selectedPlaylist?.id,
                            onSelectPlaylist: { playlist in
                                selectPlaylist(playlist)
                            },
                            onDeletePlaylist: { playlistToDelete = $0; showDeleteConfirmation = true },
                            onRenamePlaylist: { playlistToRename = $0; renamePlaylistText = $0.name },
                            onRenameFolder: {
                                folderToRename = folder
                                renameFolderText = folder.name
                            },
                            onDeleteFolder: {
                                spotifyManager.deleteFolder(folder)
                            },
                            onToggleExpand: {
                                spotifyManager.toggleFolderExpansion(folder)
                            },
                            spotifyManager: spotifyManager
                        )
                    }

                    // Uncategorized playlists
                    if !uncategorizedPlaylists.isEmpty {
                        Section {
                            ForEach(uncategorizedPlaylists) { playlist in
                                PlaylistRow(
                                    playlist: playlist,
                                    isSelected: selectedPlaylist?.id == playlist.id,
                                    currentPlaylistId: selectedPlaylist?.id,
                                    onSelect: {
                                        selectPlaylist(playlist)
                                    },
                                    onDelete: { playlistToDelete = $0; showDeleteConfirmation = true },
                                    onRename: { playlistToRename = $0; renamePlaylistText = $0.name },
                                    spotifyManager: spotifyManager
                                )
                            }
                        } header: {
                            if !spotifyManager.folders.isEmpty {
                                Text("Uncategorized")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    EmptyPlaylistsView()
                }
            }
            .listStyle(.sidebar)
            .onAppear {
                spotifyManager.fetchFolders()
            }

            Divider()

            // Bottom controls
            SpotifyControlsView(
                spotifyManager: spotifyManager,
                showOnlyEditablePlaylists: $showOnlyEditablePlaylists
            )
        }
        // macOS 26 renders the NavigationSplitView sidebar with a translucent Liquid
        // Glass material automatically — no manual NSVisualEffectView / window hacking.
        .navigationSplitViewColumnWidth(min: Constants.UI.sidebarMinWidth, ideal: Constants.UI.sidebarIdealWidth)
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            #endif
            if spotifyManager.isAuthenticated {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: { showCreateFolder = true }) {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    .help("Create a new folder")

                    Button(action: { showCreatePlaylist = true }) {
                        Label("Create Playlist", systemImage: "text.badge.plus")
                    }
                    .help("Create a new Spotify playlist")
                }
            }
        }
        .sheet(isPresented: $showCreateFolder) {
            CreateFolderSheet(
                folderName: $newFolderName,
                isPresented: $showCreateFolder,
                onCreate: {
                    if !newFolderName.isEmpty {
                        _ = spotifyManager.createFolder(name: newFolderName)
                        newFolderName = ""
                    }
                }
            )
        }
        .sheet(item: $folderToRename) { folder in
            RenameFolderSheet(
                folder: folder,
                folderName: $renameFolderText,
                onRename: {
                    spotifyManager.renameFolder(folder, newName: renameFolderText)
                    folderToRename = nil
                },
                onCancel: {
                    folderToRename = nil
                }
            )
        }
        .sheet(item: $playlistToRename) { playlist in
            RenamePlaylistSheet(
                playlistName: $renamePlaylistText,
                onRename: {
                    let id = playlist.id
                    let newName = renamePlaylistText
                    playlistToRename = nil
                    Task { _ = await spotifyManager.renamePlaylist(id, newName: newName) }
                },
                onCancel: { playlistToRename = nil }
            )
        }
        .confirmationDialog(
            "Delete Playlist?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible,
            presenting: playlistToDelete
        ) { playlist in
            Button("Delete", role: .destructive) {
                Task {
                    let success = await SpotifyManager.shared.deletePlaylist(playlist.id)
                    if !success {
                        showDeleteError = true
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { playlist in
            Text("Are you sure you want to delete \"\(playlist.name)\"? This cannot be undone.")
        }
        .alert("Failed to Delete", isPresented: $showDeleteError) {
            Button("OK") { }
        } message: {
            Text("Could not delete the playlist. Please try again.")
        }
    }

    private func selectPlaylist(_ playlist: SpotifyManager.Playlist) {
        selectedPlaylist = playlist
        spotifyManager.selectedPlaylist = playlist
        spotifyManager.isViewingLikedSongs = false
        searchText = ""
        selectedTracks = []
        isViewingLikedSongs = false
        spotifyManager.fetchTracksForPlaylist(playlist.id)
    }
}

// MARK: - Liked Songs Row

struct LikedSongsRow: View {
    let isViewingLikedSongs: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading) {
                    HStack {
                        Image(systemName: "heart.fill")
                            .foregroundColor(.red)
                            .accessibilityHidden(true)
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
        .accessibilityLabel("Liked Songs. Your liked tracks.")
        .listRowBackground(isViewingLikedSongs ? Color.accentColor.opacity(0.1) : Color.clear)
    }
}

// MARK: - Folder Section

struct FolderSection: View {
    let folder: PlaylistFolder
    let playlists: [SpotifyManager.Playlist]
    let selectedPlaylist: SpotifyManager.Playlist?
    let currentPlaylistId: String?
    let onSelectPlaylist: (SpotifyManager.Playlist) -> Void
    let onDeletePlaylist: (SpotifyManager.Playlist) -> Void
    let onRenamePlaylist: (SpotifyManager.Playlist) -> Void
    let onRenameFolder: () -> Void
    let onDeleteFolder: () -> Void
    let onToggleExpand: () -> Void
    let spotifyManager: SpotifyManager

    @State private var isFolderDropTargeted = false

    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { folder.isExpanded },
            set: { _ in onToggleExpand() }
        )) {
            ForEach(playlists) { playlist in
                PlaylistRow(
                    playlist: playlist,
                    isSelected: selectedPlaylist?.id == playlist.id,
                    currentPlaylistId: currentPlaylistId,
                    onSelect: {
                        onSelectPlaylist(playlist)
                    },
                    onDelete: onDeletePlaylist,
                    onRename: onRenamePlaylist,
                    spotifyManager: spotifyManager
                )
            }
        } label: {
            HStack {
                Image(systemName: folder.isExpanded ? "folder.fill" : "folder")
                    .foregroundStyle(.secondary)
                Text(folder.name)
                    .font(.headline)
                Spacer()
                Text("\(playlists.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                if isFolderDropTargeted {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.blue)
                }
            }
            .contentShape(Rectangle())
        }
        .listRowBackground(isFolderDropTargeted ? Color.blue.opacity(0.2) : Color.clear)
        .onDrop(of: ["xsf.welshofer.Timor.playlist"], isTargeted: $isFolderDropTargeted) { providers in
            guard let provider = providers.first else { return false }

            provider.loadDataRepresentation(forTypeIdentifier: "xsf.welshofer.Timor.playlist") { data, _ in
                guard let data = data,
                      let playlistId = String(data: data, encoding: .utf8) else { return }

                Task { @MainActor in
                    spotifyManager.addPlaylistToFolder(playlistId, folder: folder)
                }
            }
            return true
        }
        .contextMenu {
            Button {
                onRenameFolder()
            } label: {
                Label("Rename Folder", systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                onDeleteFolder()
            } label: {
                Label("Delete Folder", systemImage: "trash")
            }
        }
    }
}

struct PlaylistRow: View {
    let playlist: SpotifyManager.Playlist
    let isSelected: Bool
    let currentPlaylistId: String?
    let onSelect: () -> Void
    let onDelete: (SpotifyManager.Playlist) -> Void
    let onRename: (SpotifyManager.Playlist) -> Void
    let spotifyManager: SpotifyManager

    @State private var isDropTargeted = false

    init(playlist: SpotifyManager.Playlist, isSelected: Bool, currentPlaylistId: String? = nil, onSelect: @escaping () -> Void, onDelete: @escaping (SpotifyManager.Playlist) -> Void = { _ in }, onRename: @escaping (SpotifyManager.Playlist) -> Void = { _ in }, spotifyManager: SpotifyManager) {
        self.playlist = playlist
        self.isSelected = isSelected
        self.currentPlaylistId = currentPlaylistId
        self.onSelect = onSelect
        self.onDelete = onDelete
        self.onRename = onRename
        self.spotifyManager = spotifyManager
    }

    var body: some View {
        Button(action: onSelect) {
            HStack {
                PlaylistCoverThumbnail(urlString: playlist.coverArtURL)  // ATTR-1
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

                // Drop indicator
                if isDropTargeted && playlist.isEditable {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            isDropTargeted && playlist.isEditable
                ? Color.green.opacity(0.2)
                : (isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .onDrag {
            // Make playlists draggable into folders
            let provider = NSItemProvider()
            if let data = playlist.id.data(using: .utf8) {
                provider.registerDataRepresentation(
                    forTypeIdentifier: "xsf.welshofer.Timor.playlist",
                    visibility: .all
                ) { completion in
                    completion(data, nil)
                    return nil
                }
            }
            return provider
        }
        .onDrop(of: ["xsf.welshofer.Timor.spotifytrack"], isTargeted: Binding(
            get: { isDropTargeted },
            set: { targeted in
                isDropTargeted = targeted && playlist.isEditable && playlist.id != currentPlaylistId
            }
        )) { providers in
            // Don't allow dropping on the same playlist or non-editable playlists
            guard playlist.id != currentPlaylistId, playlist.isEditable else {
                return false
            }

            // The native NSTableView drag writes one pasteboard item per row, so collect tracks
            // from ALL providers (each is a single track, or — from older drags — an array),
            // then add them in one batch.
            let group = DispatchGroup()
            let lock = NSLock()
            var collected: [SpotifyManager.Track] = []

            for provider in providers {
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: "xsf.welshofer.Timor.spotifytrack") { data, error in
                    defer { group.leave() }
                    guard let data = data else {
                        logger.error("Drop failed: \(error?.localizedDescription ?? "No data")")
                        return
                    }
                    let decoder = JSONDecoder()
                    var dropped: [SpotifyManager.Track] = []
                    if let tracks = try? decoder.decode([SpotifyManager.Track].self, from: data) {
                        dropped = tracks
                    } else if let track = try? decoder.decode(SpotifyManager.Track.self, from: data) {
                        dropped = [track]
                    }
                    guard !dropped.isEmpty else { return }
                    lock.lock()
                    collected.append(contentsOf: dropped)
                    lock.unlock()
                }
            }

            group.notify(queue: .main) {
                guard !collected.isEmpty else { return }
                Task { @MainActor in
                    await SpotifyManager.shared.addTracksToPlaylist(playlist.id, tracks: collected)
                }
            }
            return true
        }
        .contextMenu {
            // Folder menu
            if !spotifyManager.folders.isEmpty {
                Menu("Move to Folder") {
                    ForEach(spotifyManager.folders) { folder in
                        Button {
                            spotifyManager.addPlaylistToFolder(playlist.id, folder: folder)
                        } label: {
                            Label(folder.name, systemImage: "folder")
                        }
                    }

                    Divider()

                    Button {
                        spotifyManager.removePlaylistFromFolder(playlist.id)
                    } label: {
                        Label("Remove from Folder", systemImage: "folder.badge.minus")
                    }
                }

                Divider()
            }

            if playlist.isEditable {
                Button {
                    onRename(playlist)
                } label: {
                    Label("Rename Playlist…", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    onDelete(playlist)
                } label: {
                    Label("Delete Playlist", systemImage: "trash")
                }
            }
        }
    }
}

struct EmptyPlaylistsView: View {
    var body: some View {
        // ATTR-1: native empty state.
        ContentUnavailableView(
            "Not Connected",
            systemImage: "music.note.list",
            description: Text("Connect to Spotify to see your playlists.")
        )
    }
}

struct SpotifyControlsView: View {
    @ObservedObject var spotifyManager: SpotifyManager
    @Binding var showOnlyEditablePlaylists: Bool
    
    var body: some View {
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
                .disabled(!spotifyManager.hasCredentials)

                if !spotifyManager.hasCredentials {
                    Text("Configure Client ID and Secret in Preferences first")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            
            // Only Editable toggle
            if spotifyManager.isAuthenticated {
                Toggle("Only Editable", isOn: $showOnlyEditablePlaylists)
                    .toggleStyle(.switch)
                    .font(.caption)
            }
        }
        .padding(12)
        // Transparent — sits on the sidebar's own Liquid Glass background.
        #if !os(macOS)
        .background(Color(UIColor.secondarySystemBackground))
        #endif
    }
}

// MARK: - Create Folder Sheet

struct CreateFolderSheet: View {
    @Binding var folderName: String
    @Binding var isPresented: Bool
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: Constants.UI.itemSpacing) {
            Text("Create New Folder")
                .font(.headline)

            TextField("Folder Name", text: $folderName)
                .textFieldStyle(.roundedBorder)
                .frame(width: Constants.UI.sidebarMinWidth)

            HStack {
                Button("Cancel") {
                    folderName = ""
                    isPresented = false
                }
                .keyboardShortcut(.escape)

                Button("Create") {
                    onCreate()
                    isPresented = false
                }
                .keyboardShortcut(.return)
                .disabled(folderName.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.glassProminent)
            }
        }
        .padding(Constants.UI.largePadding)
        .frame(minWidth: Constants.UI.editPlaylistMinWidth)
    }
}

// MARK: - Rename Folder Sheet

struct RenameFolderSheet: View {
    let folder: PlaylistFolder
    @Binding var folderName: String
    let onRename: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: Constants.UI.itemSpacing) {
            Text("Rename Folder")
                .font(.headline)

            TextField("Folder Name", text: $folderName)
                .textFieldStyle(.roundedBorder)
                .frame(width: Constants.UI.sidebarMinWidth)

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.escape)

                Button("Rename") {
                    onRename()
                }
                .keyboardShortcut(.return)
                .disabled(folderName.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.glassProminent)
            }
        }
        .padding(Constants.UI.largePadding)
        .frame(minWidth: Constants.UI.editPlaylistMinWidth)
    }
}

// MARK: - Rename Playlist Sheet (FUNC-2)

struct RenamePlaylistSheet: View {
    @Binding var playlistName: String
    let onRename: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: Constants.UI.itemSpacing) {
            Text("Rename Playlist")
                .font(.headline)

            TextField("Playlist Name", text: $playlistName)
                .textFieldStyle(.roundedBorder)
                .frame(width: Constants.UI.sidebarMinWidth)

            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.escape)

                Button("Rename") { onRename() }
                    .keyboardShortcut(.return)
                    .disabled(playlistName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(Constants.UI.largePadding)
        .frame(minWidth: Constants.UI.editPlaylistMinWidth)
    }
}

// MARK: - Network Status Indicator

/// Shows current network connectivity status
struct NetworkStatusIndicator: View {
    @ObservedObject var spotifyManager: SpotifyManager

    var body: some View {
        Group {
            if !spotifyManager.isOnline {
                // Offline indicator
                HStack(spacing: 4) {
                    Image(systemName: "wifi.slash")
                        .font(.caption)
                    Text("Offline")
                        .font(.caption)
                }
                .foregroundStyle(.orange)
                .help("No internet connection. Showing cached data.")
            } else if spotifyManager.isUsingCache {
                // Online but using cached data
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .help("Showing cached data. Click refresh to update.")
            }
        }
    }
}

// MARK: - Playlist Cover Thumbnail (ATTR-1)

/// Small playlist cover, decoded off the main thread via ImageCache's downsampled thumbnail path.
struct PlaylistCoverThumbnail: View {
    let urlString: String?
    var size: CGFloat = 36
    @State private var image: PlatformImage?

    private var cornerRadius: CGFloat { size >= 56 ? 10 : 4 }
    private var maxPixel: CGFloat { size * 3 }  // crisp on Retina

    var body: some View {
        Group {
            if let image = image {
                platformImage(image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.gray.opacity(0.2))
                    .overlay(
                        Image(systemName: "music.note.list")
                            .font(.system(size: size * 0.4))
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
        .task(id: urlString) {
            guard let urlString = urlString, !urlString.isEmpty else {
                image = nil
                return
            }
            if let cached = ImageCache.shared.cachedThumbnail(for: urlString, maxPixel: maxPixel) {
                image = cached
            } else {
                image = await ImageCache.shared.thumbnail(for: urlString, maxPixel: maxPixel)
            }
        }
    }
}