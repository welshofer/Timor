//
//  TrackTableCells.swift
//  Timor
//
//  Native AppKit cell views for the NSTableView-backed track list. Using real NSView cells
//  (not hosted SwiftUI) is what gives native cell reuse and smooth scrolling.
//

#if os(macOS)
import AppKit

/// Album-art thumbnail cell. Reads the cached downsampled thumbnail synchronously when
/// available (instant for recycled rows) and otherwise loads it off the main thread.
final class ArtworkCellView: NSTableCellView {
    private let art = NSImageView()
    private var loadTask: Task<Void, Never>?
    private var currentURL: String?

    private static let placeholder = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        art.translatesAutoresizingMaskIntoConstraints = false
        art.imageScaling = .scaleProportionallyUpOrDown
        art.wantsLayer = true
        art.layer?.cornerRadius = 4
        art.layer?.masksToBounds = true
        addSubview(art)
        NSLayoutConstraint.activate([
            art.widthAnchor.constraint(equalToConstant: 32),
            art.heightAnchor.constraint(equalToConstant: 32),
            art.centerYAnchor.constraint(equalTo: centerYAnchor),
            art.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(urlString: String?) {
        loadTask?.cancel()
        currentURL = urlString

        guard let urlString = urlString, !urlString.isEmpty else {
            art.image = Self.placeholder
            return
        }
        // Instant for recycled rows: memory-only lookup, no IO.
        if let cached = ImageCache.shared.cachedThumbnail(for: urlString, maxPixel: 96) {
            art.image = cached
            return
        }
        art.image = Self.placeholder
        loadTask = Task { [weak self] in
            let image = await ImageCache.shared.thumbnail(for: urlString, maxPixel: 96)
            guard let self = self, self.currentURL == urlString else { return }
            self.art.image = image ?? Self.placeholder
        }
    }
}

/// Like/unlike heart cell.
final class LikeCellView: NSTableCellView {
    private let button = NSButton()
    private var onToggle: (() -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryChange)
        button.target = self
        button.action = #selector(clicked)
        addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(isLiked: Bool, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        button.image = NSImage(systemSymbolName: isLiked ? "heart.fill" : "heart",
                               accessibilityDescription: isLiked ? "Liked" : "Not liked")
        button.contentTintColor = isLiked ? .systemRed : .secondaryLabelColor
        button.toolTip = isLiked ? "Remove from Liked Songs" : "Add to Liked Songs"
    }

    @objc private func clicked() {
        onToggle?()
    }
}

/// Simple reusable text cell (title/artist/album/date/duration).
final class TrackTextCellView: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier, monospacedDigits: Bool) {
        super.init(frame: .zero)
        self.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        if monospacedDigits {
            field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// NSTableView subclass that routes right-click into the coordinator's menu builder and
/// handles the ⌫ delete key.
final class TrackNSTableView: NSTableView {
    weak var coordinator: TrackTableRepresentable.Coordinator?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return coordinator?.menu(forClickedRow: row)
    }

    override func keyDown(with event: NSEvent) {
        // 51 = Delete/Backspace, 117 = forward delete.
        if event.keyCode == 51 || event.keyCode == 117, coordinator?.handleDeleteKey() == true {
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Context-menu move commands (used by the table coordinator)

enum MoveDest { case top, upward, downward, bottom }

final class MoveCommand: NSObject {
    let track: SpotifyManager.Track
    let dest: MoveDest
    init(track: SpotifyManager.Track, dest: MoveDest) {
        self.track = track
        self.dest = dest
    }
}
#endif
