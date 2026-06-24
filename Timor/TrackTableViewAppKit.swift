//
//  TrackTableViewAppKit.swift
//  Timor
//
//  Native NSTableView-backed track list. SwiftUI `Table` has a per-cell/render overhead that
//  stutters when scrolling large playlists even over already-loaded rows; a real NSTableView
//  with cell reuse scrolls natively. Preserves multi-select, header sort, drag-to-playlist,
//  the context menu, and inspector selection.
//

#if os(macOS)
import SwiftUI
import AppKit

let trackPasteboardType = NSPasteboard.PasteboardType("xsf.welshofer.Timor.spotifytrack")

// MARK: - Columns

private enum TrackColumn: String, CaseIterable {
    case artwork, title, artist, album, releaseDate, duration, liked

    var id: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

    var title: String {
        switch self {
        case .artwork: return ""
        case .title: return "Title"
        case .artist: return "Artist"
        case .album: return "Album"
        case .releaseDate: return "Release Date"
        case .duration: return "Duration"
        case .liked: return "♥"
        }
    }

    var width: CGFloat {
        switch self {
        case .artwork: return 40
        case .title: return 240
        case .artist, .album: return 180
        case .releaseDate: return 120
        case .duration: return 70
        case .liked: return 28
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .artwork, .liked: return width
        case .title: return 160
        case .artist, .album: return 120
        case .releaseDate: return 90
        case .duration: return 60
        }
    }

    func comparator(ascending: Bool) -> KeyPathComparator<SpotifyManager.Track>? {
        let order: SortOrder = ascending ? .forward : .reverse
        switch self {
        case .title: return KeyPathComparator(\.name, order: order)
        case .artist: return KeyPathComparator(\.artist, order: order)
        case .album: return KeyPathComparator(\.album, order: order)
        case .releaseDate: return KeyPathComparator(\.releaseDate, order: order)
        case .duration: return KeyPathComparator(\.durationSeconds, order: order)
        case .artwork, .liked: return nil
        }
    }

    /// ATTR-3: the like column gets an SF Symbol header instead of a raw "♥" glyph.
    func applyHeader(to tableColumn: NSTableColumn) {
        guard self == .liked else {
            tableColumn.title = title
            return
        }
        let headerCell = NSTableHeaderCell(textCell: "")
        headerCell.image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: "Liked")
        tableColumn.headerCell = headerCell
    }

    func text(for track: SpotifyManager.Track) -> String {
        switch self {
        case .title: return track.name
        case .artist: return track.artist
        case .album: return track.album
        case .releaseDate: return track.displayReleaseDate
        case .duration: return track.duration
        case .artwork, .liked: return ""
        }
    }
}

// MARK: - Representable

