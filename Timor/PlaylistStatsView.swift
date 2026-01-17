//
//  PlaylistStatsView.swift
//  Timor
//
//  Playlist statistics and insights view
//

import SwiftUI

/// Statistics computed from playlist tracks
struct PlaylistStatistics {
    let trackCount: Int
    let totalDurationMs: Int
    let uniqueArtists: Int
    let uniqueAlbums: Int
    let oldestRelease: String?
    let newestRelease: String?
    let averageDurationMs: Int
    let topArtists: [(artist: String, count: Int)]
    let topAlbums: [(album: String, count: Int)]
    let decadeDistribution: [(decade: String, count: Int)]
    let likedCount: Int

    /// Formatted total duration (e.g., "2h 45m")
    var formattedTotalDuration: String {
        let totalSeconds = totalDurationMs / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    /// Formatted average duration (e.g., "3:42")
    var formattedAverageDuration: String {
        let totalSeconds = averageDurationMs / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Percentage of tracks that are liked
    var likedPercentage: Double {
        guard trackCount > 0 else { return 0 }
        return Double(likedCount) / Double(trackCount) * 100
    }

    static func compute(from tracks: [SpotifyManager.Track]) -> PlaylistStatistics {
        guard !tracks.isEmpty else {
            return PlaylistStatistics(
                trackCount: 0,
                totalDurationMs: 0,
                uniqueArtists: 0,
                uniqueAlbums: 0,
                oldestRelease: nil,
                newestRelease: nil,
                averageDurationMs: 0,
                topArtists: [],
                topAlbums: [],
                decadeDistribution: [],
                likedCount: 0
            )
        }

        // Parse duration strings to milliseconds
        func parseDuration(_ duration: String) -> Int {
            let parts = duration.split(separator: ":")
            guard parts.count == 2,
                  let minutes = Int(parts[0]),
                  let seconds = Int(parts[1]) else {
                return 0
            }
            return (minutes * 60 + seconds) * 1000
        }

        // Calculate durations
        let durations = tracks.map { parseDuration($0.duration) }
        let totalDurationMs = durations.reduce(0, +)
        let averageDurationMs = totalDurationMs / tracks.count

        // Unique artists and albums
        let allArtists = tracks.flatMap { $0.artist.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
        let uniqueArtists = Set(allArtists).count
        let uniqueAlbums = Set(tracks.map { $0.album }).count

        // Top artists
        var artistCounts: [String: Int] = [:]
        for artist in allArtists {
            artistCounts[artist, default: 0] += 1
        }
        let topArtists = artistCounts.sorted { $0.value > $1.value }
            .prefix(5)
            .map { ($0.key, $0.value) }

        // Top albums
        var albumCounts: [String: Int] = [:]
        for track in tracks {
            albumCounts[track.album, default: 0] += 1
        }
        let topAlbums = albumCounts.sorted { $0.value > $1.value }
            .prefix(5)
            .map { ($0.key, $0.value) }

        // Release date analysis
        let releaseDates = tracks.map { $0.releaseDate }.filter { !$0.isEmpty }
        let sortedDates = releaseDates.sorted()
        let oldestRelease = sortedDates.first
        let newestRelease = sortedDates.last

        // Decade distribution
        var decadeCounts: [String: Int] = [:]
        for date in releaseDates {
            // Extract year from date string (could be "2023", "2023-05", or "2023-05-15")
            let yearStr = String(date.prefix(4))
            if let year = Int(yearStr) {
                let decade = (year / 10) * 10
                let decadeStr = "\(decade)s"
                decadeCounts[decadeStr, default: 0] += 1
            }
        }
        let decadeDistribution = decadeCounts.sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }

        // Liked count
        let likedCount = tracks.filter { $0.isLiked }.count

        return PlaylistStatistics(
            trackCount: tracks.count,
            totalDurationMs: totalDurationMs,
            uniqueArtists: uniqueArtists,
            uniqueAlbums: uniqueAlbums,
            oldestRelease: oldestRelease,
            newestRelease: newestRelease,
            averageDurationMs: averageDurationMs,
            topArtists: topArtists,
            topAlbums: topAlbums,
            decadeDistribution: decadeDistribution,
            likedCount: likedCount
        )
    }
}

/// View displaying playlist statistics
struct PlaylistStatsView: View {
    @ObservedObject var spotifyManager: SpotifyManager
    let playlist: SpotifyManager.Playlist?
    let isViewingLikedSongs: Bool
    @Binding var isPresented: Bool

    private var stats: PlaylistStatistics {
        PlaylistStatistics.compute(from: spotifyManager.currentPlaylistTracks)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Stats content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Overview section
                    overviewSection

                    Divider()

                    // Top Artists section
                    if !stats.topArtists.isEmpty {
                        topArtistsSection
                        Divider()
                    }

                    // Top Albums section
                    if !stats.topAlbums.isEmpty {
                        topAlbumsSection
                        Divider()
                    }

                    // Decade distribution
                    if !stats.decadeDistribution.isEmpty {
                        decadeSection
                    }
                }
                .padding()
            }

            Divider()

            // Footer
            footerView
        }
        .frame(width: 500, height: 550)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Playlist Statistics")
                    .font(.headline)
                Text(isViewingLikedSongs ? "Liked Songs" : (playlist?.name ?? ""))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chart.bar.xaxis")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Overview Section

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Overview")
                .font(.headline)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 16) {
                StatCard(title: "Tracks", value: "\(stats.trackCount)", icon: "music.note.list")
                StatCard(title: "Duration", value: stats.formattedTotalDuration, icon: "clock")
                StatCard(title: "Avg Length", value: stats.formattedAverageDuration, icon: "timer")
                StatCard(title: "Artists", value: "\(stats.uniqueArtists)", icon: "person.2")
                StatCard(title: "Albums", value: "\(stats.uniqueAlbums)", icon: "square.stack")
                StatCard(title: "Liked", value: String(format: "%.0f%%", stats.likedPercentage), icon: "heart.fill")
            }

            // Date range
            if let oldest = stats.oldestRelease, let newest = stats.newestRelease {
                HStack {
                    Text("Release Years:")
                        .foregroundStyle(.secondary)
                    Text("\(oldest.prefix(4)) – \(newest.prefix(4))")
                        .fontWeight(.medium)
                }
                .font(.caption)
            }
        }
    }

    // MARK: - Top Artists Section

    private var topArtistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top Artists")
                .font(.headline)

            ForEach(Array(stats.topArtists.enumerated()), id: \.offset) { index, item in
                HStack {
                    Text("\(index + 1).")
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                    Text(item.artist)
                        .lineLimit(1)
                    Spacer()
                    Text("\(item.count) track\(item.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - Top Albums Section

    private var topAlbumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top Albums")
                .font(.headline)

            ForEach(Array(stats.topAlbums.enumerated()), id: \.offset) { index, item in
                HStack {
                    Text("\(index + 1).")
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                    Text(item.album)
                        .lineLimit(1)
                    Spacer()
                    Text("\(item.count) track\(item.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - Decade Section

    private var decadeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("By Decade")
                .font(.headline)

            HStack(alignment: .bottom, spacing: 8) {
                ForEach(stats.decadeDistribution, id: \.decade) { item in
                    VStack {
                        Text("\(item.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor.opacity(0.8))
                            .frame(width: 40, height: barHeight(for: item.count))

                        Text(item.decade)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func barHeight(for count: Int) -> CGFloat {
        guard let maxCount = stats.decadeDistribution.map({ $0.count }).max(), maxCount > 0 else {
            return 20
        }
        let maxHeight: CGFloat = 100
        return max(20, CGFloat(count) / CGFloat(maxCount) * maxHeight)
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Spacer()
            Button("Close") {
                isPresented = false
            }
            .keyboardShortcut(.escape)
        }
        .padding()
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.gray.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
