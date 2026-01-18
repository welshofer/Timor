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
