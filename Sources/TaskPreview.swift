import AppKit

/// One to-do in full, beside the card's Home: the whole title, when it is
/// due and the complete note, with Edit (opens it in the Agenda) and Mark
/// done. A click on a Home row shows it; a second click, another row, or
/// the card folding closes or moves it.
///
/// A non-activating panel like the card itself (a popover would close at
/// once while OmniHub is not the active app), riding as the card's child.
final class TaskPreview: NSObject {
    /// Edit: the to-do to open in the Agenda.
    var onEdit: ((UUID) -> Void)?
    /// The to-do shown, or nil once closed.
    var onChange: ((UUID?) -> Void)?
    /// The to-do shown (headless: the one that would be).
    private(set) var taskID: UUID?

    private static let width: CGFloat = 300
    private static let inset: CGFloat = 14
    private static let gap: CGFloat = 8
    private static let noteLine: CGFloat = 16
    private static let maxNoteHeight: CGFloat = noteLine * 14

    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let surface = NSVisualEffectView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let whenLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let noteScroll = NSScrollView()
    private let noteHeight: NSLayoutConstraint
    private let content = NSStackView()
    private var lastUsed: CGFloat = 0

    override init() {
        noteHeight = noteScroll.heightAnchor.constraint(equalToConstant: 16)
        super.init()
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.appearance = NSAppearance(named: .darkAqua)
        surface.material = .hudWindow
        surface.blendingMode = .behindWindow
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 12
        surface.layer?.masksToBounds = true
        surface.layer?.borderWidth = 1
        surface.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        panel.contentView = surface
        _ = buildContent()
        place(content, in: surface)
    }

    private func place(_ view: NSView, in host: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
    }

    var isShown: Bool { panel.isVisible }
    /// The pointer is over the preview (the card stays open meanwhile).
    func contains(_ point: NSPoint) -> Bool {
        panel.isVisible && panel.frame.insetBy(dx: -Self.gap - 2, dy: -6).contains(point)
    }
    var hasKeyboard: Bool { panel.isVisible && panel.isKeyWindow }
    var debugFrame: String { panel.isVisible ? NSStringFromRect(panel.frame) : "-" }

