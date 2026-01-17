//
//  PlaylistUndoManager.swift
//  Timor
//
//  Undo/Redo system for playlist operations
//

import Foundation
import SwiftUI
import Combine

/// Manages undo/redo operations for playlist modifications
@MainActor
class PlaylistUndoManager: ObservableObject {
    /// The underlying Foundation UndoManager
    let undoManager = UndoManager()

    /// Whether an undo/redo operation is currently in progress
    @Published var isUndoRedoInProgress = false

    /// The ID of the playlist these undo actions belong to
    @Published private(set) var currentPlaylistId: String?

    init() {
        undoManager.levelsOfUndo = 20
    }

    /// Sets the current playlist context. Clears undo stack if playlist changes.
    func setPlaylist(_ playlistId: String?) {
        if currentPlaylistId != playlistId {
            undoManager.removeAllActions()
            currentPlaylistId = playlistId
        }
    }

    /// Clears all undo/redo history
    func clear() {
        undoManager.removeAllActions()
    }

    /// Whether undo is available
    var canUndo: Bool {
        undoManager.canUndo
    }

    /// Whether redo is available
    var canRedo: Bool {
        undoManager.canRedo
    }

    /// The name of the action that would be undone
    var undoActionName: String? {
        undoManager.undoActionName.isEmpty ? nil : undoManager.undoActionName
    }

    /// The name of the action that would be redone
    var redoActionName: String? {
        undoManager.redoActionName.isEmpty ? nil : undoManager.redoActionName
    }

    /// Performs undo
    func undo() {
        guard canUndo, !isUndoRedoInProgress else { return }
        undoManager.undo()
    }

    /// Performs redo
    func redo() {
        guard canRedo, !isUndoRedoInProgress else { return }
        undoManager.redo()
    }

    // MARK: - Track Deletion Undo

    /// Registers an undo action for track deletion
    func registerTrackDeletion(
        playlistId: String,
        deletedTracks: [(track: SpotifyManager.Track, position: Int)],
        restoreAction: @escaping (String, [(SpotifyManager.Track, Int)]) async -> Bool
    ) {
        guard playlistId == currentPlaylistId else { return }

        let trackCount = deletedTracks.count
        let actionName = trackCount == 1 ? "Delete Track" : "Delete \(trackCount) Tracks"

        undoManager.registerUndo(withTarget: self) { [weak self] manager in
            guard let self = self else { return }
            self.isUndoRedoInProgress = true

            Task { @MainActor in
                let success = await restoreAction(playlistId, deletedTracks)

                // Register redo action
                if success {
                    self.undoManager.registerUndo(withTarget: self) { [weak self] _ in
                        guard let self = self else { return }
                        self.isUndoRedoInProgress = true

                        // Redo = delete again (handled by caller)
                        Task { @MainActor in
                            // The redo action will re-delete the tracks
                            // This is complex because track IDs change after restore
                            // For now, redo after delete undo is not fully supported
                            self.isUndoRedoInProgress = false
                        }
                    }
                    self.undoManager.setActionName(actionName)
                }

                self.isUndoRedoInProgress = false
            }
        }
        undoManager.setActionName(actionName)
    }

    // MARK: - Shuffle Undo

    /// Registers an undo action for playlist shuffle
    func registerShuffle(
        playlistId: String,
        originalTracks: [SpotifyManager.Track],
        restoreAction: @escaping (String, [SpotifyManager.Track]) async -> Bool
    ) {
        guard playlistId == currentPlaylistId else { return }

        let actionName = "Shuffle Playlist"

        undoManager.registerUndo(withTarget: self) { [weak self] manager in
            guard let self = self else { return }
            self.isUndoRedoInProgress = true

            Task { @MainActor in
                let success = await restoreAction(playlistId, originalTracks)

                if success {
                    // We could register a redo here, but shuffle is random
                    // so redo would produce a different order anyway
                }

                self.isUndoRedoInProgress = false
            }
        }
        undoManager.setActionName(actionName)
    }

    // MARK: - Reorder Undo

    /// Registers an undo action for track reordering
    func registerReorder(
        playlistId: String,
        originalTracks: [SpotifyManager.Track],
        restoreAction: @escaping (String, [SpotifyManager.Track]) async -> Bool
    ) {
        guard playlistId == currentPlaylistId else { return }

        let actionName = "Reorder Tracks"

        undoManager.registerUndo(withTarget: self) { [weak self] manager in
            guard let self = self else { return }
            self.isUndoRedoInProgress = true

            Task { @MainActor in
                _ = await restoreAction(playlistId, originalTracks)
                self.isUndoRedoInProgress = false
            }
        }
        undoManager.setActionName(actionName)
    }

    // MARK: - Like/Unlike Undo

    /// Registers an undo action for liking a track
    func registerLike(
        track: SpotifyManager.Track,
        unlikeAction: @escaping (SpotifyManager.Track) async -> Bool
    ) {
        let actionName = "Like \"\(track.name)\""

        undoManager.registerUndo(withTarget: self) { [weak self] manager in
            guard let self = self else { return }
            self.isUndoRedoInProgress = true

            Task { @MainActor in
                _ = await unlikeAction(track)
                self.isUndoRedoInProgress = false
            }
        }
        undoManager.setActionName(actionName)
    }

    /// Registers an undo action for unliking a track
    func registerUnlike(
        track: SpotifyManager.Track,
        likeAction: @escaping (SpotifyManager.Track) async -> Bool
    ) {
        let actionName = "Remove from Liked Songs"

        undoManager.registerUndo(withTarget: self) { [weak self] manager in
            guard let self = self else { return }
            self.isUndoRedoInProgress = true

            Task { @MainActor in
                _ = await likeAction(track)
                self.isUndoRedoInProgress = false
            }
        }
        undoManager.setActionName(actionName)
    }
}
