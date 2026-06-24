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
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import os.log
import CryptoKit

// MARK: - Logging
private let spotifyAPILogger = Logger(subsystem: "com.timor", category: "spotify-api")

// MARK: - Cached Formatters (PERF-1 / REL-4)

/// Shared, pre-configured DateFormatters. `DateFormatter` is thread-safe for parsing/
/// formatting once configured (and never mutated), so reusing these avoids allocating a
/// fresh, expensive formatter per track (PERF-1). HTTP-date parsing uses a fixed POSIX
/// locale + GMT so it works regardless of device locale (REL-4).
private enum SpotifyDateFormatters {
    nonisolated(unsafe) static let isoFullDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    nonisolated(unsafe) static let isoYearMonth: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()
    nonisolated(unsafe) static let displayFullDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()
    nonisolated(unsafe) static let displayYearMonth: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter
    }()
    nonisolated(unsafe) static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}

// MARK: - Spotify Errors

/// User-facing errors for Spotify API operations
///
/// These errors provide:
/// - Clear, actionable messages for users
/// - Technical details in the description for debugging
/// - Recovery suggestions where appropriate
enum SpotifyError: Error, LocalizedError {
    // Authentication errors
    case notAuthenticated
    case authenticationFailed(reason: String)
    case tokenRefreshFailed
    case invalidCredentials

    // Network errors
    case networkUnavailable
    case connectionFailed(underlying: Error?)
    case requestTimeout
    case serverError(statusCode: Int)

    // Rate limiting
    case rateLimited(retryAfter: TimeInterval)

    // API errors
    case invalidResponse
    case playlistNotFound
    case trackNotFound
    case permissionDenied(operation: String)
    case quotaExceeded

    // Data errors
    case decodingFailed(context: String)
    case invalidData(reason: String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not connected to Spotify"
        case .authenticationFailed(let reason):
            return "Authentication failed: \(reason)"
        case .tokenRefreshFailed:
            return "Session expired"
        case .invalidCredentials:
            return "Invalid Spotify credentials"

        case .networkUnavailable:
            return "No internet connection"
        case .connectionFailed:
            return "Couldn't connect to Spotify"
        case .requestTimeout:
            return "Request timed out"
        case .serverError(let statusCode):
            return "Spotify server error (\(statusCode))"

        case .rateLimited(let retryAfter):
            return "Too many requests. Try again in \(Int(retryAfter)) seconds."

        case .invalidResponse:
            return "Invalid response from Spotify"
        case .playlistNotFound:
            return "Playlist not found"
        case .trackNotFound:
            return "Track not found"
        case .permissionDenied(let operation):
            return "Permission denied for \(operation)"
        case .quotaExceeded:
            return "Spotify API quota exceeded"

        case .decodingFailed(let context):
            return "Couldn't read data: \(context)"
        case .invalidData(let reason):
            return "Invalid data: \(reason)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notAuthenticated:
            return "Open Settings and connect your Spotify account."
        case .authenticationFailed:
            return "Check your credentials in Settings and try again."
        case .tokenRefreshFailed:
            return "Please reconnect your Spotify account in Settings."
        case .invalidCredentials:
            return "Verify your Client ID and Secret in Settings."

        case .networkUnavailable:
            return "Check your internet connection and try again."
        case .connectionFailed:
            return "Check your connection. Spotify might be temporarily unavailable."
        case .requestTimeout:
            return "The operation took too long. Try again."
        case .serverError:
            return "Spotify is having issues. Try again later."

        case .rateLimited:
            return "You're making requests too quickly. The app will automatically retry."

        case .playlistNotFound:
            return "This playlist may have been deleted or made private."
        case .trackNotFound:
            return "This track may no longer be available on Spotify."
        case .permissionDenied:
            return "You may not have permission to modify this playlist."
        case .quotaExceeded:
            return "Please wait a few minutes before trying again."

        default:
            return nil
        }
    }

    /// Create SpotifyError from HTTP status code
    static func fromStatusCode(_ code: Int, data: Data? = nil) -> SpotifyError? {
        switch code {
        case 200...299:
            return nil
        case 401:
            return .tokenRefreshFailed
        case 403:
            return .permissionDenied(operation: "this action")
        case 404:
            return .playlistNotFound
        case 429:
            return .rateLimited(retryAfter: 5)
        case 500...599:
            return .serverError(statusCode: code)
        default:
            return .invalidResponse
        }
    }
}

// MARK: - Rate Limiter

