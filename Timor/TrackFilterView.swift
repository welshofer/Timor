//
//  TrackFilterView.swift
//  Timor
//
//  Advanced filtering options for playlist tracks
//

import SwiftUI

/// Filter criteria for tracks
struct TrackFilter: Equatable {
    var minYear: Int? = nil
    var maxYear: Int? = nil
    var minDurationSeconds: Int? = nil
    var maxDurationSeconds: Int? = nil
    var likedStatus: LikedStatus = .all
    var selectedArtists: Set<String> = []

    enum LikedStatus: String, CaseIterable {
        case all = "All"
        case likedOnly = "Liked Only"
        case notLikedOnly = "Not Liked"
    }

    var isActive: Bool {
        minYear != nil ||
        maxYear != nil ||
        minDurationSeconds != nil ||
        maxDurationSeconds != nil ||
        likedStatus != .all ||
        !selectedArtists.isEmpty
    }

    var activeFilterCount: Int {
        var count = 0
        if minYear != nil || maxYear != nil { count += 1 }
        if minDurationSeconds != nil || maxDurationSeconds != nil { count += 1 }
        if likedStatus != .all { count += 1 }
        if !selectedArtists.isEmpty { count += 1 }
        return count
    }

    func matches(_ track: SpotifyManager.Track) -> Bool {
        // Check year range
        if let minYear = minYear, let maxYear = maxYear {
            let yearStr = String(track.releaseDate.prefix(4))
            if let year = Int(yearStr) {
                if year < minYear || year > maxYear {
                    return false
                }
            }
        }

        // Check duration range
        if minDurationSeconds != nil || maxDurationSeconds != nil {
            let durationSeconds = parseDuration(track.duration)
            if let min = minDurationSeconds, durationSeconds < min {
                return false
            }
            if let max = maxDurationSeconds, durationSeconds > max {
                return false
            }
        }

        // Check liked status
        switch likedStatus {
        case .all:
            break
        case .likedOnly:
            if !track.isLiked { return false }
        case .notLikedOnly:
            if track.isLiked { return false }
        }

        // Check artist filter
        if !selectedArtists.isEmpty {
            let trackArtists = Set(track.artist.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
            if trackArtists.isDisjoint(with: selectedArtists) {
                return false
            }
        }

        return true
    }

    private func parseDuration(_ duration: String) -> Int {
        let parts = duration.split(separator: ":")
        guard parts.count == 2,
              let minutes = Int(parts[0]),
              let seconds = Int(parts[1]) else {
            return 0
        }
        return minutes * 60 + seconds
    }

    mutating func reset() {
        minYear = nil
        maxYear = nil
        minDurationSeconds = nil
        maxDurationSeconds = nil
        likedStatus = .all
        selectedArtists = []
    }
}

/// Popover view for advanced track filtering
struct TrackFilterView: View {
    @Binding var filter: TrackFilter
    let tracks: [SpotifyManager.Track]

    // Computed ranges from current tracks
    private var yearRange: ClosedRange<Int> {
        let years = tracks.compactMap { track -> Int? in
            let yearStr = String(track.releaseDate.prefix(4))
            return Int(yearStr)
        }
        let minYear = years.min() ?? 1950
        let maxYear = years.max() ?? 2025
        return minYear...maxYear
    }

    private var durationRange: ClosedRange<Int> {
        let durations = tracks.map { parseDuration($0.duration) }
        let minDur = max(0, (durations.min() ?? 0))
        let maxDur = max(600, (durations.max() ?? 600))
        return minDur...maxDur
    }

