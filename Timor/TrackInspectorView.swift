//
//  TrackInspectorView.swift
//  Timor
//
//  Inspector pane for displaying track details
//

import SwiftUI

struct TrackInspectorView: View {
    let track: SpotifyManager.Track?
    @State private var albumArtImage: NSImage?
    @State private var isLoadingImage = false
    @State private var showingAlbumArtModal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let track = track {
                // Header
                Text("Track Details")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Divider()

                // Track info
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        DetailRow(label: "Title", value: track.name)
                        DetailRow(label: "Artist", value: track.artist)
                        DetailRow(label: "Album", value: track.album)
                        DetailRow(label: "Duration", value: track.duration)
                        DetailRow(label: "Release Date", value: track.releaseDate)

                        if track.isLiked {
                            HStack {
                                Image(systemName: "heart.fill")
                                    .foregroundColor(.red)
                                Text("Liked")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)
                        }
                    }
                }
                .textSelection(.enabled)

                Spacer()

                // Album Art
                if let albumArtImage = albumArtImage {
                    VStack {
                        Divider()

                        Image(nsImage: albumArtImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 200, height: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .shadow(radius: 2)
                            .onTapGesture(count: 2) {
                                showingAlbumArtModal = true
                            }
                            .help("Double-click to view full size")
                    }
                } else if isLoadingImage {
                    VStack {
                        Divider()
                        ProgressView()
                            .frame(width: 200, height: 200)
                    }
                } else if track.albumArtURL != nil {
                    VStack {
                        Divider()
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 200, height: 200)
                            .overlay(
                                Image(systemName: "photo")
                                    .font(.largeTitle)
                                    .foregroundColor(.gray)
                            )
                    }
                }
            } else {
                // No track selected
                VStack {
                    Spacer()
                    Image(systemName: "music.note")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("No Track Selected")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Select a track to view details")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .frame(width: 280)
        .background(Color(NSColor.controlBackgroundColor))
        .onChange(of: track?.albumArtURL) { oldValue, newValue in
            if let urlString = newValue {
                loadAlbumArt(from: urlString)
            } else {
                albumArtImage = nil
            }
        }
        .onAppear {
            if let urlString = track?.albumArtURL {
                loadAlbumArt(from: urlString)
            }
        }
        .sheet(isPresented: $showingAlbumArtModal) {
            AlbumArtModalView(
                albumArtImage: albumArtImage,
                trackName: track?.name ?? "",
                artistName: track?.artist ?? "",
                albumName: track?.album ?? "",
                releaseYear: String(track?.releaseDate.prefix(4) ?? "")
            )
        }
    }

    private func loadAlbumArt(from urlString: String) {
        guard let url = URL(string: urlString) else { return }

        isLoadingImage = true

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let image = NSImage(data: data) {
                    await MainActor.run {
                        self.albumArtImage = image
                        self.isLoadingImage = false
                    }
                }
            } catch {
                print("Failed to load album art: \(error)")
                await MainActor.run {
                    self.isLoadingImage = false
                }
            }
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .lineLimit(2)
                .truncationMode(.tail)
        }
    }
}

struct AlbumArtModalView: View {
    let albumArtImage: NSImage?
    let trackName: String
    let artistName: String
    let albumName: String
    let releaseYear: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            // Background with padding for the image
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .frame(width: 680, height: 720)

            VStack(spacing: 16) {
                if let albumArtImage = albumArtImage {
                    Image(nsImage: albumArtImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 640, height: 640)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            dismiss()
                        }
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 640, height: 640)
                        .overlay(
                            Image(systemName: "photo")
                                .font(.system(size: 72))
                                .foregroundColor(.gray)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            dismiss()
                        }
                }

                // Track info
                VStack(spacing: 4) {
                    Text(trackName)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(artistName) • \(albumName) • \(releaseYear)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal)
            }
            .padding()
        }
        .background(Color.clear)
        .presentationBackground(.clear)
    }
}

#Preview {
    TrackInspectorView(track: SpotifyManager.Track(
        id: "1",
        trackId: "abc",
        name: "Sample Track",
        artist: "Sample Artist",
        album: "Sample Album",
        releaseDate: "2024",
        duration: "3:45",
        uri: "spotify:track:abc",
        albumArtURL: nil,
        isLiked: true
    ))
}