/// Manages API rate limiting with exponential backoff and retry logic.
///
/// ## Why an Actor?
///
/// Rate limiting requires thread-safe mutable state (`retryAfter`, `consecutiveFailures`).
/// When multiple concurrent API requests hit a 429 error simultaneously, they all need
/// to update the same rate limit state without race conditions.
///
/// Swift's `actor` type guarantees:
/// - All property access is serialized (only one caller at a time)
/// - No data races, even with concurrent callers
/// - Async methods automatically suspend callers until access is granted
///
/// ## Rate Limiting Strategy
///
/// ```
/// ┌─────────────────────────────────────────────────────────────────────────┐
/// │                         Request Flow                                    │
/// ├─────────────────────────────────────────────────────────────────────────┤
/// │                                                                         │
/// │  Request → waitIfNeeded() ──┬── Rate limited? ─── Yes ──→ Sleep        │
/// │                             │                             (retryAfter)  │
/// │                             │                                           │
/// │                             └── Apply min interval (100ms throttle)     │
/// │                                                                         │
/// │  Response ←── 429? ─── Yes ──→ handleRateLimit()                       │
/// │                               - Parse Retry-After header               │
/// │                               - Apply exponential backoff: 2^failures  │
/// │                               - Set retryAfter date                    │
/// │                                                                         │
/// │  Success ──→ recordSuccess() ──→ Reset consecutiveFailures             │
/// │                                                                         │
/// └─────────────────────────────────────────────────────────────────────────┘
/// ```
///
/// ## Backoff Formula
///
/// `totalWait = retryAfterHeader × 2^(min(failures-1, 4))`
///
/// | Failures | Multiplier | If header says 1s |
/// |----------|------------|-------------------|
/// | 1        | 1×         | 1 second          |
/// | 2        | 2×         | 2 seconds         |
/// | 3        | 4×         | 4 seconds         |
/// | 4        | 8×         | 8 seconds         |
/// | 5+       | 16× (cap)  | 16 seconds        |
///
actor RateLimiter {
    /// When the rate limit expires (nil if not rate limited)
    private var retryAfter: Date?

    /// Consecutive 429 failures (for exponential backoff calculation)
    private var consecutiveFailures: Int = 0

    /// Last request timestamp (for minimum interval enforcement)
    private var lastRequestTime: Date?

    /// Minimum time between requests (100ms = ~10 requests/second max)
    private let minRequestInterval: TimeInterval = 0.1

    /// Maximum retry attempts before giving up
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
                spotifyAPILogger.info("Rate limited, waiting \(waitTime, format: .fixed(precision: 1))s")
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
                // Try parsing as HTTP date (REL-4: locale-stable shared formatter)
                if let date = SpotifyDateFormatters.httpDate.date(from: header) {
                    waitSeconds = max(1, date.timeIntervalSince(Date()))
                }
            }
        }

        // Apply exponential backoff for consecutive failures
        let backoffMultiplier = pow(2.0, Double(min(consecutiveFailures - 1, 4)))
        let totalWait = waitSeconds * backoffMultiplier

        retryAfter = Date().addingTimeInterval(totalWait)
        spotifyAPILogger.warning("Rate limited! Waiting \(totalWait, format: .fixed(precision: 1))s (failure #\(self.consecutiveFailures))")
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
                    spotifyAPILogger.info("Rate limit hit on attempt \(attempt + 1)/\(retries)")
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

