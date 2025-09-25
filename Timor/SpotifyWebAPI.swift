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

        let scopes = "playlist-read-private playlist-read-collaborative user-read-private"
        let state = UUID().uuidString

        var components = URLComponents(string: authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "show_dialog", value: "true")
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

    func fetchUserPlaylists() async -> [SpotifyManager.Playlist] {
        guard let accessToken = accessToken else { return [] }
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
                SpotifyManager.Playlist(
                    id: item.id,
                    name: item.name,
                    totalTracks: item.tracks.total,
                    owner: item.owner.display_name ?? item.owner.id
                )
            }
        } catch {
            print("Error fetching playlists: \(error)")
            return []
        }
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
}

struct Owner: Codable {
    let id: String
    let display_name: String?
}

struct Tracks: Codable {
    let total: Int
}