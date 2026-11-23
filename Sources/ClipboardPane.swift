import AppKit

/// A page of the dock card (see FloatingDockPanel).
protocol DockPage: NSView {
    /// Size of the page inside the card.
    func preferredSize(horizontal: Bool) -> NSSize
    func pageWillAppear()
    func pageDidDisappear()
    /// The view that should get the keyboard when the page opens by hotkey
    /// or click.
    var initialResponder: NSView? { get }
    /// Esc: return true when the page used it itself (closed a sheet…).
    func handleEscape() -> Bool
}

extension DockPage {
    func pageWillAppear() {}
    func pageDidDisappear() {}
    var initialResponder: NSView? { nil }
    func handleEscape() -> Bool { false }
}

/// Clipboard page: filter the history, star favourites, reorder them by
/// dragging, and put an entry back on the pasteboard. Double-click (or
/// Return) copies the entry and closes the card — nothing is pasted for you.
final class ClipboardPane: NSView, DockPage {
    private let searchField = NSSearchField()
    private let segmented = NSSegmentedControl(labels: [L("All"), L("Starred")],
                                               trackingMode: .selectOne,
                                               target: nil,
                                               action: nil)
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var results: [ClipItem] = []
    private var favouritesOnly = false

    init() {
        super.init(frame: .zero)
        buildContent()
        // New copies show up while the page is open.
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged),
                                               name: .clipboardChanged, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func preferredSize(horizontal: Bool) -> NSSize { NSSize(width: 560, height: 400) }
    var initialResponder: NSView? { searchField }

    func pageWillAppear() {
        searchField.stringValue = ""
        reload(query: "")
    }

    /// Opens on the Starred tab (verification runs).
    func showFavourites() {
        segmented.selectedSegment = 1
        switchTab()
    }

    var debugState: String {
        "clipboard rows=\(results.count) tab=\(favouritesOnly ? "Starred" : "All") selected=\(tableView.selectedRow)"
    }

    /// Test hook: what a double-click on `row` does.
    func debugActivate(row: Int) {
        guard row < results.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        activateSelection()
    }

    @objc private func storeChanged() {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return }
        let fresh = ClipboardStore.shared.filtered(searchField.stringValue, favouritesOnly: favouritesOnly)
        // Our own edits already refreshed the list.
        if fresh.map(\.id) == results.map(\.id), fresh.map(\.pinned) == results.map(\.pinned) { return }
        let selected = tableView.selectedRow >= 0 && tableView.selectedRow < results.count
            ? results[tableView.selectedRow].id : nil
        results = fresh
        tableView.reloadData()
        if let selected, let index = results.firstIndex(where: { $0.id == selected }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if !results.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    /// Return when the list (not the search field) has focus.
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: activateSelection()
        default: super.keyDown(with: event)
        }
    }

    /// Row buttons. The list keeps its scroll position and selection.
    private func toggleFavourite(_ id: UUID) {
        let selected = tableView.selectedRow
        ClipboardStore.shared.togglePin(id)
        reloadKeepingSelection(near: selected)
    }

    private func delete(_ id: UUID) {
        let selected = tableView.selectedRow
        ClipboardStore.shared.remove(id)
        reloadKeepingSelection(near: selected)
    }

    private func reloadKeepingSelection(near row: Int) {
        results = ClipboardStore.shared.filtered(searchField.stringValue, favouritesOnly: favouritesOnly)
        tableView.reloadData()
        if !results.isEmpty {
            let next = min(max(row, 0), results.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        }
    }

    private func buildContent() {
        segmented.selectedSegment = 0
        segmented.target = self
        segmented.action = #selector(switchTab)
        segmented.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = L("Search clipboard history…")
        searchField.font = .systemFont(ofSize: 13)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        tableView.headerView = nil
        tableView.rowHeight = 44
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(activateSelection)
        tableView.registerForDraggedTypes([.string])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        for view in [segmented, searchField, scrollView] { addSubview(view) }

        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            segmented.leadingAnchor.constraint(equalTo: leadingAnchor),

            searchField.centerYAnchor.constraint(equalTo: segmented.centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: segmented.trailingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @objc private func switchTab() {
        favouritesOnly = segmented.selectedSegment == 1
        reload(query: searchField.stringValue)
    }

    private func reload(query: String) {
        results = ClipboardStore.shared.filtered(query, favouritesOnly: favouritesOnly)
        tableView.reloadData()
        if !results.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    /// Copies the entry and closes the card. Pasting is left to the user.
    @objc private func activateSelection() {
        let row = tableView.selectedRow
        guard row >= 0, row < results.count else { return }
        guard ClipboardStore.shared.restore(results[row]) else { return }
        FloatingDockPanel.closeCard()
        Toast.show("Copied")
    }

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let current = max(tableView.selectedRow, 0)
        let next = min(max(current + delta, 0), results.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }
}

extension ClipboardPane: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        reload(query: searchField.stringValue)
    }

    func control(_ control: NSControl,
                 textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            activateSelection(); return true
        default:
            return false
        }
    }
}