struct TrackTableRepresentable: NSViewRepresentable {
    var tracks: [SpotifyManager.Track]
    @Binding var selection: Set<SpotifyManager.Track.ID>
    @Binding var sortOrder: [KeyPathComparator<SpotifyManager.Track>]
    @Binding var selectedTrack: SpotifyManager.Track?
    @Binding var showDeleteConfirmation: Bool
    let playlist: SpotifyManager.Playlist?
    let spotifyManager: SpotifyManager
    /// Drag-to-reorder is only valid in playlist order (editable, not sorted, not filtered).
    let canReorder: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = TrackNSTableView()
        tableView.coordinator = context.coordinator
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 36
        tableView.style = .inset
        tableView.headerView = NSTableHeaderView()
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.tableDoubleClicked(_:))
        // .move for internal reorder, .copy for dropping onto a sidebar playlist (both local).
        tableView.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)

        for column in TrackColumn.allCases {
            let tableColumn = NSTableColumn(identifier: column.id)
            column.applyHeader(to: tableColumn)  // ATTR-3
            tableColumn.width = column.width
            tableColumn.minWidth = column.minWidth
            if column.comparator(ascending: true) != nil {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            }
            tableView.addTableColumn(tableColumn)
        }

        // Accept internal drops so rows can be reordered by dragging.
        tableView.registerForDraggedTypes([trackPasteboardType])
        tableView.draggingDestinationFeedbackStyle = .gap

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        context.coordinator.tableView = tableView
        context.coordinator.apply(tracks: tracks)
        context.coordinator.applySelection(selection)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(tracks: tracks)
        context.coordinator.applySelection(selection)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: TrackTableRepresentable
        weak var tableView: NSTableView?
        private var tracks: [SpotifyManager.Track] = []
        private var isProgrammaticSelection = false

        init(_ parent: TrackTableRepresentable) {
            self.parent = parent
        }

        /// PERF-2: reload only the rows that changed (e.g. one like) rather than the whole table.
        func apply(tracks newTracks: [SpotifyManager.Track]) {
            guard let tableView = tableView else { tracks = newTracks; return }
            if tracks.map(\.id) != newTracks.map(\.id) {
                tracks = newTracks
                tableView.reloadData()   // structure changed (add/remove/reorder/switch)
                return
            }
            var changed = IndexSet()
            for (index, pair) in zip(tracks, newTracks).enumerated() where pair.0 != pair.1 {
                changed.insert(index)
            }
            tracks = newTracks
            guard !changed.isEmpty else { return }
            tableView.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(0..<tableView.numberOfColumns))
        }

        func applySelection(_ ids: Set<SpotifyManager.Track.ID>) {
            guard let tableView = tableView else { return }
            let indexes = IndexSet(tracks.enumerated().compactMap { ids.contains($0.element.id) ? $0.offset : nil })
            guard indexes != tableView.selectedRowIndexes else { return }
            isProgrammaticSelection = true
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            isProgrammaticSelection = false
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { tracks.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn = tableColumn,
                  let column = TrackColumn(rawValue: tableColumn.identifier.rawValue),
                  row < tracks.count else { return nil }
            let track = tracks[row]

            switch column {
            case .artwork:
                let cell = (tableView.makeView(withIdentifier: column.id, owner: nil) as? ArtworkCellView)
                    ?? ArtworkCellView(identifier: column.id)
                cell.configure(urlString: track.albumArtURL)
                return cell
            case .liked:
                let cell = (tableView.makeView(withIdentifier: column.id, owner: nil) as? LikeCellView)
                    ?? LikeCellView(identifier: column.id)
                cell.configure(isLiked: track.isLiked) { [weak self] in self?.toggleLike(track) }
                return cell
            default:
                let cell = (tableView.makeView(withIdentifier: column.id, owner: nil) as? TrackTextCellView)
                    ?? TrackTextCellView(identifier: column.id, monospacedDigits: column == .duration)
                cell.textField?.stringValue = column.text(for: track)
                return cell
            }
        }

        // MARK: Selection

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isProgrammaticSelection, let tableView = tableView else { return }
            let rows = tableView.selectedRowIndexes
            let ids = Set(rows.compactMap { $0 < tracks.count ? tracks[$0].id : nil })
            parent.selection = ids
            if rows.count == 1, let row = rows.first, row < tracks.count {
                parent.selectedTrack = tracks[row]
            } else if ids.isEmpty {
                parent.selectedTrack = nil
            }
        }

        // MARK: Sorting (header clicks). Parent re-sorts displayTracks; we only translate.

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key,
                  let column = TrackColumn(rawValue: key),
                  let comparator = column.comparator(ascending: descriptor.ascending) else {
                parent.sortOrder = []
                return
            }
            parent.sortOrder = [comparator]
        }

        // MARK: Drag out (one item per row; the drop side collects all providers)

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row < tracks.count, let data = try? JSONEncoder().encode(tracks[row]) else { return nil }
            let item = NSPasteboardItem()
            item.setData(data, forType: trackPasteboardType)
            return item
        }

        // MARK: Drag-to-reorder (internal drops; dragging OUT to a sidebar playlist is handled there)

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            // Only reorder for drags that originate from THIS table, and only in playlist order.
            guard parent.canReorder, (info.draggingSource as? NSTableView) === tableView else { return [] }
            if dropOperation == .on {
                tableView.setDropRow(row, dropOperation: .above)
            }
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard parent.canReorder, let playlist = parent.playlist else { return false }
            let items = info.draggingPasteboard.pasteboardItems ?? []
            let draggedIDs: [String] = items.compactMap { item in
                guard let data = item.data(forType: trackPasteboardType),
                      let track = try? JSONDecoder().decode(SpotifyManager.Track.self, from: data) else { return nil }
                return track.id
            }
            let sourceIndexes = IndexSet(draggedIDs.compactMap { id in tracks.firstIndex(where: { $0.id == id }) })
            guard !sourceIndexes.isEmpty else { return false }
            Task {
                await parent.spotifyManager.reorderTracks(in: playlist.id, from: sourceIndexes, to: row)
            }
            return true
        }

        // MARK: Actions

        @objc func tableDoubleClicked(_ sender: Any?) {
            guard let tableView = tableView else { return }
            let row = tableView.clickedRow
            guard row >= 0, row < tracks.count else { return }
            parent.selectedTrack = tracks[row]
        }

        private func toggleLike(_ track: SpotifyManager.Track) {
            Task {
                if track.isLiked {
                    _ = await parent.spotifyManager.unlikeTrack(track)
                } else {
                    _ = await parent.spotifyManager.likeTrack(track)
                }
            }
        }

        /// USE-2: ⌫ deletes the current selection (handled natively so the key reaches us).
        func handleDeleteKey() -> Bool {
            guard parent.playlist?.isEditable == true,
                  let tableView = tableView, !tableView.selectedRowIndexes.isEmpty else { return false }
            parent.showDeleteConfirmation = true
            return true
        }

        // MARK: Context menu

        func menu(forClickedRow row: Int) -> NSMenu? {
            guard row >= 0, row < tracks.count else { return nil }
            let selectedIDs = parent.selection.isEmpty ? [tracks[row].id] : parent.selection
            let selected = tracks.filter { selectedIDs.contains($0.id) }
            guard !selected.isEmpty else { return nil }

            let menu = NSMenu()
            let editable = parent.playlist?.isEditable ?? false

            let unliked = selected.filter { !$0.isLiked }
            let liked = selected.filter { $0.isLiked }
            if !unliked.isEmpty {
                addItem(menu, unliked.count == 1 ? "Add to Liked Songs" : "Like \(unliked.count) Tracks",
                        #selector(menuLike(_:)), unliked)
            }
            if !liked.isEmpty {
                addItem(menu, liked.count == 1 ? "Remove from Liked Songs" : "Unlike \(liked.count) Tracks",
                        #selector(menuUnlike(_:)), liked)
            }

            if editable {
                if parent.sortOrder.isEmpty, selected.count == 1 {
                    menu.addItem(.separator())
                    addMove(menu, "Move to Top", selected[0], .top)
                    addMove(menu, "Move Up", selected[0], .upward)
                    addMove(menu, "Move Down", selected[0], .downward)
                    addMove(menu, "Move to Bottom", selected[0], .bottom)
                }
                menu.addItem(.separator())
                addItem(menu, selected.count == 1 ? "Delete" : "Delete \(selected.count) Tracks",
                        #selector(menuDelete(_:)), nil)
            }
            return menu.items.isEmpty ? nil : menu
        }

        private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector, _ payload: Any?) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = payload
            menu.addItem(item)
        }

        private func addMove(_ menu: NSMenu, _ title: String, _ track: SpotifyManager.Track, _ dest: MoveDest) {
            addItem(menu, title, #selector(menuMove(_:)), MoveCommand(track: track, dest: dest))
        }

        @objc private func menuLike(_ sender: NSMenuItem) {
            guard let tracks = sender.representedObject as? [SpotifyManager.Track] else { return }
            Task { _ = await parent.spotifyManager.bulkLikeTracks(tracks) }
        }

        @objc private func menuUnlike(_ sender: NSMenuItem) {
            guard let tracks = sender.representedObject as? [SpotifyManager.Track] else { return }
            Task { _ = await parent.spotifyManager.bulkUnlikeTracks(tracks) }
        }

        @objc private func menuDelete(_ sender: NSMenuItem) {
            parent.showDeleteConfirmation = true
        }

        @objc private func menuMove(_ sender: NSMenuItem) {
            guard let command = sender.representedObject as? MoveCommand,
                  let playlist = parent.playlist else { return }
            let allTracks = parent.spotifyManager.currentPlaylistTracks
            guard let index = allTracks.firstIndex(where: { $0.id == command.track.id }) else { return }
            let count = allTracks.count
            let destination: Int
            switch command.dest {
            case .top: destination = 0
            case .upward: destination = max(0, index - 1)
            case .downward: destination = min(count, index + 2)
            case .bottom: destination = count
            }
            Task {
                await parent.spotifyManager.reorderTracks(
                    in: playlist.id, from: IndexSet(integer: index), to: destination
                )
            }
        }
    }
}
#endif
