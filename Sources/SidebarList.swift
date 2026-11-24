import AppKit

/// A vertical list of choices, each with a coloured icon badge: the main
/// window's pages and the Settings categories. Tab reaches the rows; ↑ / ↓
/// move the selection, Return or Space picks the focused row.
final class SidebarList: NSStackView {
    struct Item {
        let title: String
        let symbol: String
        let tint: NSColor
    }

    private(set) var rows: [SidebarRow] = []
    /// Called with the index the user picked (not for `select(_:)`).
    var onPick: ((Int) -> Void)?

    private(set) var selectedIndex = 0

    init(items: [Item], rowHeight: CGFloat = 34) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 2
        translatesAutoresizingMaskIntoConstraints = false
        for (index, item) in items.enumerated() {
            let row = SidebarRow(item: item, height: rowHeight)
            row.tag = index
            row.target = self
            row.action = #selector(picked(_:))
            row.onArrow = { [weak self] delta in self?.move(delta, from: index) }
            addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            rows.append(row)
        }
        syncRows()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows `index` as selected without telling anyone.
    func select(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        selectedIndex = index
        syncRows()
    }

    var titles: [String] { rows.map(\.itemTitle) }

    @objc private func picked(_ sender: SidebarRow) {
        select(sender.tag)
        onPick?(sender.tag)
    }

    private func move(_ delta: Int, from index: Int) {
        let next = index + delta
        guard rows.indices.contains(next) else { return }
        window?.makeFirstResponder(rows[next])
        select(next)
        onPick?(next)
    }

    private func syncRows() {
        for row in rows { row.isSelected = row.tag == selectedIndex }
    }
}

/// One row of a `SidebarList`: badge, title, and a rounded highlight when
/// selected or under the pointer.
final class SidebarRow: FocusButton {
    let itemTitle: String
    var onArrow: ((Int) -> Void)?
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            label.font = .systemFont(ofSize: 13, weight: isSelected ? .semibold : .regular)
            label.textColor = isSelected ? .white : NSColor(white: 1, alpha: 0.78)
            needsDisplay = true
        }
    }
    private let tint: NSColor
    private let label: NSTextField
    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }

    init(item: SidebarList.Item, height: CGFloat) {
        itemTitle = item.title
        tint = item.tint
        label = NSTextField(labelWithString: L(item.title))
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        setAccessibilityTitle(L(item.title))
        setAccessibilityRole(.button)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true

        let badge = BadgeView(symbol: item.symbol, tint: item.tint, side: height - 12)
        label.font = .systemFont(ofSize: 13)
        label.textColor = NSColor(white: 1, alpha: 0.78)
        label.lineBreakMode = .byTruncatingTail
        for view in [badge, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: onArrow?(1)      // ↓
        case 126: onArrow?(-1)     // ↑
        default: super.keyDown(with: event)
        }
    }

    private var shape: NSBezierPath { NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8) }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            // The row's own colour, quietly: a tinted wash and a hairline.
            tint.withAlphaComponent(0.22).setFill()
            shape.fill()
            tint.withAlphaComponent(0.45).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        } else if hovering {
            NSColor(white: 1, alpha: 0.06).setFill()
            shape.fill()
        }
    }

    override func drawFocusRingMask() { shape.fill() }
    override var focusRingMaskBounds: NSRect { bounds }
}

/// A rounded square with a white symbol on a gradient of `tint`.
final class BadgeView: NSView {
    init(symbol: String, tint: NSColor, side: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
        let gradient = CAGradientLayer()
        let top = tint.blended(withFraction: 0.18, of: .white) ?? tint
        let bottom = tint.blended(withFraction: 0.22, of: .black) ?? tint
        gradient.colors = [top.cgColor, bottom.cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.cornerRadius = side * 0.28
        gradient.frame = bounds
        layer?.addSublayer(gradient)
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: side * 0.52, weight: .semibold)) ?? NSImage())
        image.contentTintColor = .white
        image.frame = bounds
        image.imageScaling = .scaleNone
        addSubview(image)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: side).isActive = true
        heightAnchor.constraint(equalToConstant: side).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