extension ClipboardPane: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ClipCell")
        let cell: ClipCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? ClipCellView {
            cell = reused
        } else {
            cell = ClipCellView()
            cell.identifier = identifier
        }
        let item = results[row]
        cell.configure(with: item)
        cell.onToggleFavourite = { [weak self] in self?.toggleFavourite(item.id) }
        cell.onDelete = { [weak self] in self?.delete(item.id) }
        return cell
    }

    // Drag reorder inside the Starred tab only.
    func tableView(_ tableView: NSTableView,
                   pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard favouritesOnly, row < results.count else { return nil }
        return results[row].id.uuidString as NSString
    }

    func tableView(_ tableView: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard favouritesOnly, dropOperation == .above else { return [] }
        return .move
    }

    func tableView(_ tableView: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard favouritesOnly,
              let raw = info.draggingPasteboard.string(forType: .string),
              let uuid = UUID(uuidString: raw),
              let source = ClipboardStore.shared.pinnedItems.firstIndex(where: { $0.id == uuid })
        else { return false }
        ClipboardStore.shared.movePinned(from: source, to: row)
        reload(query: searchField.stringValue)
        return true
    }
}

// MARK: - Cell

final class ClipCellView: NSTableCellView {
    var onToggleFavourite: (() -> Void)?
    var onDelete: (() -> Void)?

    private let thumb = NSImageView()
    private let primary = NSTextField(labelWithString: "")
    private let secondary = NSTextField(labelWithString: "")
    private let starButton = NSButton()
    private let deleteButton = NSButton()

    init() {
        super.init(frame: .zero)
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 4
        thumb.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        thumb.translatesAutoresizingMaskIntoConstraints = false

        primary.font = .systemFont(ofSize: 13)
        primary.lineBreakMode = .byTruncatingTail
        primary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        primary.translatesAutoresizingMaskIntoConstraints = false

        secondary.font = .systemFont(ofSize: 10)
        secondary.textColor = .tertiaryLabelColor
        secondary.translatesAutoresizingMaskIntoConstraints = false

        for (button, action) in [(starButton, #selector(starTapped)), (deleteButton, #selector(deleteTapped))] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.target = self
            button.action = action
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: L("Delete"))
        deleteButton.contentTintColor = .secondaryLabelColor
        deleteButton.toolTip = L("Delete")

        for view in [thumb, primary, secondary, starButton, deleteButton] { addSubview(view) }

        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 32),
            thumb.heightAnchor.constraint(equalToConstant: 32),

            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            starButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -4),
            starButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            primary.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 10),
            primary.trailingAnchor.constraint(lessThanOrEqualTo: starButton.leadingAnchor, constant: -10),
            primary.topAnchor.constraint(equalTo: topAnchor, constant: 7),

            secondary.leadingAnchor.constraint(equalTo: primary.leadingAnchor),
            secondary.topAnchor.constraint(equalTo: primary.bottomAnchor, constant: 1)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func starTapped() { onToggleFavourite?() }
    @objc private func deleteTapped() { onDelete?() }

    func configure(with item: ClipItem) {
        if let image = item.image {
            thumb.image = image
            primary.stringValue = L("Image %ld × %ld", Int(image.size.width), Int(image.size.height))
        } else {
            thumb.image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil)
            primary.stringValue = (item.text ?? "").replacingOccurrences(of: "\n", with: " ⏎ ")
        }
        // Filled yellow star = favourite (click to remove); outline = not yet.
        starButton.image = NSImage(systemSymbolName: item.pinned ? "star.fill" : "star",
                                   accessibilityDescription: item.pinned ? L("Unstar") : L("Starred"))
        starButton.contentTintColor = item.pinned ? .systemYellow : .secondaryLabelColor
        starButton.toolTip = item.pinned ? L("Unstar") : L("Starred")
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(item.date) ? "HH:mm:ss" : "MM-dd HH:mm"
        secondary.stringValue = formatter.string(from: item.date)
    }
}