    /// Shows `task` beside the card (`card`, in screen coordinates), level
    /// with its row (`row`).
    func show(_ task: TaskItem, row: NSView, card: NSRect) {
        fill(task)
        taskID = task.id
        onChange?(task.id)
        guard let parent = row.window, parent.isVisible else { return }
        let size = content.fittingSize
        let rowRect = parent.convertToScreen(row.convert(row.bounds, to: nil))
        let screen = (parent.screen ?? NSScreen.main)?.visibleFrame ?? card
        var x = card.maxX + Self.gap
        if x + size.width > screen.maxX - 4 { x = card.minX - Self.gap - size.width }
        x = min(max(x, screen.minX + 4), screen.maxX - size.width - 4)
        var y = rowRect.maxY + 10 - size.height
        y = min(max(y, screen.minY + 4), screen.maxY - size.height - 4)
        panel.level = parent.level
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func close() {
        let wasShowing = taskID != nil
        taskID = nil
        if let parent = panel.parent { parent.removeChildWindow(panel) }
        panel.orderOut(nil)
        if wasShowing { onChange?(nil) }
    }

    // MARK: Content

    private func buildContent() -> NSView {
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.isSelectable = true
        titleLabel.preferredMaxLayoutWidth = Self.width - Self.inset * 2
        whenLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)

        noteLabel.isSelectable = true
        noteLabel.preferredMaxLayoutWidth = Self.width - Self.inset * 2
        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(noteLabel)
        noteScroll.documentView = document
        noteScroll.drawsBackground = false
        noteScroll.hasVerticalScroller = true
        noteScroll.autohidesScrollers = true
        noteScroll.scrollerStyle = .overlay
        noteScroll.translatesAutoresizingMaskIntoConstraints = false

        let markDone = NSButton(title: L("Mark done"), target: self, action: #selector(markDone))
        let edit = NSButton(title: L("Edit"), target: self, action: #selector(edit))
        for button in [markDone, edit] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        let gap = NSView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [gap, markDone, edit])
        buttons.spacing = 8

        for view in [titleLabel, whenLabel, noteScroll, buttons] as [NSView] { content.addArrangedSubview(view) }
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.setCustomSpacing(12, after: noteScroll)
        content.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset - 2, right: Self.inset)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.width),
            noteHeight,
            noteScroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -Self.inset * 2),
            document.topAnchor.constraint(equalTo: noteScroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: noteScroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: noteScroll.contentView.trailingAnchor),
            noteLabel.topAnchor.constraint(equalTo: document.topAnchor),
            noteLabel.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            noteLabel.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            noteLabel.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -Self.inset * 2)
        ])
        return content
    }

    private func fill(_ task: TaskItem) {
        titleLabel.stringValue = task.title
        if let due = task.due {
            let formatter = DateFormatter()
            formatter.locale = AppLanguage.current.locale
            formatter.setLocalizedDateFormatFromTemplate("MMMdEEEHHmm")
            let overdue = due < Date()
            whenLabel.stringValue = formatter.string(from: due) + (overdue ? " · " + L("Overdue") : "")
            whenLabel.textColor = overdue ? .systemRed : NSColor(white: 1, alpha: 0.55)
        } else {
            whenLabel.stringValue = L("No date")
            whenLabel.textColor = NSColor(white: 1, alpha: 0.55)
        }
        // A fixed line height: Chinese and Latin lines alike, so the
        // measured height is the drawn one.
        let lines = NSMutableParagraphStyle()
        lines.minimumLineHeight = Self.noteLine
        lines.maximumLineHeight = Self.noteLine
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12),
                                                         .foregroundColor: NSColor(white: 1, alpha: 0.78),
                                                         .paragraphStyle: lines]
        noteLabel.attributedStringValue = NSAttributedString(string: task.note, attributes: attributes)
        noteScroll.isHidden = task.note.isEmpty
        // The note in full, scrolling once it is taller than the limit.
        let used = ceil(noteLabel.fittingSize.height)
        noteHeight.constant = min(max(used, Self.noteLine), Self.maxNoteHeight)
        lastUsed = used
        noteScroll.contentView.scroll(to: .zero)
        content.layoutSubtreeIfNeeded()
    }

    @objc private func markDone() {
        guard let id = taskID else { return }
        close()
        TaskStore.shared.complete(id)
    }

    @objc private func edit() {
        guard let id = taskID else { return }
        close()
        onEdit?(id)
    }

    // MARK: Test hooks

    var debugText: String {
        "title=\(titleLabel.stringValue) when=\(whenLabel.stringValue) note=\(noteScroll.isHidden ? "-" : noteLabel.stringValue) "
            + "noteHeight=\(Int(noteHeight.constant)) used=\(Int(lastUsed))"
    }
    func debugEdit() { edit() }
    func debugMarkDone() { markDone() }

    /// Renders the preview on a dark backing in an off-screen window (a
    /// view drawn outside a window ignores the dark appearance).
    func debugSnapshot(to url: URL) {
        let size = content.fittingSize
        let backing = DarkBacking(frame: NSRect(origin: .zero, size: size))
        let window = NSWindow(contentRect: backing.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = backing
        content.translatesAutoresizingMaskIntoConstraints = true
        content.frame = backing.bounds
        backing.addSubview(content)
        backing.layoutSubtreeIfNeeded()
        if let rep = backing.bitmapImageRepForCachingDisplay(in: backing.bounds) {
            backing.cacheDisplay(in: backing.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        content.removeFromSuperview()
        window.contentView = nil
        place(content, in: surface)
    }

    private final class DarkBacking: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor(white: 0.17, alpha: 1).setFill()
            dirtyRect.fill()
        }
    }
}

extension NSTextField {
    /// One line that ends in "…" when it does not fit, and gives way to
    /// the views beside it.
    func makeSingleLine() {
        usesSingleLineMode = true
        maximumNumberOfLines = 1
        cell?.wraps = false
        cell?.truncatesLastVisibleLine = true
        lineBreakMode = .byTruncatingTail
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
}

/// Test hook: labels drawn past their row, under the time beside them,
/// or taller than one line.
enum LabelClash {
    static func find(in row: NSView, labels: [NSTextField], beside: NSView?) -> [String] {
        row.layoutSubtreeIfNeeded()
        let other = beside.map { $0.convert($0.bounds, to: row) }
        return labels.compactMap { label in
            guard !label.isHidden, !label.stringValue.isEmpty else { return nil }
            let frame = label.convert(label.bounds, to: row)
            let line = ceil((label.font?.ascender ?? 0) - (label.font?.descender ?? 0) + (label.font?.leading ?? 0))
            var problems: [String] = []
            if !row.bounds.contains(frame) { problems.append("outside the row") }
            if let other, frame.intersects(other) { problems.append("under the time") }
            if frame.height > line + 4 { problems.append("\(Int(frame.height)) high") }
            return problems.isEmpty ? nil
                : "\(label.stringValue.prefix(12))…: " + problems.joined(separator: ", ") + " \(NSStringFromRect(frame.integral)) in \(NSStringFromRect(row.bounds.integral))"
        }
    }
}
