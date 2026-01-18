//
//  PlaylistUndoManagerTests.swift
//  TimorTests
//
//  Tests for the PlaylistUndoManager undo/redo system
//

import XCTest
@testable import Timor

@MainActor
final class PlaylistUndoManagerTests: XCTestCase {

    var undoManager: PlaylistUndoManager!

    override func setUp() async throws {
        undoManager = PlaylistUndoManager()
    }

    override func tearDown() async throws {
        undoManager = nil
    }

    // MARK: - Initial State Tests

    func testInitialStateHasNoUndoRedo() {
        XCTAssertFalse(undoManager.canUndo, "Should not be able to undo initially")
        XCTAssertFalse(undoManager.canRedo, "Should not be able to redo initially")
    }

    func testInitialStateHasNoPlaylistId() {
        XCTAssertNil(undoManager.currentPlaylistId, "Should have no playlist ID initially")
    }

    func testUndoActionNameNilWhenEmpty() {
        XCTAssertNil(undoManager.undoActionName, "Undo action name should be nil when empty")
    }

    func testRedoActionNameNilWhenEmpty() {
        XCTAssertNil(undoManager.redoActionName, "Redo action name should be nil when empty")
    }

    // MARK: - Playlist Context Tests

    func testSetPlaylistUpdatesCurrentId() {
        undoManager.setPlaylist("playlist123")
        XCTAssertEqual(undoManager.currentPlaylistId, "playlist123")
    }

    func testSetPlaylistClearsUndoWhenChanging() {
        // Set initial playlist and register an action
        undoManager.setPlaylist("playlist1")

        var restoreCalled = false
        undoManager.registerShuffle(
            playlistId: "playlist1",
            originalTracks: [],
            restoreAction: { _, _ in restoreCalled = true; return true }
        )

        XCTAssertTrue(undoManager.canUndo, "Should be able to undo after registering action")

        // Change to different playlist - should clear undo stack
        undoManager.setPlaylist("playlist2")

        XCTAssertFalse(undoManager.canUndo, "Undo stack should be cleared when playlist changes")
        XCTAssertEqual(undoManager.currentPlaylistId, "playlist2")
    }

    func testSetSamePlaylistDoesNotClearUndo() {
        undoManager.setPlaylist("playlist1")

        undoManager.registerShuffle(
            playlistId: "playlist1",
            originalTracks: [],
            restoreAction: { _, _ in return true }
        )

        // Set same playlist again
        undoManager.setPlaylist("playlist1")

        XCTAssertTrue(undoManager.canUndo, "Undo should remain when setting same playlist")
    }

    // MARK: - Clear Tests

    func testClearRemovesAllActions() {
        undoManager.setPlaylist("playlist1")

        undoManager.registerShuffle(
            playlistId: "playlist1",
            originalTracks: [],
            restoreAction: { _, _ in return true }
        )

        XCTAssertTrue(undoManager.canUndo)

        undoManager.clear()

        XCTAssertFalse(undoManager.canUndo, "Undo should be unavailable after clear")
        XCTAssertFalse(undoManager.canRedo, "Redo should be unavailable after clear")
    }

    // MARK: - Shuffle Undo Tests

    func testRegisterShuffleSetsActionName() {
        undoManager.setPlaylist("playlist1")

        undoManager.registerShuffle(
            playlistId: "playlist1",
            originalTracks: [],
            restoreAction: { _, _ in return true }
        )

        XCTAssertEqual(undoManager.undoActionName, "Shuffle Playlist")
    }

    func testRegisterShuffleIgnoredForWrongPlaylist() {
        undoManager.setPlaylist("playlist1")

        undoManager.registerShuffle(
            playlistId: "playlist2", // Wrong playlist
            originalTracks: [],
            restoreAction: { _, _ in return true }
        )

        XCTAssertFalse(undoManager.canUndo, "Should not register undo for wrong playlist")
    }

    // MARK: - Undo/Redo Prevention During Operation

    func testUndoPreventedDuringOperation() async {
        undoManager.setPlaylist("playlist1")

        // Register action that takes time
        undoManager.registerShuffle(
            playlistId: "playlist1",
            originalTracks: [],
            restoreAction: { _, _ in
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                return true
            }
        )

        // Start undo
        undoManager.undo()

        // isUndoRedoInProgress should be true
        XCTAssertTrue(undoManager.isUndoRedoInProgress,
                     "isUndoRedoInProgress should be true during operation")

        // Wait for operation to complete
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(undoManager.isUndoRedoInProgress,
                      "isUndoRedoInProgress should be false after operation")
    }

    // MARK: - Like/Unlike Undo Tests

    func testRegisterLikeSetsCorrectActionName() {
        let track = createMockTrack(name: "Test Song")

        undoManager.registerLike(
            track: track,
            unlikeAction: { _ in return true }
        )

        XCTAssertEqual(undoManager.undoActionName, "Like \"Test Song\"")
    }

    func testRegisterUnlikeSetsCorrectActionName() {
        let track = createMockTrack(name: "Test Song")

        undoManager.registerUnlike(
            track: track,
            likeAction: { _ in return true }
        )

        XCTAssertEqual(undoManager.undoActionName, "Remove from Liked Songs")
    }

    // MARK: - Helper Methods

    private func createMockTrack(name: String) -> SpotifyManager.Track {
        SpotifyManager.Track(
            id: "test-track-\(UUID().uuidString)",
            trackId: "track123",
            name: name,
            artist: "Test Artist",
            album: "Test Album",
            releaseDate: "2024",
            duration: "3:30",
            uri: "spotify:track:track123",
            albumArtURL: nil,
            isLiked: false
        )
    }
}
