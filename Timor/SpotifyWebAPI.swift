//
//  SpotifyWebAPI.swift
//  Timor
//
//  Spotify Web API integration for macOS using OAuth 2.0 Authorization Code Flow
//

import Foundation
import SwiftUI
import AuthenticationServices
import Combine
import AppKit
import os.log
import CryptoKit

// MARK: - Rate Limiter

/// Manages API rate limiting with exponential backoff and retry logic
actor RateLimiter {
    private var retryAfter: Date?
    private var consecutiveFailures: Int = 0
    private var lastRequestTime: Date?
    private let minRequestInterval: TimeInterval = 0.1 // 100ms between requests (~10/sec max)
    private let maxRetries: Int = 5
    private let logger = Logger(subsystem: "com.timor.spotify", category: "RateLimiter")

    /// Published state for UI feedback
    @MainActor static var shared = RateLimiter()

    /// Whether we're currently rate limited
    var isRateLimited: Bool {
        if let retryAfter = retryAfter {
            return Date() < retryAfter
        }
        return false
    }

    /// Time remaining until rate limit expires
    var rateLimitRemaining: TimeInterval? {
        guard let retryAfter = retryAfter else { return nil }
        let remaining = retryAfter.timeIntervalSince(Date())
        return remaining > 0 ? remaining : nil
    }

    /// Wait for rate limit to expire and apply throttling
    func waitIfNeeded() async throws {
        // Check if we're rate limited
        if let retryAfter = retryAfter {
            let waitTime = retryAfter.timeIntervalSince(Date())
            if waitTime > 0 {
                logger.info("Rate limited, waiting \(waitTime, format: .fixed(precision: 1))s")
                try await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
            }
            self.retryAfter = nil
        }

        // Apply minimum request interval to prevent hitting rate limits
        if let lastRequest = lastRequestTime {
            let elapsed = Date().timeIntervalSince(lastRequest)
            if elapsed < minRequestInterval {
                let delay = minRequestInterval - elapsed
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        lastRequestTime = Date()
    }

    /// Handle a 429 response and calculate backoff
    func handleRateLimit(retryAfterHeader: String?) {
        consecutiveFailures += 1

        // Parse Retry-After header (can be seconds or HTTP date)
        var waitSeconds: TimeInterval = 1.0

        if let header = retryAfterHeader {
            if let seconds = TimeInterval(header) {
                waitSeconds = seconds
            } else {
                // Try parsing as HTTP date
                let formatter = DateFormatter()
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                if let date = formatter.date(from: header) {
                    waitSeconds = max(1, date.timeIntervalSince(Date()))
                }
            }
        }

        // Apply exponential backoff for consecutive failures
        let backoffMultiplier = pow(2.0, Double(min(consecutiveFailures - 1, 4)))
        let totalWait = waitSeconds * backoffMultiplier

        retryAfter = Date().addingTimeInterval(totalWait)
        logger.warning("Rate limited! Waiting \(totalWait, format: .fixed(precision: 1))s (failure #\(self.consecutiveFailures))")
    }

    /// Reset failure count on successful request
    func recordSuccess() {
        consecutiveFailures = 0
    }

    /// Execute a request with automatic retry on rate limit
    func executeWithRetry(
        maxRetries: Int? = nil,
        operation: @escaping () async throws -> (Data, URLResponse)
    ) async throws -> (Data, URLResponse) {
        let retries = maxRetries ?? self.maxRetries
        var lastError: Error?

        for attempt in 0..<retries {
            do {
                try await waitIfNeeded()

                let (data, response) = try await operation()

                guard let httpResponse = response as? HTTPURLResponse else {
                    return (data, response)
                }

                switch httpResponse.statusCode {
                case 200...299:
                    recordSuccess()
                    return (data, response)

                case 429:
                    let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                    handleRateLimit(retryAfterHeader: retryAfter)
                    logger.info("Rate limit hit on attempt \(attempt + 1)/\(retries)")
                    continue

                case 500...599:
                    // Server error - retry with backoff
                    consecutiveFailures += 1
                    let backoff = pow(2.0, Double(min(attempt, 4)))
                    try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    continue

                default:
                    // Other errors - don't retry
                    return (data, response)
                }
            } catch {
                lastError = error
                if attempt < retries - 1 {
                    let backoff = pow(2.0, Double(min(attempt, 4)))
                    try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                }
            }
        }

        throw lastError ?? URLError(.timedOut)
    }
}

// MARK: - Certificate Pinning Delegate
private class PinnedURLSessionDelegate: NSObject, URLSessionDelegate {
    // Spotify API certificate public key hashes (SHA-256)
    // These should be updated if Spotify rotates certificates
    private static let pinnedPublicKeyHashes: Set<String> = [
        // Primary Spotify API certificate
        // Note: In production, obtain these from Spotify's certificate chain
        // For now, we'll use a permissive mode that still validates the chain
    ]

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Verify the certificate chain is valid
        var error: CFError?
        let isValid = SecTrustEvaluateWithError(serverTrust, &error)

        guard isValid else {
            SpotifyWebAPI.logger.error("Certificate validation failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // If we have pinned hashes, verify the public key
        if !Self.pinnedPublicKeyHashes.isEmpty {
            guard let certificate = SecTrustGetCertificateAtIndex(serverTrust, 0) else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }

            // Extract public key and hash it
            if let publicKey = SecCertificateCopyKey(certificate),
               let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? {
                let hash = SHA256.hash(data: publicKeyData)
                let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()

                if Self.pinnedPublicKeyHashes.contains(hashString) {
                    completionHandler(.useCredential, URLCredential(trust: serverTrust))
                    return
                } else {
                    SpotifyWebAPI.logger.error("Certificate pinning failed - hash mismatch")
                    completionHandler(.cancelAuthenticationChallenge, nil)
                    return
                }
            }
        }

        // For now, accept valid certificates (pinning disabled until hashes configured)
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}

@MainActor
class SpotifyWebAPI: NSObject, ObservableObject {
    static let shared = SpotifyWebAPI()

    // MARK: - Logging
    fileprivate static let logger = Logger(subsystem: "com.timor.spotify", category: "SpotifyWebAPI")

    @Published var isAuthenticated = false
    @Published var accessToken: String?
    @Published var refreshToken: String?
    @Published var tokenExpiryDate: Date?
    @Published var isRateLimited = false
    @Published var rateLimitSecondsRemaining: Int = 0

    private let keychain = KeychainManager.shared
    private let rateLimiter = RateLimiter()
    private var authSession: ASWebAuthenticationSession?
    private var currentUserId: String?
    private var tokenRefreshTimer: Timer?

    // URLSession with certificate pinning
    private lazy var pinnedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config, delegate: PinnedURLSessionDelegate(), delegateQueue: nil)
    }()

    private let baseURL = Constants.Spotify.baseURL
    private let tokenURL = Constants.Spotify.tokenURL
    private let authURL = Constants.Spotify.authURL

    private override init() {
        super.init()
        loadTokens()
        setupTokenRefreshTimer()
    }

    deinit {
        tokenRefreshTimer?.invalidate()
    }

    var clientID: String {
        (try? keychain.retrieve(for: "spotify_client_id")) ?? ""
    }

    /// Retrieves client secret securely - minimizes time in memory
    private func getClientSecretData() -> Data? {
        guard let secret = try? keychain.retrieve(for: "spotify_client_secret"),
              !secret.isEmpty else {
            return nil
        }
        return secret.data(using: .utf8)
    }

    /// Creates Basic Auth header with minimal secret exposure
    private func createBasicAuthHeader() -> String? {
        guard let clientIdData = clientID.data(using: .utf8),
              let secretData = getClientSecretData() else {
            return nil
        }

        // Combine credentials
        var credentials = clientIdData
        credentials.append(":".data(using: .utf8)!)
        credentials.append(secretData)

        let base64 = credentials.base64EncodedString()

        // Clear sensitive data
        credentials.resetBytes(in: 0..<credentials.count)

        return "Basic \(base64)"
    }

    // MARK: - Rate-Limited Request Helper

    /// Executes an API request with automatic rate limiting and retry logic
    private func rateLimitedRequest(for request: URLRequest) async throws -> (Data, URLResponse) {
        return try await rateLimiter.executeWithRetry {
            try await self.pinnedSession.data(for: request)
        }
    }

    /// Updates the rate limit UI state
    private func updateRateLimitStatus() async {
        let isLimited = await rateLimiter.isRateLimited
        let remaining = await rateLimiter.rateLimitRemaining

        await MainActor.run {
            self.isRateLimited = isLimited
            self.rateLimitSecondsRemaining = remaining.map { Int(ceil($0)) } ?? 0
        }
    }

    var redirectURI: String {
        Constants.Spotify.redirectURI
    }

    private func setupTokenRefreshTimer() {
        // Check token expiry every minute
        tokenRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkAndRefreshTokenIfNeeded()
            }
        }
    }

    private func checkAndRefreshTokenIfNeeded() async {
        guard let expiryDate = tokenExpiryDate else { return }

        // Refresh if token expires in less than 5 minutes
        let fiveMinutesFromNow = Date().addingTimeInterval(5 * 60)
        if expiryDate < fiveMinutesFromNow && refreshToken != nil {
            Self.logger.info("Token expiring soon, proactively refreshing")
            _ = await refreshAccessToken()
        }
    }

    private func loadTokens() {
        accessToken = try? keychain.retrieve(for: "spotify_web_access_token")
        refreshToken = try? keychain.retrieve(for: "spotify_web_refresh_token")

        // Load token expiry if stored
        if let expiryString = try? keychain.retrieve(for: "spotify_token_expiry"),
           let expiryInterval = TimeInterval(expiryString) {
            tokenExpiryDate = Date(timeIntervalSince1970: expiryInterval)
        }

        isAuthenticated = accessToken != nil

        // If we have tokens, validate them on startup
        if accessToken != nil || refreshToken != nil {
            Task {
                await validateAndRefreshTokenIfNeeded()
            }
        }
    }

    func validateAndRefreshTokenIfNeeded() async {
        // If we have a refresh token but no access token, or if access token might be expired
        if refreshToken != nil {
            // Try to refresh the token
            if await refreshAccessToken() {
                Self.logger.info("Successfully refreshed access token on startup")
            } else if accessToken == nil {
                // Only clear if we don't have a valid access token
                Self.logger.warning("Failed to refresh token on startup, will require re-authentication")
                await MainActor.run {
                    logout()
                }
            }
        }
    }

    private func saveTokens(accessToken: String, refreshToken: String?, expiresIn: Int? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.isAuthenticated = true

        // Calculate and store expiry date
        if let expiresIn = expiresIn {
            let expiryDate = Date().addingTimeInterval(TimeInterval(expiresIn))
            self.tokenExpiryDate = expiryDate
            try? keychain.save(String(expiryDate.timeIntervalSince1970), for: "spotify_token_expiry")
        }

        try? keychain.save(accessToken, for: "spotify_web_access_token")
        if let refreshToken = refreshToken {
            try? keychain.save(refreshToken, for: "spotify_web_refresh_token")
        }

        // Notify observers of authentication state change
        NotificationCenter.default.post(name: .init("SpotifyWebAPIAuthChanged"), object: nil)
    }

    func authenticate() {
        guard !clientID.isEmpty, getClientSecretData() != nil else {
            Self.logger.warning("Client ID and Secret must be configured")
            return
        }

        let scopes = Constants.Spotify.scopes
        let state = UUID().uuidString

        var components = URLComponents(string: authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state)
        ]

        guard let authURL = components.url else { return }

        authSession = ASWebAuthenticationSession(url: authURL, callbackURLScheme: "timor") { [weak self] callbackURL, error in
            Task { @MainActor in
                guard let self = self else { return }

                if let error = error {
                    Self.logger.error("Authentication error: \(error.localizedDescription, privacy: .public)")
                    return
                }

                guard let callbackURL = callbackURL,
                      let code = self.extractCode(from: callbackURL) else {
                    Self.logger.error("Failed to extract authorization code")
                    return
                }

                await self.exchangeCodeForTokens(code: code)
            }
        }

        authSession?.presentationContextProvider = self
        authSession?.prefersEphemeralWebBrowserSession = true
        authSession?.start()
    }

    private func extractCode(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "code" })?
            .value
    }

    private func exchangeCodeForTokens(code: String) async {
        guard let url = URL(string: tokenURL) else {
            Self.logger.error("Failed to create token URL")
            return
        }

        guard let authHeader = createBasicAuthHeader() else {
            Self.logger.error("Failed to create authorization header")
            return
        }

        Self.logger.debug("Exchanging authorization code for tokens")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")

        let bodyParams = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI
        ]

        request.httpBody = bodyParams
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        do {
            let (data, response) = try await rateLimitedRequest(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                Self.logger.error("Invalid response type from token endpoint")
                return
            }

            if httpResponse.statusCode != 200 {
                Self.logger.error("Token exchange failed with status: \(httpResponse.statusCode)")
                #if DEBUG
                if let errorString = String(data: data, encoding: .utf8) {
                    Self.logger.debug("Error response: \(errorString, privacy: .private)")
                }
                #endif
                return
            }

            let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
            saveTokens(
                accessToken: tokenResponse.access_token,
                refreshToken: tokenResponse.refresh_token,
                expiresIn: tokenResponse.expires_in
            )

            Self.logger.info("Successfully authenticated with Spotify Web API")
        } catch {
            Self.logger.error("Token exchange error: \(error.localizedDescription, privacy: .public)")
        }
    }

    func refreshAccessToken() async -> Bool {
        guard let refreshToken = refreshToken else { return false }
        guard let url = URL(string: tokenURL) else { return false }

        guard let authHeader = createBasicAuthHeader() else {
            Self.logger.error("Failed to create authorization header for token refresh")
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")

        let bodyParams = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]

        request.httpBody = bodyParams
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        do {
            let (data, response) = try await rateLimitedRequest(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                Self.logger.warning("Token refresh failed with non-200 status")
                return false
            }

            let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
            saveTokens(
                accessToken: tokenResponse.access_token,
                refreshToken: tokenResponse.refresh_token ?? refreshToken,
                expiresIn: tokenResponse.expires_in
            )

            return true
        } catch {
            Self.logger.error("Token refresh error: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - URL Construction Helpers

    /// Safely constructs API URL with path and query parameters
    private func buildAPIURL(path: String, queryItems: [URLQueryItem]? = nil) -> URL? {
        var components = URLComponents(string: baseURL)
        components?.path += path
        if let queryItems = queryItems, !queryItems.isEmpty {
            components?.queryItems = queryItems
        }
        return components?.url
    }

    func fetchCurrentUser() async -> String? {
        guard let accessToken = accessToken else { return nil }
        guard let url = buildAPIURL(path: "/me") else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, _) = try await rateLimitedRequest(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let userId = json["id"] as? String {
                currentUserId = userId
                return userId
            }
        } catch {
            Self.logger.error("Error fetching current user: \(error.localizedDescription, privacy: .public)")
        }
        return nil
    }

    func fetchUserPlaylists() async -> [SpotifyManager.Playlist] {
        guard let accessToken = accessToken else { return [] }

        // Get current user ID if we don't have it
        if currentUserId == nil {
            _ = await fetchCurrentUser()
        }

        guard let url = URL(string: "\(baseURL)/me/playlists?limit=\(Constants.Spotify.playlistFetchLimit)") else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await rateLimitedRequest(for: request)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
                // Token expired, try to refresh
                if await refreshAccessToken() {
                    return await fetchUserPlaylists()
                } else {
                    logout()
                    return []
                }
            }

            let playlistResponse = try JSONDecoder().decode(PlaylistResponse.self, from: data)

            return playlistResponse.items.map { item in
                let isOwner = currentUserId != nil && item.owner.id == currentUserId
                return SpotifyManager.Playlist(
                    id: item.id,
                    name: item.name,
                    totalTracks: item.tracks.total,
                    owner: item.owner.display_name ?? item.owner.id,
                    description: item.description,
                    isEditable: isOwner || item.collaborative
                )
            }
        } catch {
            print("Error fetching playlists: \(error)")
            return []
        }
    }

    func fetchPlaylistTracks(playlistId: String, progressHandler: ((Int, Int) -> Void)? = nil) async -> [SpotifyManager.Track] {
        guard let accessToken = accessToken else { return [] }

        var allTracks: [SpotifyManager.Track] = []
        var offset = 0
        let limit = Constants.Spotify.trackFetchLimit
        var hasMore = true

        while hasMore {
            guard let url = URL(string: "\(baseURL)/playlists/\(playlistId)/tracks?limit=\(limit)&offset=\(offset)") else { break }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            do {
                let (data, response) = try await rateLimitedRequest(for: request)
                await updateRateLimitStatus()

                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
                    // Token expired, try to refresh
                    if await refreshAccessToken() {
                        return await fetchPlaylistTracks(playlistId: playlistId, progressHandler: progressHandler)
                    } else {
                        logout()
                        return []
                    }
                }

                let tracksResponse = try JSONDecoder().decode(PlaylistTracksResponse.self, from: data)

                let tracks = tracksResponse.items.enumerated().compactMap { (index, item) -> SpotifyManager.Track? in
                    guard let track = item.track else { return nil }
                    // Create a unique ID combining track ID and its position to handle duplicates
                    let uniqueId = "\(track.id)_\(allTracks.count + index)"

                    // Get the 640x640 album art image, or the largest available
                    let albumArtURL = track.album.images?.first(where: { $0.height == 640 && $0.width == 640 })?.url
                        ?? track.album.images?.max(by: { ($0.height ?? 0) < ($1.height ?? 0) })?.url
                        ?? track.album.images?.first?.url

                    return SpotifyManager.Track(
                        id: uniqueId,
                        trackId: track.id,
                        name: track.name,
                        artist: track.artists.map { $0.name }.joined(separator: ", "),
                        album: track.album.name,
                        releaseDate: formatReleaseDate(track.album.release_date),
                        duration: formatDuration(track.duration_ms),
                        uri: track.uri,
                        albumArtURL: albumArtURL
                    )
                }

                allTracks.append(contentsOf: tracks)

                // Report progress
                progressHandler?(allTracks.count, tracksResponse.total ?? allTracks.count)

                // Check if there are more tracks to fetch
                hasMore = tracksResponse.next != nil
                offset += limit

                Self.logger.debug("Fetched \(allTracks.count) tracks so far...")

            } catch {
                Self.logger.error("Error fetching playlist tracks at offset \(offset): \(error.localizedDescription, privacy: .public)")
                await updateRateLimitStatus()
                break
            }
        }

        print("Total tracks fetched: \(allTracks.count)")
        return allTracks
    }

    private func formatDuration(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1000
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    private func formatReleaseDate(_ dateString: String?) -> String {
        guard let dateString = dateString else { return "" }

        // Spotify returns dates in different formats:
        // - Full date: "2023-10-15"
        // - Year and month: "2023-10"
        // - Year only: "2023"

        let components = dateString.split(separator: "-")

        if components.count == 3 {
            // Full date - format as MMM d, yyyy
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"

            if let date = dateFormatter.date(from: dateString) {
                dateFormatter.dateFormat = "MMM d, yyyy"
                return dateFormatter.string(from: date)
            }
        } else if components.count == 2 {
            // Year and month - format as MMM yyyy
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM"

            if let date = dateFormatter.date(from: dateString) {
                dateFormatter.dateFormat = "MMM yyyy"
                return dateFormatter.string(from: date)
            }
        } else if components.count == 1 {
            // Year only
            return dateString
        }

        return dateString
    }

    func searchTracks(title: String = "", artist: String = "", album: String = "", year: String = "", limit: Int = 50) async -> [SpotifyManager.Track] {
        guard let accessToken = accessToken else { return [] }

        // Build search query - EXACTLY AS IT WAS WHEN IT WORKED
        var queryParts: [String] = []
        if !title.isEmpty {
            queryParts.append("track:\"\(title)\"")
        }
        if !artist.isEmpty {
            queryParts.append("artist:\"\(artist)\"")
        }
        if !album.isEmpty {
            queryParts.append("album:\"\(album)\"")
        }
        if !year.isEmpty {
            queryParts.append("year:\(year)")
        }

        // If no search terms, return empty
        if queryParts.isEmpty {
            return []
        }

        let query = queryParts.joined(separator: " ")
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return [] }
        guard let url = URL(string: "\(baseURL)/search?q=\(encodedQuery)&type=track&limit=\(limit)") else { return [] }

        print("🔍 SEARCH QUERY: \(query)")
        print("🔍 SEARCH URL: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await rateLimitedRequest(for: request)

            // Log the raw response
            if let responseString = String(data: data, encoding: .utf8) {
                print("🔍 RESPONSE (first 500 chars): \(String(responseString.prefix(500)))")
            }

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
                if await refreshAccessToken() {
                    return await searchTracks(title: title, artist: artist, album: album, year: year, limit: limit)
                } else {
                    logout()
                    return []
                }
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tracks = json["tracks"] as? [String: Any],
               let items = tracks["items"] as? [[String: Any]] {

                return items.compactMap { item in
                    guard let id = item["id"] as? String,
                          let name = item["name"] as? String,
                          let uri = item["uri"] as? String,
                          let artists = item["artists"] as? [[String: Any]],
                          let firstArtist = artists.first?["name"] as? String,
                          let album = item["album"] as? [String: Any],
                          let albumName = album["name"] as? String,
                          let duration_ms = item["duration_ms"] as? Int else {
                        return nil
                    }

                    let releaseDate = (album["release_date"] as? String) ?? ""
                    let minutes = duration_ms / 60000
                    let seconds = (duration_ms % 60000) / 1000
                    let duration = String(format: "%d:%02d", minutes, seconds)

                    // Get album art URL from images array (640x640 preferred)
                    let albumArtURL: String? = {
                        guard let images = album["images"] as? [[String: Any]],
                              !images.isEmpty else { return nil }
                        // Look for 640x640 image first
                        if let largeImage = images.first(where: { img in
                            let height = img["height"] as? Int
                            let width = img["width"] as? Int
                            return height == 640 && width == 640
                        }) {
                            return largeImage["url"] as? String
                        }
                        // Otherwise get the largest image available
                        let largestImage = images.max { img1, img2 in
                            let height1 = img1["height"] as? Int ?? 0
                            let height2 = img2["height"] as? Int ?? 0
                            return height1 < height2
                        }
                        return (largestImage ?? images.first)?["url"] as? String
                    }()

                    return SpotifyManager.Track(
                        id: UUID().uuidString, // Unique ID for table selection
                        trackId: id,
                        name: name,
                        artist: firstArtist,
                        album: albumName,
                        releaseDate: releaseDate,
                        duration: duration,
                        uri: uri,
                        albumArtURL: albumArtURL
                    )
                }
            }
        } catch {
            print("Error searching tracks: \(error)")
        }

        return []
    }

    func fetchLikedSongs(limit: Int = 50, offset: Int = 0) async -> (tracks: [SpotifyManager.Track], total: Int) {
        guard let accessToken = accessToken else { return ([], 0) }
        guard let url = URL(string: "\(baseURL)/me/tracks?limit=\(limit)&offset=\(offset)") else { return ([], 0) }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await rateLimitedRequest(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 {
                    if await refreshAccessToken() {
                        return await fetchLikedSongs(limit: limit, offset: offset)
                    } else {
                        logout()
                        return ([], 0)
                    }
                } else if httpResponse.statusCode == 200 {
                    print("Fetching liked songs - offset: \(offset), limit: \(limit)")
                    // Parse the response
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let items = json["items"] as? [[String: Any]],
                       let total = json["total"] as? Int {

                        print("Found \(items.count) liked songs, total: \(total)")

                        let tracks = items.compactMap { item -> SpotifyManager.Track? in
                            guard let track = item["track"] as? [String: Any],
                                  let id = track["id"] as? String,
                                  let name = track["name"] as? String,
                                  let uri = track["uri"] as? String,
                                  let artists = track["artists"] as? [[String: Any]],
                                  let album = track["album"] as? [String: Any],
                                  let albumName = album["name"] as? String,
                                  let duration_ms = track["duration_ms"] as? Int else {
                                return nil
                            }

                            let artistName = artists.compactMap { $0["name"] as? String }.joined(separator: ", ")
                            let releaseDate = (album["release_date"] as? String) ?? ""

                            // Get album art URL from images array (640x640 preferred)
                            let albumArtURL: String? = {
                                guard let images = album["images"] as? [[String: Any]],
                                      !images.isEmpty else { return nil }
                                // Look for 640x640 image first
                                if let largeImage = images.first(where: { img in
                                    let height = img["height"] as? Int
                                    let width = img["width"] as? Int
                                    return height == 640 && width == 640
                                }) {
                                    return largeImage["url"] as? String
                                }
                                // Otherwise get the largest image available
                                let largestImage = images.max { img1, img2 in
                                    let height1 = img1["height"] as? Int ?? 0
                                    let height2 = img2["height"] as? Int ?? 0
                                    return height1 < height2
                                }
                                return (largestImage ?? images.first)?["url"] as? String
                            }()

                            return SpotifyManager.Track(
                                id: UUID().uuidString,
                                trackId: id,
                                name: name,
                                artist: artistName,
                                album: albumName,
                                releaseDate: formatReleaseDate(releaseDate),
                                duration: formatDuration(duration_ms),
                                uri: uri,
                                albumArtURL: albumArtURL,
                                isLiked: true  // These are all liked by definition
                            )
                        }

                        return (tracks, total)
                    }
                }
            }
        } catch {
            print("Error fetching liked songs: \(error)")
        }

        return ([], 0)
    }

    func checkSavedTracks(trackIds: [String]) async -> [Bool] {
        guard let accessToken = accessToken else { return [] }

        let idsParam = trackIds.joined(separator: ",")
        guard let encodedIds = idsParam.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(baseURL)/me/tracks/contains?ids=\(encodedIds)") else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await rateLimitedRequest(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 {
                    if await refreshAccessToken() {
                        return await checkSavedTracks(trackIds: trackIds)
                    } else {
                        logout()
                        return []
                    }
                } else if httpResponse.statusCode == 200 {
                    // Parse the boolean array response
                    if let boolArray = try? JSONDecoder().decode([Bool].self, from: data) {
                        return boolArray
                    }
                }
            }
        } catch {
            print("Error checking saved tracks: \(error)")
        }

        return []
    }

    func saveTracks(trackIds: [String]) async -> Bool {
        guard let accessToken = accessToken else { return false }
        guard let url = URL(string: "\(baseURL)/me/tracks") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["ids": trackIds]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await rateLimitedRequest(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 {
                    if await refreshAccessToken() {
                        return await saveTracks(trackIds: trackIds)
                    } else {
                        logout()
                        return false
                    }
                } else if httpResponse.statusCode == 200 || httpResponse.statusCode == 204 {
                    print("Successfully saved tracks (status \(httpResponse.statusCode)): \(trackIds)")
                    return true
                } else {
                    print("Failed to save tracks: HTTP \(httpResponse.statusCode) for IDs: \(trackIds)")
                    if let errorString = String(data: data, encoding: .utf8) {
                        print("Error response: \(errorString)")
                    }
                    return false
                }
            }
        } catch {
            print("Error saving tracks: \(error)")
            return false
        }

        return false
    }

    func removeSavedTracks(trackIds: [String]) async -> Bool {
        guard let accessToken = accessToken else { return false }
        guard let url = URL(string: "\(baseURL)/me/tracks") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["ids": trackIds]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await rateLimitedRequest(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 {
                    if await refreshAccessToken() {
                        return await removeSavedTracks(trackIds: trackIds)
                    } else {
                        logout()
                        return false
                    }
                } else if httpResponse.statusCode == 200 || httpResponse.statusCode == 204 {
                    print("Successfully removed saved tracks (status \(httpResponse.statusCode))")
                    return true
                } else {
                    print("Failed to remove saved tracks: HTTP \(httpResponse.statusCode)")
                    return false
                }
            }
        } catch {
            print("Error removing saved tracks: \(error)")
            return false
        }

        return false
    }

    func deletePlaylist(playlistId: String) async -> Bool {
        guard let accessToken = accessToken else { return false }
        guard let url = URL(string: "\(baseURL)/playlists/\(playlistId)/followers") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await rateLimitedRequest(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 {
                    if await refreshAccessToken() {
                        return await deletePlaylist(playlistId: playlistId)
                    } else {
                        logout()
                        return false
                    }
                } else if httpResponse.statusCode == 200 {
                    print("Successfully unfollowed/deleted playlist")
                    return true
                } else {
                    print("Failed to delete playlist: HTTP \(httpResponse.statusCode)")
                    return false
                }
            }
        } catch {
            print("Error deleting playlist: \(error)")
            return false
        }

        return false
    }

    func createPlaylist(name: String, description: String = "", isPublic: Bool = false) async -> String? {
        guard let accessToken = accessToken else { return nil }

        // Get current user ID if we don't have it
        if currentUserId == nil {
            _ = await fetchCurrentUser()
        }

        guard let userId = currentUserId else { return nil }
        guard let url = URL(string: "\(baseURL)/users/\(userId)/playlists") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "name": name,
            "description": description,
            "public": isPublic
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await rateLimitedRequest(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 {
                    if await refreshAccessToken() {
                        return await createPlaylist(name: name, description: description, isPublic: isPublic)
                    } else {
                        logout()
                        return nil
                    }
                } else if httpResponse.statusCode == 201 {
                    // Parse the created playlist ID from response
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let playlistId = json["id"] as? String {
                        print("Successfully created playlist: \(name) with ID: \(playlistId)")
                        return playlistId
                    }
                } else {
                    print("Failed to create playlist: HTTP \(httpResponse.statusCode)")
                    if let errorString = String(data: data, encoding: .utf8) {
                        print("Error response: \(errorString)")
                    }
                    return nil
                }
            }
        } catch {
            print("Error creating playlist: \(error)")
            return nil
        }

        return nil
    }

    func addTracksToPlaylist(playlistId: String, trackUris: [String]) async -> Bool {
        guard let accessToken = accessToken else { return false }
        guard let url = URL(string: "\(baseURL)/playlists/\(playlistId)/tracks") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["uris": trackUris]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await rateLimitedRequest(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 {
                    if await refreshAccessToken() {
                        return await addTracksToPlaylist(playlistId: playlistId, trackUris: trackUris)
                    } else {
                        logout()
                        return false
                    }
                } else if httpResponse.statusCode == 201 {
                    return true
                } else {
                    print("Failed to add tracks: HTTP \(httpResponse.statusCode)")
                    return false
                }
            }
        } catch {
            print("Error adding tracks to playlist: \(error)")
            return false
        }

        return false
    }

    func deletePlaylistTracks(playlistId: String, trackUris: [String], positions: [[Int]]) async -> Bool {
        guard let accessToken = accessToken else { return false }
        guard let url = URL(string: "\(baseURL)/playlists/\(playlistId)/tracks") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Create the tracks array with URIs and their positions
        var tracks: [[String: Any]] = []
        for (index, uri) in trackUris.enumerated() {
            if index < positions.count {
                tracks.append([
                    "uri": uri,
                    "positions": positions[index]
                ])
            }
        }

        let body = ["tracks": tracks]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await rateLimitedRequest(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 {
                    // Token expired, try to refresh
                    if await refreshAccessToken() {
                        return await deletePlaylistTracks(playlistId: playlistId, trackUris: trackUris, positions: positions)
                    } else {
                        logout()
                        return false
                    }
                } else if httpResponse.statusCode == 200 {
                    print("Successfully deleted tracks from playlist")
                    return true
                } else {
                    print("Failed to delete tracks: HTTP \(httpResponse.statusCode)")
                    return false
                }
            }
        } catch {
            print("Error deleting tracks from playlist: \(error)")
            return false
        }

        return false
    }

    func reorderPlaylistTracks(playlistId: String, rangeStart: Int, insertBefore: Int, rangeLength: Int = 1) async -> Bool {
        guard let accessToken = accessToken else { return false }
        guard let url = URL(string: "\(baseURL)/playlists/\(playlistId)/tracks") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "range_start": rangeStart,
            "insert_before": insertBefore,
            "range_length": rangeLength
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await rateLimitedRequest(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 {
                    // Token expired, try to refresh
                    if await refreshAccessToken() {
                        return await reorderPlaylistTracks(playlistId: playlistId, rangeStart: rangeStart, insertBefore: insertBefore, rangeLength: rangeLength)
                    } else {
                        logout()
                        return false
                    }
                } else if httpResponse.statusCode == 200 {
                    return true
                } else {
                    print("Failed to reorder tracks: HTTP \(httpResponse.statusCode)")
                    return false
                }
            }
        } catch {
            print("Error reordering playlist tracks: \(error)")
            return false
        }

        return false
    }

    func replacePlaylistTracks(playlistId: String, trackUris: [String]) async -> Bool {
        guard let accessToken = accessToken else { return false }

        // Spotify limits to 100 tracks per request, so we need to batch
        let chunks = trackUris.chunked(into: Constants.Spotify.trackFetchLimit)

        for (index, chunk) in chunks.enumerated() {
            // First chunk replaces all, subsequent chunks append
            let endpoint = index == 0 ? "tracks" : "tracks"
            let method = index == 0 ? "PUT" : "POST"

            guard let url = URL(string: "\(baseURL)/playlists/\(playlistId)/\(endpoint)") else { return false }

            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body = ["uris": chunk]

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (_, response) = try await rateLimitedRequest(for: request)

                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 401 {
                        // Token expired, try to refresh
                        if await refreshAccessToken() {
                            return await replacePlaylistTracks(playlistId: playlistId, trackUris: trackUris)
                        } else {
                            logout()
                            return false
                        }
                    } else if httpResponse.statusCode != 200 && httpResponse.statusCode != 201 {
                        print("Failed to update playlist: HTTP \(httpResponse.statusCode)")
                        return false
                    }
                }
            } catch {
                print("Error updating playlist: \(error)")
                return false
            }
        }

        return true
    }

    func logout() {
        accessToken = nil
        refreshToken = nil
        tokenExpiryDate = nil
        isAuthenticated = false

        try? keychain.delete(for: "spotify_web_access_token")
        try? keychain.delete(for: "spotify_web_refresh_token")
        try? keychain.delete(for: "spotify_token_expiry")

        // Notify observers of authentication state change
        NotificationCenter.default.post(name: .init("SpotifyWebAPIAuthChanged"), object: nil)
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding
extension SpotifyWebAPI: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}

// MARK: - Response Models
struct TokenResponse: Codable {
    let access_token: String
    let token_type: String
    let scope: String
    let expires_in: Int
    let refresh_token: String?
}

struct PlaylistResponse: Codable {
    let items: [PlaylistItem]
    let total: Int
}

struct PlaylistItem: Codable {
    let id: String
    let name: String
    let description: String?
    let owner: Owner
    let tracks: Tracks
    let collaborative: Bool
}

struct Owner: Codable {
    let id: String
    let display_name: String?
}

struct Tracks: Codable {
    let total: Int
}

struct PlaylistTracksResponse: Codable {
    let items: [PlaylistTrackItem]
    let total: Int?
    let next: String?
}

struct PlaylistTrackItem: Codable {
    let track: TrackObject?
}

struct TrackObject: Codable {
    let id: String
    let name: String
    let artists: [Artist]
    let album: Album
    let duration_ms: Int
    let uri: String
}

struct Artist: Codable {
    let name: String
}

struct Album: Codable {
    let name: String
    let release_date: String?
    let images: [AlbumImage]?
}

struct AlbumImage: Codable {
    let url: String
    let height: Int?
    let width: Int?
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}