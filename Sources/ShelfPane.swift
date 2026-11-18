import AppKit

/// Shelf page: files dropped on the dock ball (or onto this page). Drag a row
/// out to copy the file somewhere else; double-click opens it.
final class ShelfPane: NSView, DockPage {
    private let titleLabel = NSTextField(labelWithString: "Shelf")
    private let countLabel = NSTextField(labelWithString: "")
    private let clearButton = NSButton(title: "Clear All", target: nil, action: nil)
    private let rows = NSStackView()
    private let scroll = NSScrollView()
    private let empty = NSStackView()
    private let emptyText = NSTextField(wrappingLabelWithString: "")
    private var dropping = false {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 380))
        wantsLayer = true
        registerForDraggedTypes([.fileURL])

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = NSColor(white: 1, alpha: 0.5)
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.target = self
        clearButton.action = #selector(clearAll)
        let header = NSStackView(views: [titleLabel, countLabel, NSView(), clearButton])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        rows.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.verticalScroller = SlimScroller()
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true

        let icon = NSImageView(image: NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 30, weight: .light)
        icon.contentTintColor = NSColor(srgbRed: 0.45, green: 0.85, blue: 1.0, alpha: 0.9)
        emptyText.font = .systemFont(ofSize: 12.5)
        emptyText.textColor = NSColor(white: 1, alpha: 0.6)
        emptyText.alignment = .center
        emptyText.preferredMaxLayoutWidth = 300
        empty.orientation = .vertical
        empty.alignment = .centerX
        empty.spacing = 10
        empty.addArrangedSubview(icon)
        empty.addArrangedSubview(emptyText)

        for view in [header, scroll, empty] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            rows.topAnchor.constraint(equalTo: document.topAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -2),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 14)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: ShelfStore.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .settingsChanged, object: nil)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func preferredSize(horizontal: Bool) -> NSSize { NSSize(width: 520, height: 380) }
    func pageWillAppear() { reload() }

    @objc private func reload() {
        let store = ShelfStore.shared
        for view in rows.arrangedSubviews {
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for item in store.items {
            let row = ShelfRowView(item: item)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        let total = store.items.reduce(Int64(0)) { $0 + $1.size }
        countLabel.stringValue = store.items.isEmpty ? ""
            : "\(store.items.count) item\(store.items.count == 1 ? "" : "s") · "
                + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        clearButton.isHidden = store.items.isEmpty
        let days = ShelfStore.retentionDays
        emptyText.stringValue = "Drop files on the dock ball (or here).\nThey stay \(days) day\(days == 1 ? "" : "s"), then are cleared."
        empty.isHidden = !store.items.isEmpty
        scroll.isHidden = store.items.isEmpty
    }

    @objc private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "Clear the Shelf?"
        alert.informativeText = "All \(ShelfStore.shared.items.count) items are deleted from the Shelf."
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ShelfStore.shared.removeAll()
    }

    // MARK: Dropping onto the page

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !Self.fileURLs(sender).isEmpty, !ShelfRowView.isDraggingOut else { return [] }
        dropping = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropping = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropping = false
        let urls = Self.fileURLs(sender)
        guard !urls.isEmpty else { return false }
        ShelfPane.add(urls)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard dropping else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor(srgbRed: 0.45, green: 0.85, blue: 1.0, alpha: 0.9).setStroke()
        path.stroke()
    }

    static func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// Adds files and says what happened.
    static func add(_ urls: [URL]) {
        ShelfStore.shared.add(urls) { added, failed in
            if failed.isEmpty {
                Toast.show(added == 1 ? "Added to Shelf" : "Added \(added) to Shelf")
            } else {
                Toast.show("Could not add: " + failed.joined(separator: ", "), duration: 2.5)
            }
        }
    }

    /// Test hooks.
    var debugRows: [String] { rows.arrangedSubviews.compactMap { ($0 as? ShelfRowView)?.debugText } }
    var debugEmptyShown: Bool { !empty.isHidden }
}

/// One Shelf item: icon, name, size · added · time left. Drag it out to
/// copy the file; double-click opens it; right-click for more.
final class ShelfRowView: NSView, NSDraggingSource {
    /// True while a row is being dragged (the page must not take it back).
    static var isDraggingOut = false

    private let item: ShelfItem
    private let detail = NSTextField(labelWithString: "")
    private let actions = NSStackView()
    private var tracking: NSTrackingArea?
    private var downAt: NSPoint?

    init(item: ShelfItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let url = ShelfStore.shared.url(of: item)
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
        icon.imageScaling = .scaleProportionallyUpOrDown
        let name = NSTextField(labelWithString: item.name)
        name.font = .systemFont(ofSize: 12.5, weight: .medium)
        name.textColor = .white
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = .systemFont(ofSize: 10.5)
        detail.textColor = NSColor(white: 1, alpha: 0.5)
        detail.stringValue = Self.detailText(item)
        let texts = NSStackView(views: [name, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1

        let reveal = Self.iconButton("magnifyingglass", "Show in Finder", self, #selector(revealTapped))
        let remove = Self.iconButton("xmark", "Remove from Shelf", self, #selector(removeTapped))
        actions.orientation = .horizontal
        actions.spacing = 2
        actions.addArrangedSubview(reveal)
        actions.addArrangedSubview(remove)
        actions.alphaValue = 0

        for view in [icon, texts, actions] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 42),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            texts.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -8),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        toolTip = item.name + "\nDouble-click to open · drag out to copy"
        menu = makeMenu()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var debugText: String { "\(item.name) | \(detail.stringValue)" }

    static func detailText(_ item: ShelfItem, now: Date = Date()) -> String {
        let size = item.isDirectory ? "Folder · " + ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
            : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        let added = Calendar.current.isDateInToday(item.addedAt)
            ? item.addedAt.formatted(date: .omitted, time: .shortened)
            : item.addedAt.formatted(.dateTime.month(.abbreviated).day())
        let left = ShelfStore.shared.expiry(of: item).timeIntervalSince(now)
        let leftText: String
        if left < 3600 { leftText = "clears soon" }
        else if left < 86_400 { leftText = "\(Int((left / 3600).rounded(.up)))h left" }
        else { leftText = "\(Int((left / 86_400).rounded(.up)))d left" }
        return "\(size) · Added \(added) · \(leftText)"
    }

    private static func iconButton(_ symbol: String, _ tip: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
                              target: target, action: action)
        button.isBordered = false
        button.toolTip = tip
        button.contentTintColor = NSColor(white: 1, alpha: 0.75)
        button.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(openTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show in Finder", action: #selector(revealTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy", action: #selector(copyTapped), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Remove from Shelf", action: #selector(removeTapped), keyEquivalent: "").target = self
        return menu
    }

    private var fileURL: URL { ShelfStore.shared.url(of: item) }

    @objc private func openTapped() { NSWorkspace.shared.open(fileURL) }
    @objc private func revealTapped() { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
    @objc private func copyTapped() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([fileURL as NSURL])
        Toast.show("Copied")
    }
    @objc private func removeTapped() { ShelfStore.shared.remove(item.id) }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        actions.alphaValue = 1
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.11).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        actions.alphaValue = 0
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
    }

    // MARK: Open / drag out

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { openTapped(); return }
        downAt = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt else { return }
        let moved = hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y)
        guard moved > 4 else { return }
        downAt = nil
        let dragItem = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        let image = NSWorkspace.shared.icon(forFile: fileURL.path)
        let point = convert(event.locationInWindow, from: nil)
        dragItem.setDraggingFrame(NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32), contents: image)
        Self.isDraggingOut = true
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        Self.isDraggingOut = false
    }
}
