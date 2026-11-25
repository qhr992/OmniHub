import AppKit

/// Settings' first view: every topic as a row of one list. A row shows the
/// topic's name and the groups inside it; clicking it (or Return / Space)
/// opens it, ↑ / ↓ move between rows.
final class SettingsOverview: NSView {
    struct Topic {
        let title: String       // English: the key into Localizable.strings
        let symbol: String
        let tint: NSColor
        let detail: String      // already localised
    }

    static let maxWidth: CGFloat = 720
    var onPick: ((Int) -> Void)?
    private(set) var rows: [SettingsTopicRow] = []

    init(topics: [Topic]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let group = NSStackView()
        group.orientation = .vertical
        group.spacing = 0
        group.wantsLayer = true
        group.layer?.cornerRadius = 14
        group.layer?.backgroundColor = NSColor(white: 1, alpha: 0.045).cgColor
        group.layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        group.layer?.borderWidth = 1
        group.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        group.translatesAutoresizingMaskIntoConstraints = false
        rows = topics.enumerated().map { index, topic in
            let row = SettingsTopicRow(topic)
            row.onPick = { [weak self] in self?.onPick?(index) }
            row.onArrow = { [weak self] step in self?.move(from: index, by: step) }
            return row
        }
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let rule = Hairline()
                group.addArrangedSubview(rule)
                rule.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 54).isActive = true
                rule.trailingAnchor.constraint(equalTo: group.trailingAnchor, constant: -16).isActive = true
            }
            group.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 6).isActive = true
            row.trailingAnchor.constraint(equalTo: group.trailingAnchor, constant: -6).isActive = true
        }

        // Taller than the window: the list scrolls.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(group)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let clip = scroll.contentView
        let wide = group.widthAnchor.constraint(equalTo: document.widthAnchor)
        wide.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            group.topAnchor.constraint(equalTo: document.topAnchor),
            group.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            group.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
            group.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth),
            wide
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func move(from index: Int, by step: Int) {
        let next = index + step
        guard next >= 0, next < rows.count else { return }
        window?.makeFirstResponder(rows[next])
        rows[next].scrollToVisible(rows[next].bounds)
    }

    /// The rows fade down into place one after another (Reduce Motion: all at once).
    func animateIn() {
        for (index, row) in rows.enumerated() {
            let delay = MainWindowMotion.reduceMotion ? 0 : Double(index) * 0.02
            MainWindowMotion.arrive(row.layer, dx: 0, dy: -6, duration: MainWindowMotion.pageDuration, delay: delay)
        }
    }
}

/// A 1 pt rule between rows.
private final class Hairline: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// One topic in the overview list.
final class SettingsTopicRow: FocusButton {
    static let height: CGFloat = 52
    var onPick: (() -> Void)?
    var onArrow: ((Int) -> Void)?
    let topicTitle: String
    private let tint: NSColor
    private var hovering = false { didSet { if hovering != oldValue { restyle() } } }
    private var focused = false { didSet { if focused != oldValue { restyle() } } }

    init(_ topic: SettingsOverview.Topic) {
        topicTitle = topic.title
        tint = topic.tint
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 9
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityTitle(L(topic.title))
        setAccessibilityHelp(topic.detail)
        target = self
        action = #selector(fire)

        let badge = BadgeView(symbol: topic.symbol, tint: topic.tint, side: 26)
        let name = NSTextField(labelWithString: L(topic.title))
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.textColor = .white
        let detail = NSTextField(labelWithString: topic.detail)
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = NSColor(white: 1, alpha: 0.48)
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) ?? NSImage())
        chevron.contentTintColor = NSColor(white: 1, alpha: 0.3)
        for view in [badge, name, detail, chevron] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 26),
            badge.heightAnchor.constraint(equalToConstant: 26),
            name.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 12),
            name.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -12),
            name.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -12),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // The labels inside must not take the click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {}

    @objc private func fire() { onPick?() }

    private func restyle() {
        layer?.backgroundColor = NSColor(white: 1, alpha: focused ? 0.09 : hovering ? 0.06 : 0).cgColor
        layer?.borderColor = tint.withAlphaComponent(0.85).cgColor
        layer?.borderWidth = focused ? 1.5 : 0
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    // Pressed: the row dims for a moment (opacity only).
    override func mouseDown(with event: NSEvent) {
        layer?.opacity = 0.7
        super.mouseDown(with: event)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        layer?.opacity = 1
        CATransaction.commit()
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { focused = true }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { focused = false }
        return resigned
    }

    // Our own ring (the tinted border) instead of the system's.
    override var focusRingType: NSFocusRingType { get { .none } set {} }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: onArrow?(1)
        case 126: onArrow?(-1)
        default: super.keyDown(with: event)
        }
    }
}
