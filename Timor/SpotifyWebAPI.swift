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

@MainActor
class SpotifyWebAPI: NSObject, ObservableObject {
    static let shared = SpotifyWebAPI()

    @Published var isAuthenticated = false
    @Published var accessToken: String?
    @Published var refreshToken: String?

    private let keychain = KeychainManager.shared
    private var authSession: ASWebAuthenticationSession?
    private var currentUserId: String?

    private let baseURL = "https://api.spotify.com/v1"
    private let tokenURL = "https://accounts.spotify.com/api/token"
    private let authURL = "https://accounts.spotify.com/authorize"

    private override init() {
        super.init()
        loadTokens()
    }

    var clientID: String {
        (try? keychain.retrieve(for: "spotify_client_id")) ?? ""
    }

    var clientSecret: String {
        (try? keychain.retrieve(for: "spotify_client_secret")) ?? ""
    }

    var redirectURI: String {
        "timor://spotify-callback"
    }

    private func loadTokens() {
        accessToken = try? keychain.retrieve(for: "spotify_web_access_token")
        refreshToken = try? keychain.retrieve(for: "spotify_web_refresh_token")
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
                print("Successfully refreshed access token on startup")
            } else if accessToken == nil {
                // Only clear if we don't have a valid access token
                print("Failed to refresh token on startup, will require re-authentication")
                await MainActor.run {
                    logout()
                }
            }
        }
    }

    private func saveTokens(accessToken: String, refreshToken: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.isAuthenticated = true

        try? keychain.save(accessToken, for: "spotify_web_access_token")
        if let refreshToken = refreshToken {
            try? keychain.save(refreshToken, for: "spotify_web_refresh_token")
        }

        // Notify observers of authentication state change
        NotificationCenter.default.post(name: .init("SpotifyWebAPIAuthChanged"), object: nil)
    }

    func authenticate() {
        guard !clientID.isEmpty && !clientSecret.isEmpty else {
            print("Client ID and Secret must be configured")
            return
        }

        let scopes = "playlist-read-private playlist-read-collaborative playlist-modify-public playlist-modify-private user-read-private"
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
                    print("Authentication error: \(error)")
                    return
                }

                guard let callbackURL = callbackURL,
                      let code = self.extractCode(from: callbackURL) else {
                    print("Failed to extract authorization code")
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
            print("Failed to create token URL")
            return
        }

        print("Exchanging code for tokens...")
        print("Token URL: \(tokenURL)")
        print("Client ID: \(clientID)")
        print("Has Client Secret: \(!clientSecret.isEmpty)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let credentials = "\(clientID):\(clientSecret)"
        let credentialsData = credentials.data(using: .utf8)!
        let base64Credentials = credentialsData.base64EncodedString()
        request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")

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
            print("Sending token exchange request...")
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                print("Invalid response type")
                return
            }

            if httpResponse.statusCode != 200 {
                print("Token exchange failed with status: \(httpResponse.statusCode)")
                if let errorString = String(data: data, encoding: .utf8) {
                    print("Error response: \(errorString)")
                }
                return
            }

            let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
            saveTokens(accessToken: tokenResponse.access_token, refreshToken: tokenResponse.refresh_token)

            print("Successfully authenticated with Spotify Web API")
        } catch {
            print("Token exchange error: \(error)")
        }
    }

    func refreshAccessToken() async -> Bool {
        guard let refreshToken = refreshToken else { return false }
        guard let url = URL(string: tokenURL) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let credentials = "\(clientID):\(clientSecret)"
        let credentialsData = credentials.data(using: .utf8)!
        let base64Credentials = credentialsData.base64EncodedString()
        request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")

        let bodyParams = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]

        request.httpBody = bodyParams
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return false
            }

            let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
            saveTokens(accessToken: tokenResponse.access_token, refreshToken: tokenResponse.refresh_token ?? refreshToken)

            return true
        } catch {
            print("Token refresh error: \(error)")
            return false
        }
    }

    func fetchCurrentUser() async -> String? {
        guard let accessToken = accessToken else { return nil }
        guard let url = URL(string: "\(baseURL)/me") else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let userId = json["id"] as? String {
                currentUserId = userId
                return userId
            }
        } catch {
            print("Error fetching current user: \(error)")
        }
        return nil
    }

    func fetchUserPlaylists() async -> [SpotifyManager.Playlist] {
        guard let accessToken = accessToken else { return [] }

        // Get current user ID if we don't have it
        if currentUserId == nil {
            _ = await fetchCurrentUser()
        }

        guard let url = URL(string: "\(baseURL)/me/playlists?limit=50") else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

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
        let limit = 100
        var hasMore = true

        while hasMore {
            guard let url = URL(string: "\(baseURL)/playlists/\(playlistId)/tracks?limit=\(limit)&offset=\(offset)") else { break }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)

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
                    return SpotifyManager.Track(
                        id: uniqueId,
                        trackId: track.id,
                        name: track.name,
                        artist: track.artists.map { $0.name }.joined(separator: ", "),
                        album: track.album.name,
                        releaseDate: formatReleaseDate(track.album.release_date),
                        duration: formatDuration(track.duration_ms),
                        uri: track.uri
                    )
                }

                allTracks.append(contentsOf: tracks)

                // Report progress
                progressHandler?(allTracks.count, tracksResponse.total ?? allTracks.count)

                // Check if there are more tracks to fetch
                hasMore = tracksResponse.next != nil
                offset += limit

                print("Fetched \(allTracks.count) tracks so far...")

            } catch {
                print("Error fetching playlist tracks at offset \(offset): \(error)")
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

    func searchTracks(title: String = "", artist: String = "", album: String = "", year: String = "", limit: Int = 100) async -> [SpotifyManager.Track] {
        guard let accessToken = accessToken else { return [] }

        // Build search query with field-specific filters when provided
        var queryParts: [String] = []

        // Only add field filters if that specific field has content
        if !title.isEmpty {
            // For title, use track: filter
            queryParts.append("track:\(title)")
        }
        if !artist.isEmpty {
            // For artist, use artist: filter
            queryParts.append("artist:\(artist)")
        }
        if !album.isEmpty {
            // For album, use album: filter
            queryParts.append("album:\(album)")
        }
        if !year.isEmpty {
            // For year, use year: filter
            queryParts.append("year:\(year)")
        }

        // If no search terms, return empty
        if queryParts.isEmpty {
            return []
        }

        let query = queryParts.joined(separator: " ")
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return [] }
        guard let url = URL(string: "\(baseURL)/search?q=\(encodedQuery)&type=track&limit=\(limit)") else { return [] }

        print("Search query: \(query)")
        print("Search URL: \(url)")

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
                if await refreshAccessToken() {
                    return await searchTracks(title: title, artist: artist, album: album, year: year, limit: limit)
                } else {
                    logout()
                    return []
                }
            }

            // Try to parse the response
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                print("Search response: \(json.keys)")

                if let error = json["error"] as? [String: Any] {
                    print("Search error: \(error)")
                    return []
                }

                if let tracks = json["tracks"] as? [String: Any],
                   let items = tracks["items"] as? [[String: Any]] {
                    print("Found \(items.count) tracks")

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

                    return SpotifyManager.Track(
                        id: UUID().uuidString, // Unique ID for table selection
                        trackId: id,
                        name: name,
                        artist: firstArtist,
                        album: albumName,
                        releaseDate: releaseDate,
                        duration: duration,
                        uri: uri
                    )
                    }
                }
            } else {
                print("Failed to parse search response")
            }
        } catch {
            print("Error searching tracks: \(error)")
        }

        return []
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
            let (_, response) = try await URLSession.shared.data(for: request)

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
            let (_, response) = try await URLSession.shared.data(for: request)

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
            let (_, response) = try await URLSession.shared.data(for: request)

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
        let chunks = trackUris.chunked(into: 100)

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
                let (_, response) = try await URLSession.shared.data(for: request)

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
        isAuthenticated = false

        try? keychain.delete(for: "spotify_web_access_token")
        try? keychain.delete(for: "spotify_web_refresh_token")

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
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}