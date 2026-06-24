//
//  SpotifyErrorTests.swift
//  TimorTests
//
//  Tests for SpotifyError user-facing error messages
//

import XCTest
@testable import Timor

final class SpotifyErrorTests: XCTestCase {

    // MARK: - Error Description Tests

    func testNotAuthenticatedHasDescription() {
        let error = SpotifyError.notAuthenticated
        XCTAssertEqual(error.localizedDescription, "Not connected to Spotify")
    }

    func testAuthenticationFailedIncludesReason() {
        let error = SpotifyError.authenticationFailed(reason: "Invalid code")
        XCTAssertTrue(error.localizedDescription.contains("Invalid code"))
    }

    func testNetworkUnavailableHasDescription() {
        let error = SpotifyError.networkUnavailable
        XCTAssertEqual(error.localizedDescription, "No internet connection")
    }

    func testRateLimitedShowsTime() {
        let error = SpotifyError.rateLimited(retryAfter: 30)
        XCTAssertTrue(error.localizedDescription.contains("30"))
    }

    func testServerErrorShowsStatusCode() {
        let error = SpotifyError.serverError(statusCode: 503)
        XCTAssertTrue(error.localizedDescription.contains("503"))
    }

    func testPermissionDeniedShowsOperation() {
        let error = SpotifyError.permissionDenied(operation: "deleting tracks")
        XCTAssertTrue(error.localizedDescription.contains("deleting tracks"))
    }

    // MARK: - Recovery Suggestion Tests

    func testNotAuthenticatedHasRecoverySuggestion() {
        let error = SpotifyError.notAuthenticated
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion!.contains("Settings"))
    }

    func testNetworkUnavailableHasRecoverySuggestion() {
        let error = SpotifyError.networkUnavailable
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion!.contains("connection"))
    }

    func testRateLimitedHasRecoverySuggestion() {
        let error = SpotifyError.rateLimited(retryAfter: 5)
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion!.contains("retry"))
    }

    func testDecodingFailedHasNoRecoverySuggestion() {
        let error = SpotifyError.decodingFailed(context: "JSON parse error")
        XCTAssertNil(error.recoverySuggestion)
    }

    // MARK: - Status Code Mapping Tests

    func testFromStatusCode200ReturnsNil() {
        XCTAssertNil(SpotifyError.fromStatusCode(200))
    }

    func testFromStatusCode401ReturnsTokenRefreshFailed() {
        if case .tokenRefreshFailed = SpotifyError.fromStatusCode(401) {
            // Pass
        } else {
            XCTFail("Expected tokenRefreshFailed for 401")
        }
    }

    func testFromStatusCode403ReturnsPermissionDenied() {
        if case .permissionDenied = SpotifyError.fromStatusCode(403) {
            // Pass
        } else {
            XCTFail("Expected permissionDenied for 403")
        }
    }

    func testFromStatusCode404ReturnsPlaylistNotFound() {
        if case .playlistNotFound = SpotifyError.fromStatusCode(404) {
            // Pass
        } else {
            XCTFail("Expected playlistNotFound for 404")
        }
    }

    func testFromStatusCode429ReturnsRateLimited() {
        if case .rateLimited = SpotifyError.fromStatusCode(429) {
            // Pass
        } else {
            XCTFail("Expected rateLimited for 429")
        }
    }

    func testFromStatusCode500ReturnsServerError() {
        if case .serverError(let code) = SpotifyError.fromStatusCode(500) {
            XCTAssertEqual(code, 500)
        } else {
            XCTFail("Expected serverError for 500")
        }
    }

    func testFromStatusCode503ReturnsServerError() {
        if case .serverError(let code) = SpotifyError.fromStatusCode(503) {
            XCTAssertEqual(code, 503)
        } else {
            XCTFail("Expected serverError for 503")
        }
    }
}

// MARK: - FUNC-3: Search query building

@MainActor
final class SpotifySearchQueryTests: XCTestCase {

    func testSingleWordTermsAreUnquotedForPartialMatch() {
        let query = SpotifyWebAPI.buildSearchQuery(title: "Yesterday", artist: "Beatles", album: "", year: "")
        XCTAssertEqual(query, "track:Yesterday artist:Beatles")
    }