    private var allArtists: [String] {
        var artists: [String: Int] = [:]
        for track in tracks {
            for artist in track.artist.split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespaces) }) {
                artists[artist, default: 0] += 1
            }
        }
        return artists.sorted { $0.value > $1.value }.map { $0.key }
    }

    // Local state for sliders
    @State private var yearSliderRange: ClosedRange<Double> = 1950...2025
    @State private var durationSliderRange: ClosedRange<Double> = 0...600
    @State private var isYearFilterEnabled = false
    @State private var isDurationFilterEnabled = false
    // PERF-4: cache the artist histogram (full grouping over all tracks) instead of
    // recomputing it on every popover render / slider drag.
    @State private var cachedArtists: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("Filter Tracks")
                    .font(.headline)
                Spacer()
                if filter.isActive {
                    Button("Reset") {
                        withAnimation {
                            filter.reset()
                            isYearFilterEnabled = false
                            isDurationFilterEnabled = false
                        }
                    }
                    .font(.caption)
                }
            }

            Divider()

            // Year Range
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $isYearFilterEnabled) {
                    Label("Release Year", systemImage: "calendar")
                        .font(.subheadline)
                }
                .onChange(of: isYearFilterEnabled) { _, newValue in
                    if newValue {
                        filter.minYear = Int(yearSliderRange.lowerBound)
                        filter.maxYear = Int(yearSliderRange.upperBound)
                    } else {
                        filter.minYear = nil
                        filter.maxYear = nil
                    }
                }

                if isYearFilterEnabled {
                    HStack {
                        Text("\(Int(yearSliderRange.lowerBound))")
                            .font(.caption)
                            .frame(width: 40)
                        Spacer()
                        Text("\(Int(yearSliderRange.upperBound))")
                            .font(.caption)
                            .frame(width: 40)
                    }
                    .foregroundStyle(.secondary)

                    RangeSlider(
                        range: $yearSliderRange,
                        bounds: Double(yearRange.lowerBound)...Double(yearRange.upperBound),
                        step: 1
                    )
                    .onChange(of: yearSliderRange) { _, newValue in
                        filter.minYear = Int(newValue.lowerBound)
                        filter.maxYear = Int(newValue.upperBound)
                    }
                }
            }

            Divider()

            // Duration Range
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $isDurationFilterEnabled) {
                    Label("Duration", systemImage: "timer")
                        .font(.subheadline)
                }
                .onChange(of: isDurationFilterEnabled) { _, newValue in
                    if newValue {
                        filter.minDurationSeconds = Int(durationSliderRange.lowerBound)
                        filter.maxDurationSeconds = Int(durationSliderRange.upperBound)
                    } else {
                        filter.minDurationSeconds = nil
                        filter.maxDurationSeconds = nil
                    }
                }

                if isDurationFilterEnabled {
                    HStack {
                        Text(formatDuration(Int(durationSliderRange.lowerBound)))
                            .font(.caption)
                            .frame(width: 40)
                        Spacer()
                        Text(formatDuration(Int(durationSliderRange.upperBound)))
                            .font(.caption)
                            .frame(width: 40)
                    }
                    .foregroundStyle(.secondary)

                    RangeSlider(
                        range: $durationSliderRange,
                        bounds: Double(durationRange.lowerBound)...Double(durationRange.upperBound),
                        step: 10
                    )
                    .onChange(of: durationSliderRange) { _, newValue in
                        filter.minDurationSeconds = Int(newValue.lowerBound)
                        filter.maxDurationSeconds = Int(newValue.upperBound)
                    }
                }
            }

            Divider()

            // Liked Status
            VStack(alignment: .leading, spacing: 8) {
                Label("Liked Status", systemImage: "heart")
                    .font(.subheadline)

                Picker("", selection: $filter.likedStatus) {
                    ForEach(TrackFilter.LikedStatus.allCases, id: \.self) { status in
                        Text(status.rawValue).tag(status)
                    }
                }
                .pickerStyle(.segmented)
            }

            Divider()

            // Artist Filter (top 10)
            if !cachedArtists.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Artists", systemImage: "person.2")
                        .font(.subheadline)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(cachedArtists.prefix(15), id: \.self) { artist in
                                Toggle(isOn: Binding(
                                    get: { filter.selectedArtists.contains(artist) },
                                    set: { isSelected in
                                        if isSelected {
                                            filter.selectedArtists.insert(artist)
                                        } else {
                                            filter.selectedArtists.remove(artist)
                                        }
                                    }
                                )) {
                                    Text(artist)
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                                #if os(macOS)
                                .toggleStyle(.checkbox)
                                #endif
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }
            }
        }
        .padding()
        .frame(width: 280)
        .onAppear {
            cachedArtists = allArtists  // PERF-4: compute the histogram once
            // Initialize slider positions from current filter
            if let minYear = filter.minYear, let maxYear = filter.maxYear {
                yearSliderRange = Double(minYear)...Double(maxYear)
                isYearFilterEnabled = true
            } else {
                yearSliderRange = Double(yearRange.lowerBound)...Double(yearRange.upperBound)
            }

            if let minDur = filter.minDurationSeconds, let maxDur = filter.maxDurationSeconds {
                durationSliderRange = Double(minDur)...Double(maxDur)
                isDurationFilterEnabled = true
            } else {
                durationSliderRange = Double(durationRange.lowerBound)...Double(durationRange.upperBound)
            }
        }
    }

    private func parseDuration(_ duration: String) -> Int {
        let parts = duration.split(separator: ":")
        guard parts.count == 2,
              let minutes = Int(parts[0]),
              let seconds = Int(parts[1]) else {
            return 0
        }
        return minutes * 60 + seconds
    }

    private func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Range Slider Component

