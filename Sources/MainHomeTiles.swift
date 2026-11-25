import AppKit

/// A card on the main window's Home: a hairline-edged surface with a badge
/// and title on top, an optional control at the header's end, and an
/// optional colour wash from the top left.
class HomeTile: NSView {
    let content = NSStackView()
    private let header = NSStackView()
    private let wash = CAGradientLayer()

    init(title: String, symbol: String, tint: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.045).cgColor
        layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        wash.startPoint = CGPoint(x: 0, y: 1)
        wash.endPoint = CGPoint(x: 0.9, y: 0)
        wash.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor]
        layer?.addSublayer(wash)
        translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: L(title))
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.textColor = NSColor(white: 1, alpha: 0.62)
        header.orientation = .horizontal
        header.spacing = 8
        header.addArrangedSubview(BadgeView(symbol: symbol, tint: tint, side: 20))
        header.addArrangedSubview(name)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        for view in [header, content] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            content.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A control at the end of the header ("All ›").
    func setAccessory(_ view: NSView) {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        header.addArrangedSubview(spacer)
        header.addArrangedSubview(view)
    }

    /// Tints the card from its top left (nil: none).
    func setWash(_ color: NSColor?) {
        let top = (color ?? .clear).withAlphaComponent(color == nil ? 0 : 0.30).cgColor
        wash.colors = [top, NSColor.clear.cgColor]
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wash.frame = bounds
        CATransaction.commit()
    }
}

/// A small text button: "All ›", "+ New to-do".
final class HomeLink: FocusButton {
    init(_ title: String, symbol: String? = nil, color: NSColor = NSColor(white: 1, alpha: 0.55),
         action: @escaping () -> Void) {
        self.handler = action
        super.init(frame: .zero)
        isBordered = false
        let text = NSMutableAttributedString(string: L(title),
                                             attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                          .foregroundColor: color])
        if let symbol {
            if !text.string.isEmpty { text.insert(NSAttributedString(string: " "), at: 0) }
            text.insert(Self.symbol(symbol, size: title.isEmpty ? 15 : 10, color: color), at: 0)
        }
        attributedTitle = text
        setAccessibilityTitle(L(title))
        target = self
        self.action = #selector(fire)
    }

    private let handler: () -> Void

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }

    /// An SF Symbol in `color`, to sit in an attributed title.
    static func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color])))
        return NSAttributedString(attachment: attachment)
    }
}

/// A 270° gauge with the value in the middle and a caption below.
final class RingGauge: NSView {
    var value: Double? { didSet { needsDisplay = true } }
    var detail = "" { didSet { needsDisplay = true } }
    var tint: NSColor { didSet { needsDisplay = true } }
    private let caption: String

    init(caption: String, tint: NSColor) {
        self.caption = L(caption)
        self.tint = tint
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 62).isActive = true
        heightAnchor.constraint(equalToConstant: 84).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let side: CGFloat = 56
        let center = NSPoint(x: bounds.midX, y: bounds.maxY - side / 2 - 2)
        let radius = side / 2 - 4
        func arc(_ fraction: Double, _ color: NSColor) {
            let path = NSBezierPath()
            path.appendArc(withCenter: center, radius: radius, startAngle: 225,
                           endAngle: 225 - 270 * CGFloat(min(max(fraction, 0), 1)), clockwise: true)
            path.lineWidth = 5
            path.lineCapStyle = .round
            color.setStroke()
            path.stroke()
        }
        arc(1, NSColor(white: 1, alpha: 0.1))
        if let value, value > 0.005 { arc(value, tint) }
        let figure = value.map { "\(Int(($0 * 100).rounded()))" } ?? "–"
        let big: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold),
                                                  .foregroundColor: NSColor.white]
        let size = (figure as NSString).size(withAttributes: big)
        (figure as NSString).draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: big)
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                    .foregroundColor: NSColor(white: 1, alpha: 0.6)]
        let label = detail.isEmpty ? caption : detail
        let labelSize = (label as NSString).size(withAttributes: small)
        (label as NSString).draw(at: NSPoint(x: bounds.midX - labelSize.width / 2, y: 2), withAttributes: small)
    }
}

/// One of the quick actions: a badge over a caption, in a soft square.
final class HomeAction: FocusButton {
    private let handler: () -> Void
    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }

    init(_ title: String, symbol: String, tint: NSColor, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        isBordered = false
        self.title = ""
        setAccessibilityTitle(L(title))
        target = self
        self.action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 70).isActive = true
        let badge = BadgeView(symbol: symbol, tint: tint, side: 28)
        let label = NSTextField(labelWithString: L(title))
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor(white: 1, alpha: 0.85)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        for view in [badge, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: centerXAnchor),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            label.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 7),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            label.centerXAnchor.constraint(equalTo: centerXAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private var shape: NSBezierPath { NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: isHighlighted ? 0.12 : hovering ? 0.09 : 0.045).setFill()
        shape.fill()
    }

    override func drawFocusRingMask() { shape.fill() }
    override var focusRingMaskBounds: NSRect { bounds }
}

/// A to-do on Home: a ring to tick it off, the title, and when it is due.
final class HomeTodoRow: NSView {
    init(_ item: TaskItem, onDone: @escaping () -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let check = HomeLink("", symbol: "circle", color: NSColor(white: 1, alpha: 0.5), action: onDone)
        check.setAccessibilityTitle(L("Done") + " " + item.title)
        check.toolTip = L("Done")
        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 13)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let due = NSTextField(labelWithString: item.due.map(Self.dueText) ?? "")
        due.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let overdue = (item.due ?? .distantFuture) < Date()
        due.textColor = overdue ? NSColor(srgbRed: 1, green: 0.42, blue: 0.40, alpha: 1) : NSColor(white: 1, alpha: 0.45)
        for view in [check, title, due] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            check.leadingAnchor.constraint(equalTo: leadingAnchor),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            due.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 10),
            due.trailingAnchor.constraint(equalTo: trailingAnchor),
            due.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// "14:30" today, "Tomorrow 09:00", else "Nov 26".
    static func dueText(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = DateFormatter()
        time.locale = AppLanguage.chosen.locale
        time.dateFormat = "HH:mm"
        if calendar.isDateInToday(date) { return time.string(from: date) }
        if calendar.isDateInTomorrow(date) { return L("Tomorrow") + " " + time.string(from: date) }
        let day = DateFormatter()
        day.locale = AppLanguage.chosen.locale
        day.setLocalizedDateFormatFromTemplate("MMMd")
        return day.string(from: date)
    }
}

/// A quiet empty state: a faint symbol, a line, and a hint.
final class HomeEmptyState: NSStackView {
    init(symbol: String, title: String, detail: String) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 6
        edgeInsets = NSEdgeInsets(top: 14, left: 0, bottom: 10, right: 0)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 26, weight: .light)) ?? NSImage())
        icon.contentTintColor = NSColor(white: 1, alpha: 0.22)
        let line = NSTextField(labelWithString: L(title))
        line.font = .systemFont(ofSize: 13, weight: .medium)
        line.textColor = NSColor(white: 1, alpha: 0.55)
        let hint = NSTextField(wrappingLabelWithString: L(detail))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor(white: 1, alpha: 0.35)
        hint.alignment = .center
        hint.preferredMaxLayoutWidth = 260
        for view in [icon, line, hint] as [NSView] { addArrangedSubview(view) }
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