    func testMultiWordTermsAreQuotedToPreservePhrase() {
        let query = SpotifyWebAPI.buildSearchQuery(title: "Hey Jude", artist: "The Beatles", album: "", year: "")
        XCTAssertEqual(query, "track:\"Hey Jude\" artist:\"The Beatles\"")
    }

    func testYearIsAppendedUnquoted() {
        let query = SpotifyWebAPI.buildSearchQuery(title: "", artist: "", album: "", year: "1969")
        XCTAssertEqual(query, "year:1969")
    }

    func testEmptyInputsProduceEmptyQuery() {
        XCTAssertEqual(SpotifyWebAPI.buildSearchQuery(title: "", artist: "", album: "", year: ""), "")
    }

    func testWhitespaceOnlyTermsAreIgnored() {
        let query = SpotifyWebAPI.buildSearchQuery(title: "   ", artist: "Adele", album: "", year: "")
        XCTAssertEqual(query, "artist:Adele")
    }

    func testAllFieldsCombineInOrder() {
        let query = SpotifyWebAPI.buildSearchQuery(title: "Hello", artist: "Adele", album: "25", year: "2015")
        XCTAssertEqual(query, "track:Hello artist:Adele album:25 year:2015")
    }
}

// MARK: - FUNC-2: Track duration sorting

@MainActor
final class TrackDurationSortTests: XCTestCase {

    private func track(duration: String) -> SpotifyManager.Track {
        SpotifyManager.Track(
            id: "i", trackId: "t", name: "n", artist: "a", album: "al",
            releaseDate: "2024", duration: duration, uri: "u", albumArtURL: nil
        )
    }

    func testDurationSecondsParsesMinutesAndSeconds() {
        XCTAssertEqual(track(duration: "3:45").durationSeconds, 225)
        XCTAssertEqual(track(duration: "0:30").durationSeconds, 30)
        XCTAssertEqual(track(duration: "10:05").durationSeconds, 605)
    }

    func testLongerTrackSortsAfterShorterNumerically() {
        // The bug: as strings, "10:05" < "9:30". durationSeconds must order them correctly.
        XCTAssertLessThan("10:05", "9:30") // documents the broken lexicographic ordering
        XCTAssertGreaterThan(track(duration: "10:05").durationSeconds, track(duration: "9:30").durationSeconds)
    }

    func testMalformedDurationIsZero() {
        XCTAssertEqual(track(duration: "").durationSeconds, 0)
        XCTAssertEqual(track(duration: "bad").durationSeconds, 0)
    }
}

// MARK: - FUNC-1: Raw release dates

@MainActor
final class ReleaseDateTests: XCTestCase {

    private func track(releaseDate: String) -> SpotifyManager.Track {
        SpotifyManager.Track(
            id: "i", trackId: "t", name: "n", artist: "a", album: "al",
            releaseDate: releaseDate, duration: "3:00", uri: "u", albumArtURL: nil
        )
    }

    func testFormatReleaseFullDate() {
        XCTAssertEqual(SpotifyDateFormatters.formatRelease("2023-10-15"), "Oct 15, 2023")
    }

    func testFormatReleaseYearMonth() {
        XCTAssertEqual(SpotifyDateFormatters.formatRelease("2023-10"), "Oct 2023")
    }

    func testFormatReleaseYearOnly() {
        XCTAssertEqual(SpotifyDateFormatters.formatRelease("2023"), "2023")
    }

    func testRawDateEnablesYearExtraction() {
        // The bug: "Oct 15, 2023".prefix(4) == "Oct ". Storing raw yields a real year.
        let track = track(releaseDate: "2023-10-15")
        XCTAssertEqual(Int(track.releaseDate.prefix(4)), 2023)
        XCTAssertEqual(track.displayReleaseDate, "Oct 15, 2023")
    }

    func testRawIsoDatesSortChronologically() {
        // Raw ISO sorts chronologically as text; formatted "MMM…" did not.
        XCTAssertLessThan("1999-12-01", "2020-04-01")
    }
}