struct RangeSlider: View {
    @Binding var range: ClosedRange<Double>
    let bounds: ClosedRange<Double>
    let step: Double

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height: CGFloat = 24

            ZStack(alignment: .leading) {
                // Track background
                Capsule()
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 4)

                // Selected range
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: rangeWidth(width: width), height: 4)
                    .offset(x: leftOffset(width: width))

                // Lower thumb
                Circle()
                    .fill(Color.white)
                    .frame(width: 16, height: 16)
                    .shadow(radius: 2)
                    .offset(x: leftOffset(width: width) - 8)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let newLower = valueForPosition(value.location.x, width: width)
                                if newLower < range.upperBound - step {
                                    range = newLower...range.upperBound
                                }
                            }
                    )

                // Upper thumb
                Circle()
                    .fill(Color.white)
                    .frame(width: 16, height: 16)
                    .shadow(radius: 2)
                    .offset(x: rightOffset(width: width) - 8)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let newUpper = valueForPosition(value.location.x, width: width)
                                if newUpper > range.lowerBound + step {
                                    range = range.lowerBound...newUpper
                                }
                            }
                    )
            }
            .frame(height: height)
        }
        .frame(height: 24)
    }

    /// STAB-1: guard against a zero-width range (e.g. all tracks share one year) which would
    /// divide by zero and produce NaN offsets / a broken slider.
    private var span: Double {
        max(bounds.upperBound - bounds.lowerBound, 0.0001)
    }

    private func leftOffset(width: CGFloat) -> CGFloat {
        let ratio = (range.lowerBound - bounds.lowerBound) / span
        return CGFloat(ratio) * width
    }

    private func rightOffset(width: CGFloat) -> CGFloat {
        let ratio = (range.upperBound - bounds.lowerBound) / span
        return CGFloat(ratio) * width
    }

    private func rangeWidth(width: CGFloat) -> CGFloat {
        rightOffset(width: width) - leftOffset(width: width)
    }

    private func valueForPosition(_ position: CGFloat, width: CGFloat) -> Double {
        let safeWidth = max(width, 1)
        let ratio = max(0, min(1, position / safeWidth))
        let rawValue = bounds.lowerBound + ratio * span
        let steppedValue = (rawValue / step).rounded() * step
        return max(bounds.lowerBound, min(bounds.upperBound, steppedValue))
    }
}
