//
//  ImportView.swift
//  Timor
//
//  Import tracks from CSV files or Spotify URLs
//

import SwiftUI
import TabularData
import UniformTypeIdentifiers

/// Results from an import operation
struct ImportResults {
    let added: Int
    let duplicatesSkipped: Int
    let notFound: [String]
    let errors: [String]

    var isEmpty: Bool {
        added == 0 && duplicatesSkipped == 0 && notFound.isEmpty && errors.isEmpty
    }

    var summary: String {
        var parts: [String] = []
        if added > 0 {
            parts.append("\(added) track(s) added")
        }
        if duplicatesSkipped > 0 {
            parts.append("\(duplicatesSkipped) duplicate(s) skipped")
        }
        if !notFound.isEmpty {
            parts.append("\(notFound.count) not found")
        }
        if !errors.isEmpty {
            parts.append("\(errors.count) error(s)")
        }
        return parts.isEmpty ? "No changes" : parts.joined(separator: ", ")
    }
}

/// View for importing tracks from CSV files or Spotify URLs
struct ImportView: View {
    @ObservedObject var spotifyManager: SpotifyManager
    let playlist: SpotifyManager.Playlist
    @Binding var isPresented: Bool

    enum ImportMode: String, CaseIterable {
        case csv = "CSV File"
        case urls = "Spotify URLs"
    }

    @State private var importMode: ImportMode = .csv
    @State private var urlText = ""
    @State private var skipDuplicates = true
    @State private var isImporting = false
    @State private var importResults: ImportResults?
    @State private var showFileImporter = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Content based on mode
            VStack(spacing: 16) {
                // Mode picker
                Picker("Import From", selection: $importMode) {
                    ForEach(ImportMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                // Mode-specific content
                switch importMode {
                case .csv:
                    csvImportView
                case .urls:
                    urlImportView
                }

                // Options
                Toggle("Skip duplicate tracks", isOn: $skipDuplicates)
                    .padding(.horizontal)

                Spacer()

                // Results
                if let results = importResults {
                    resultsView(results)
                }
            }
            .padding(.top)

            Divider()

            // Footer
            footerView
        }
        .frame(width: Constants.UI.importViewWidth, height: Constants.UI.importViewHeight)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.commaSeparatedText],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import Tracks")
                    .font(.headline)
                Text("to \(playlist.name)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
    }

    // MARK: - CSV Import View

    private var csvImportView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text("Import from CSV file")
                .font(.headline)

            Text("Expected format: Title, Artist, Album, Release Date, Duration, Spotify URI")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Choose CSV File...") {
                showFileImporter = true
            }
            .buttonStyle(.glassProminent)
            .disabled(isImporting)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    // MARK: - URL Import View

    private var urlImportView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Enter Spotify track URLs (one per line)")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $urlText)
                .font(.system(.body, design: .monospaced))
                .frame(height: 150)
                .border(Color.gray.opacity(0.3))
                .disabled(isImporting)

            Text("Supported formats:")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("https://open.spotify.com/track/...")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("spotify:track:...")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
    }

    // MARK: - Results View

    private func resultsView(_ results: ImportResults) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: results.errors.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(results.errors.isEmpty ? .green : .orange)
                Text(results.summary)
                    .font(.subheadline)
            }

            if !results.notFound.isEmpty {
                DisclosureGroup("Not found (\(results.notFound.count))") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(results.notFound, id: \.self) { item in
                                Text(item)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxHeight: 80)
                }
                .font(.caption)
            }

            if !results.errors.isEmpty {
                DisclosureGroup("Errors (\(results.errors.count))") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(results.errors, id: \.self) { error in
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    .frame(maxHeight: 80)
                }
                .font(.caption)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            if isImporting {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Importing...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Close") {
                isPresented = false
            }
            .keyboardShortcut(.escape)

            if importMode == .urls && !urlText.isEmpty {
                Button("Import URLs") {
                    Task {
                        await importFromURLs()
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(isImporting)
            }
        }
        .padding()
    }

    // MARK: - Import Actions

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                await importFromCSV(url: url)
            }
        case .failure(let error):
            importResults = ImportResults(
                added: 0,
                duplicatesSkipped: 0,
                notFound: [],
                errors: [error.localizedDescription]
            )
        }
    }

    private func importFromCSV(url: URL) async {
        isImporting = true
        defer { isImporting = false }

        importResults = await spotifyManager.importTracksFromCSV(
            url: url,
            playlistId: playlist.id,
            skipDuplicates: skipDuplicates
        )
    }

    private func importFromURLs() async {
        isImporting = true
        defer { isImporting = false }

        let urls = urlText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        importResults = await spotifyManager.importTracksFromURLs(
            urls: urls,
            playlistId: playlist.id,
            skipDuplicates: skipDuplicates
        )
    }
}

// MARK: - SpotifyManager Import Extensions

extension SpotifyManager {

