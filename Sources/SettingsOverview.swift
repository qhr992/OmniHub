import AppKit

/// Settings' first view: every topic as a card in a grid. A card shows the
/// topic's badge, its name and the groups inside it; clicking (or Return /
/// Space) opens it, the arrow keys move between cards.
final class SettingsOverview: NSView {
    struct Topic {
        let title: String       // English: the key into Localizable.strings
        let symbol: String
        let tint: NSColor
        let detail: String      // already localised
    }

    static let columns = 3
    var onPick: ((Int) -> Void)?
    private(set) var cards: [SettingsTopicCard] = []

    init(topics: [Topic]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.spacing = 14
        grid.translatesAutoresizingMaskIntoConstraints = false
        cards = topics.enumerated().map { index, topic in
            let card = SettingsTopicCard(topic)
            card.onPick = { [weak self] in self?.onPick?(index) }
            card.onArrow = { [weak self] dx, dy in self?.move(from: index, dx: dx, dy: dy) }
            return card
        }
        for start in stride(from: 0, to: cards.count, by: Self.columns) {
            var line: [NSView] = Array(cards[start..<min(start + Self.columns, cards.count)])
            while line.count < Self.columns { line.append(NSView()) }
            let row = NSStackView(views: line)
            row.distribution = .fillEqually
            row.spacing = 14
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func move(from index: Int, dx: Int, dy: Int) {
        let next = index + dx + dy * Self.columns
        guard next >= 0, next < cards.count, dx == 0 || next / Self.columns == index / Self.columns else { return }
        window?.makeFirstResponder(cards[next])
    }

    /// The cards fade up one after another (Reduce Motion: all at once).
    func animateIn() {
        for (index, card) in cards.enumerated() {
            let delay = MainWindowMotion.reduceMotion ? 0 : Double(index) * 0.025
            MainWindowMotion.arrive(card.layer, dx: 0, dy: -10, duration: MainWindowMotion.pageDuration + 0.06, delay: delay)
        }
    }
}

/// One topic on the overview.
final class SettingsTopicCard: FocusButton {
    static let height: CGFloat = 108
    var onPick: (() -> Void)?
    var onArrow: ((Int, Int) -> Void)?
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
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityTitle(L(topic.title))
        target = self
        action = #selector(fire)

        let badge = BadgeView(symbol: topic.symbol, tint: topic.tint, side: 34)
        let name = NSTextField(labelWithString: L(topic.title))
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.textColor = .white
        let detail = NSTextField(wrappingLabelWithString: topic.detail)
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = NSColor(white: 1, alpha: 0.5)
        detail.maximumNumberOfLines = 2
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
            // Room for the badge row and two lines of groups.
            heightAnchor.constraint(equalToConstant: Self.height),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            badge.widthAnchor.constraint(equalToConstant: 34),
            badge.heightAnchor.constraint(equalToConstant: 34),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            chevron.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            name.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 12),
            name.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
            detail.leadingAnchor.constraint(equalTo: badge.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            detail.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 12)
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
        let lit = hovering || focused
        layer?.backgroundColor = NSColor(white: 1, alpha: lit ? 0.085 : 0.045).cgColor
        layer?.borderColor = (focused ? tint.withAlphaComponent(0.85)
                              : hovering ? tint.withAlphaComponent(0.45) : NSColor(white: 1, alpha: 0.08)).cgColor
        layer?.borderWidth = focused ? 2 : 1
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    // Pressed: the card gives a little (transform only).
    override func mouseDown(with event: NSEvent) {
        press(true)
        super.mouseDown(with: event)
        press(false)
    }

    private func press(_ down: Bool) {
        guard let layer, !MainWindowMotion.reduceMotion else { return }
        let scale = down ? 0.975 : 1
        // Scale about the centre (the layer's anchor is its corner).
        let box = layer.bounds
        var transform = CATransform3DMakeTranslation(box.midX, box.midY, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -box.midX, -box.midY, 0)
        CATransaction.begin()
        CATransaction.setAnimationDuration(down ? 0.08 : 0.18)
        layer.transform = down ? transform : CATransform3DIdentity
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

    // Our own ring (the border) instead of the system's.
    override var focusRingType: NSFocusRingType { get { .none } set {} }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onArrow?(-1, 0)
        case 124: onArrow?(1, 0)
        case 125: onArrow?(0, 1)
        case 126: onArrow?(0, -1)
        default: super.keyDown(with: event)
        }
    }
}