/// Implements certificate pinning for Spotify API connections.
///
/// ## Certificate Pinning Overview
///
/// Certificate pinning ensures the app only communicates with servers presenting
/// certificates we explicitly trust, preventing man-in-the-middle attacks even if
/// a rogue CA issues a fraudulent certificate for api.spotify.com.
///
/// ## Pinning Strategy
///
/// We pin to both the leaf certificate AND intermediate CA:
/// - **Leaf pin**: Catches immediate certificate compromise
/// - **Intermediate CA pin**: Survives routine leaf certificate rotation (typically annual)
///
/// ## Hash Extraction Process
///
/// To update these hashes when Spotify rotates certificates:
/// ```bash
/// # Get leaf certificate hash:
/// echo | openssl s_client -servername api.spotify.com -connect api.spotify.com:443 2>/dev/null \
///   | openssl x509 -pubkey -noout | openssl pkey -pubin -outform DER \
///   | openssl dgst -sha256 -hex | awk '{print $NF}'
///
/// # Get full chain hashes:
/// openssl s_client -servername api.spotify.com -connect api.spotify.com:443 -showcerts 2>/dev/null \
///   | # ... extract and hash each certificate
/// ```
///
/// ## Failure Behavior
///
/// If pinning fails:
/// 1. Connection is cancelled with `.cancelAuthenticationChallenge`
/// 2. Error is logged (without exposing hash values to logs)
/// 3. User sees a generic network error
///
/// - Warning: If Spotify rotates their intermediate CA, users will lose connectivity
///   until the app is updated with new hashes. Monitor Spotify's certificate expiration.
private final class PinnedURLSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    /// Logger for certificate pinning events (file-scoped to avoid MainActor issues)
    private static let pinningLogger = Logger(subsystem: "com.timor", category: "certificate-pinning")

    /// Spotify API certificate public key hashes (SHA-256 of SecKeyCopyExternalRepresentation output)
    ///
    /// Last verified: 2026-01-18 (extracted using SecKeyCopyExternalRepresentation + SHA256)
    /// Both api.spotify.com and accounts.spotify.com share the same certificate chain.
    ///
    /// To update these hashes, run the hash extraction script in the project or check
    /// Console.app logs (category: certificate-pinning) during DEBUG builds.
    private static let pinnedPublicKeyHashes: Set<String> = [
        // Leaf certificate (api.spotify.com, accounts.spotify.com)
        // Rotates most frequently - typically annually
        "88b56ec2e245e6042cff85bab64e91872a6d7d7caff3af38582334d44dcba3b7",

        // Intermediate CA certificate - more stable, survives leaf rotation
        "ebf967039a1282fcd6aebe815e06e39f7b7cf05b3fc3768a7c24bc6fcb12a0cb",

        // Root CA certificate - most stable, rarely changes
        "93336939b223ecf6b3a33598be91ad79f8ab826693f8ac50cd827008eca78968",
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
            Self.pinningLogger.error("Certificate validation failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // If we have pinned hashes, verify at least one certificate in the chain matches
        if !Self.pinnedPublicKeyHashes.isEmpty {
            // Use modern API (SecTrustCopyCertificateChain) available in macOS 12+
            guard let certificates = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }

            var foundMatch = false

            // Check all certificates in the chain (leaf + intermediates)
            // This allows pinning to survive leaf certificate rotation
            for certificate in certificates {
                // Extract public key and hash it (SPKI hash)
                if let publicKey = SecCertificateCopyKey(certificate),
                   let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? {
                    let hash = SHA256.hash(data: publicKeyData)
                    let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()

                    if Self.pinnedPublicKeyHashes.contains(hashString) {
                        foundMatch = true
                        break
                    }
                }
            }

            if foundMatch {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                Self.pinningLogger.error("Certificate pinning failed - no matching hash in chain")
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }

        // Fallback: accept valid certificates (pinning disabled)
        // Debug: Log the actual certificate hashes we see at runtime
        #if DEBUG
        if let certificates = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] {
            for (index, certificate) in certificates.enumerated() {
                if let publicKey = SecCertificateCopyKey(certificate),
                   let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? {
                    let hash = SHA256.hash(data: publicKeyData)
                    let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
                    Self.pinningLogger.debug("Certificate[\(index)] hash: \(hashString, privacy: .public)")
                }
            }
        }
        #endif
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
    /// SEC-1: the `state` value sent on the current auth request, used to validate the callback.
    private var pendingAuthState: String?
    private var currentUserId: String?
    @MainActor private var tokenRefreshTimer: Timer?

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
        // Timer invalidation happens on MainActor as part of deallocation
        // The timer will be invalidated when the reference is released
    }

    var clientID: String {
        (try? keychain.retrieve(for: "spotify_client_id")) ?? ""
    }

    /// Retrieves client secret securely - minimizes time in memory
    private func getClientSecretData() -> Data? {
        // SEC-4: read the secret as raw Data so it never becomes a lingering Swift String.
        guard let secretData = try? keychain.retrieveData(for: "spotify_client_secret"),
              !secretData.isEmpty else {
            return nil
        }
        return secretData
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
        let session = self.pinnedSession
        return try await rateLimiter.executeWithRetry { @Sendable in
            try await session.data(for: request)
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
        pendingAuthState = state  // SEC-1: remember it to validate the callback

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

                // SEC-1: reject the callback unless the returned state matches what we sent.
                let expectedState = self.pendingAuthState
                self.pendingAuthState = nil
                let returnedState = self.extractQueryItem("state", from: callbackURL)
                guard let expectedState = expectedState, returnedState == expectedState else {
                    Self.logger.error("OAuth state mismatch — rejecting callback (possible CSRF)")
                    return
                }

                await self.exchangeCodeForTokens(code: code)
            }
        }

        authSession?.presentationContextProvider = self
        authSession?.prefersEphemeralWebBrowserSession = true
        authSession?.start()
    }

    private func extractQueryItem(_ name: String, from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    private func extractCode(from url: URL) -> String? {
        extractQueryItem("code", from: url)
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

        // FUNC-1: page through ALL playlists (a user can have far more than one page).
        var allPlaylists: [SpotifyManager.Playlist] = []
        var offset = 0
        let limit = Constants.Spotify.playlistFetchLimit
        var hasMore = true

        while hasMore {
            guard let url = URL(string: "\(baseURL)/me/playlists?limit=\(limit)&offset=\(offset)") else { break }

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

                allPlaylists.append(contentsOf: playlistResponse.items.map { item in
                    let isOwner = currentUserId != nil && item.owner.id == currentUserId
                    return SpotifyManager.Playlist(
                        id: item.id,
                        name: item.name,
                        totalTracks: item.tracks.total,
                        owner: item.owner.display_name ?? item.owner.id,
                        description: item.description,
                        isEditable: isOwner || item.collaborative
                    )
                })

                hasMore = playlistResponse.next != nil
                offset += limit
            } catch {
                spotifyAPILogger.error("Error fetching playlists: \(error)")
                hasMore = false
            }
        }

        return allPlaylists
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

        spotifyAPILogger.debug("Total tracks fetched: \(allTracks.count)")
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
            // Full date - format as MMM d, yyyy (PERF-1: reuse shared formatters)
            if let date = SpotifyDateFormatters.isoFullDate.date(from: dateString) {
                return SpotifyDateFormatters.displayFullDate.string(from: date)
            }
        } else if components.count == 2 {
            // Year and month - format as MMM yyyy
            if let date = SpotifyDateFormatters.isoYearMonth.date(from: dateString) {
                return SpotifyDateFormatters.displayYearMonth.string(from: date)
            }
        } else if components.count == 1 {
            // Year only
            return dateString
        }

        return dateString
    }

    /// FUNC-3: builds a Spotify search query string. Single-word field values are left
    /// unquoted so they match partially; multi-word values are quoted to preserve phrase
    /// matching. Extracted as a pure function so it can be unit-tested.
    static func buildSearchQuery(title: String, artist: String, album: String, year: String) -> String {
        func term(_ field: String, _ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed.contains(" ") ? "\(field):\"\(trimmed)\"" : "\(field):\(trimmed)"
        }
        var parts: [String] = []
        if let titleTerm = term("track", title) { parts.append(titleTerm) }
        if let artistTerm = term("artist", artist) { parts.append(artistTerm) }
        if let albumTerm = term("album", album) { parts.append(albumTerm) }
        let trimmedYear = year.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedYear.isEmpty { parts.append("year:\(trimmedYear)") }
        return parts.joined(separator: " ")
    }

    func searchTracks(title: String = "", artist: String = "", album: String = "", year: String = "", limit: Int = 50) async -> [SpotifyManager.Track] {
        guard let accessToken = accessToken else { return [] }

        // FUNC-3: relaxed query — single-word terms unquoted (partial match), phrases quoted.
        let query = Self.buildSearchQuery(title: title, artist: artist, album: album, year: year)

        // If no search terms, return empty
        if query.isEmpty {
            return []
        }

        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return [] }
        guard let url = URL(string: "\(baseURL)/search?q=\(encodedQuery)&type=track&limit=\(limit)") else { return [] }

        spotifyAPILogger.debug("Search query: \(query)")
        spotifyAPILogger.debug("Search URL: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await rateLimitedRequest(for: request)

            // Log the raw response (SEC-5: DEBUG-only and marked private)
            #if DEBUG
            if let responseString = String(data: data, encoding: .utf8) {
                let snippet = String(responseString.prefix(500))
                spotifyAPILogger.debug("Search response (first 500 chars): \(snippet, privacy: .private)")
            }
            #endif

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
            spotifyAPILogger.error("Error searching tracks: \(error)")
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
                    spotifyAPILogger.debug("Fetching liked songs - offset: \(offset), limit: \(limit)")
                    // Parse the response
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let items = json["items"] as? [[String: Any]],
                       let total = json["total"] as? Int {

                        spotifyAPILogger.debug("Found \(items.count) liked songs, total: \(total)")

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
            spotifyAPILogger.error("Error fetching liked songs: \(error)")
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
            spotifyAPILogger.error("Error checking saved tracks: \(error)")
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
                    spotifyAPILogger.info("Successfully saved tracks (status \(httpResponse.statusCode)): \(trackIds)")
                    return true
                } else {
                    spotifyAPILogger.error("Failed to save tracks: HTTP \(httpResponse.statusCode) for IDs: \(trackIds)")
                    if let errorString = String(data: data, encoding: .utf8) {
                        spotifyAPILogger.error("Error response: \(errorString)")
                    }
                    return false
                }
            }
        } catch {
            spotifyAPILogger.error("Error saving tracks: \(error)")
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
                    spotifyAPILogger.info("Successfully removed saved tracks (status \(httpResponse.statusCode))")
                    return true
                } else {
                    spotifyAPILogger.error("Failed to remove saved tracks: HTTP \(httpResponse.statusCode)")
                    return false
                }
            }
        } catch {
            spotifyAPILogger.error("Error removing saved tracks: \(error)")
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
                    spotifyAPILogger.info("Successfully unfollowed/deleted playlist")
                    return true
                } else {
                    spotifyAPILogger.error("Failed to delete playlist: HTTP \(httpResponse.statusCode)")
                    return false
                }
            }
        } catch {
            spotifyAPILogger.error("Error deleting playlist: \(error)")
            return false
        }

        return false
    }

    /// FUNC-5: Updates a playlist's name and/or description (and optionally visibility)
    /// via `PUT /playlists/{id}`. Spotify returns 200 on success.
    func updatePlaylistDetails(
        playlistId: String,
        name: String? = nil,
        description: String? = nil,
        isPublic: Bool? = nil
    ) async -> Bool {
        guard let accessToken = accessToken else { return false }
        guard let url = URL(string: "\(baseURL)/playlists/\(playlistId)") else { return false }

        var body: [String: Any] = [:]
        if let name = name { body["name"] = name }
        if let description = description { body["description"] = description }
        if let isPublic = isPublic { body["public"] = isPublic }
        guard !body.isEmpty else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await rateLimitedRequest(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 {
                    if await refreshAccessToken() {
                        return await updatePlaylistDetails(
                            playlistId: playlistId, name: name,
                            description: description, isPublic: isPublic
                        )
                    } else {
                        logout()
                        return false
                    }
                } else if httpResponse.statusCode == 200 {
                    spotifyAPILogger.info("Successfully updated playlist details")
                    return true
                } else {
                    spotifyAPILogger.error("Failed to update playlist details: HTTP \(httpResponse.statusCode)")
                    return false
                }
            }
        } catch {
            spotifyAPILogger.error("Error updating playlist details: \(error)")
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
                        spotifyAPILogger.info("Successfully created playlist: \(name) with ID: \(playlistId)")
                        return playlistId
                    }
                } else {
                    spotifyAPILogger.error("Failed to create playlist: HTTP \(httpResponse.statusCode)")
                    if let errorString = String(data: data, encoding: .utf8) {
                        spotifyAPILogger.error("Error response: \(errorString)")
                    }
                    return nil
                }
            }
        } catch {
            spotifyAPILogger.error("Error creating playlist: \(error)")
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
                    spotifyAPILogger.error("Failed to add tracks: HTTP \(httpResponse.statusCode)")
                    return false
                }
            }
        } catch {
            spotifyAPILogger.error("Error adding tracks to playlist: \(error)")
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
                    spotifyAPILogger.info("Successfully deleted tracks from playlist")
                    return true
                } else {
                    spotifyAPILogger.error("Failed to delete tracks: HTTP \(httpResponse.statusCode)")
                    return false
                }
            }
        } catch {
            spotifyAPILogger.error("Error deleting tracks from playlist: \(error)")
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
                    spotifyAPILogger.error("Failed to reorder tracks: HTTP \(httpResponse.statusCode)")
                    return false
                }
            }
        } catch {
            spotifyAPILogger.error("Error reordering playlist tracks: \(error)")
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
                        spotifyAPILogger.error("Failed to update playlist: HTTP \(httpResponse.statusCode)")
                        return false
                    }
                }
            } catch {
                spotifyAPILogger.error("Error updating playlist: \(error)")
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
        #if os(macOS)
        return NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
        #else
        // On iOS, find the key window from the connected scenes
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first as? UIWindowScene
        return windowScene?.windows.first ?? ASPresentationAnchor()
        #endif
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
    let next: String?
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