    /// Imports tracks from a CSV file
    func importTracksFromCSV(url: URL, playlistId: String, skipDuplicates: Bool) async -> ImportResults {
        var added = 0
        var duplicatesSkipped = 0
        var notFound: [String] = []
        var errors: [String] = []

        // Start accessing security-scoped resource
        guard url.startAccessingSecurityScopedResource() else {
            return ImportResults(added: 0, duplicatesSkipped: 0, notFound: [], errors: ["Cannot access file"])
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let dataFrame = try DataFrame(contentsOfCSVFile: url)
            var trackUrisToAdd: [String] = []

            // Get existing track URIs for duplicate detection
            let existingTrackIds = Set(currentPlaylistTracks.map { $0.trackId })

            for row in dataFrame.rows {
                // Try to get URI from the CSV (if export format)
                if let uri = row["Spotify URI"] as? String, uri.hasPrefix("spotify:track:") {
                    let trackId = String(uri.dropFirst("spotify:track:".count))

                    if skipDuplicates && existingTrackIds.contains(trackId) {
                        duplicatesSkipped += 1
                        continue
                    }

                    trackUrisToAdd.append(uri)
                } else {
                    // Try to search by title/artist
                    let title = row["Title"] as? String ?? ""
                    let artist = row["Artist"] as? String ?? ""

                    if title.isEmpty {
                        continue
                    }

                    let results = await SpotifyWebAPI.shared.searchTracks(
                        title: title,
                        artist: artist,
                        limit: 1
                    )

                    if let track = results.first {
                        if skipDuplicates && existingTrackIds.contains(track.trackId) {
                            duplicatesSkipped += 1
                            continue
                        }
                        trackUrisToAdd.append(track.uri)
                    } else {
                        notFound.append("\(title) - \(artist)")
                    }
                }
            }

            // Add tracks in batches (Spotify API limit)
            for chunk in trackUrisToAdd.chunked(into: Constants.Spotify.trackFetchLimit) {
                let success = await SpotifyWebAPI.shared.addTracksToPlaylist(
                    playlistId: playlistId,
                    trackUris: chunk
                )
                if success {
                    added += chunk.count
                } else {
                    errors.append("Failed to add \(chunk.count) tracks")
                }
            }

            // Refresh the playlist if we added tracks
            if added > 0 {
                fetchTracksForPlaylist(playlistId, forceRefresh: true)
                updatePlaylistTrackCount(playlistId, addedCount: added)
            }

        } catch {
            errors.append("CSV parse error: \(error.localizedDescription)")
        }

        return ImportResults(
            added: added,
            duplicatesSkipped: duplicatesSkipped,
            notFound: notFound,
            errors: errors
        )
    }

    /// Imports tracks from Spotify URLs
    func importTracksFromURLs(urls: [String], playlistId: String, skipDuplicates: Bool) async -> ImportResults {
        var added = 0
        var duplicatesSkipped = 0
        var notFound: [String] = []
        var errors: [String] = []
        var trackUrisToAdd: [String] = []

        // Get existing track IDs for duplicate detection
        let existingTrackIds = Set(currentPlaylistTracks.map { $0.trackId })

        var candidates: [(id: String, source: String)] = []
        for urlString in urls {
            if let trackId = parseSpotifyTrackId(from: urlString) {
                if skipDuplicates && existingTrackIds.contains(trackId) {
                    duplicatesSkipped += 1
                    continue
                }
                candidates.append((trackId, urlString))
            } else {
                notFound.append(urlString)
            }
        }

        // FUNC-4: verify the parsed IDs resolve to real tracks before adding them.
        let validIds = await SpotifyWebAPI.shared.fetchExistingTrackIds(candidates.map { $0.id })
        for candidate in candidates {
            if validIds.contains(candidate.id) {
                trackUrisToAdd.append("spotify:track:\(candidate.id)")
            } else {
                notFound.append(candidate.source)
            }
        }

        // Add tracks in batches (Spotify API limit)
        for chunk in trackUrisToAdd.chunked(into: Constants.Spotify.trackFetchLimit) {
            let success = await SpotifyWebAPI.shared.addTracksToPlaylist(
                playlistId: playlistId,
                trackUris: chunk
            )
            if success {
                added += chunk.count
            } else {
                errors.append("Failed to add \(chunk.count) tracks")
            }
        }

        // Refresh the playlist if we added tracks
        if added > 0 {
            fetchTracksForPlaylist(playlistId, forceRefresh: true)
            updatePlaylistTrackCount(playlistId, addedCount: added)
        }

        return ImportResults(
            added: added,
            duplicatesSkipped: duplicatesSkipped,
            notFound: notFound,
            errors: errors
        )
    }

    /// Parses a Spotify track ID from various URL formats
    private func parseSpotifyTrackId(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)

        // Handle spotify:track:ID format
        if trimmed.hasPrefix("spotify:track:") {
            return String(trimmed.dropFirst("spotify:track:".count))
        }

        // Handle https://open.spotify.com/track/ID format
        if let url = URL(string: trimmed),
           url.host == "open.spotify.com",
           url.pathComponents.contains("track"),
           let trackIndex = url.pathComponents.firstIndex(of: "track"),
           trackIndex + 1 < url.pathComponents.count {
            let trackId = url.pathComponents[trackIndex + 1]
            // Remove any query parameters
            return trackId.components(separatedBy: "?").first
        }

        return nil
    }
}
