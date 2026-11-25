import AppKit

/// A group of settings on a soft card, under a coloured badge and a title —
/// the colour tells the groups apart at a glance.
final class SettingsSection: NSView {
    /// Badge colours, one per kind of setting.
    enum Tint {
        static let blue = NSColor(srgbRed: 0.27, green: 0.56, blue: 1.0, alpha: 1)
        static let green = NSColor(srgbRed: 0.24, green: 0.78, blue: 0.42, alpha: 1)
        static let orange = NSColor(srgbRed: 1.0, green: 0.58, blue: 0.20, alpha: 1)
        static let red = NSColor(srgbRed: 1.0, green: 0.34, blue: 0.36, alpha: 1)
        static let purple = NSColor(srgbRed: 0.66, green: 0.45, blue: 1.0, alpha: 1)
        static let indigo = NSColor(srgbRed: 0.42, green: 0.45, blue: 1.0, alpha: 1)
        static let teal = NSColor(srgbRed: 0.18, green: 0.75, blue: 0.80, alpha: 1)
        static let pink = NSColor(srgbRed: 1.0, green: 0.40, blue: 0.65, alpha: 1)
        static let yellow = NSColor(srgbRed: 0.98, green: 0.78, blue: 0.20, alpha: 1)
        static let gray = NSColor(srgbRed: 0.56, green: 0.58, blue: 0.64, alpha: 1)
    }

    let content = NSStackView()

    init(title: String, symbol: String, tint: NSColor, views: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.055).cgColor
        layer?.borderColor = tint.withAlphaComponent(0.22).cgColor
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false

        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 6
        let gradient = CAGradientLayer()
        gradient.colors = [tint.cgColor, (tint.blended(withFraction: 0.35, of: .black) ?? tint).cgColor]
        gradient.cornerRadius = 6
        gradient.frame = CGRect(x: 0, y: 0, width: 22, height: 22)
        badge.layer?.addSublayer(gradient)
        badge.translatesAutoresizingMaskIntoConstraints = false
        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
        glyph.contentTintColor = .white
        glyph.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(glyph)

        let heading = NSTextField(labelWithString: L(title))
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = .labelColor
        heading.translatesAutoresizingMaskIntoConstraints = false

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 9
        content.translatesAutoresizingMaskIntoConstraints = false
        views.forEach(content.addArrangedSubview)

        for view in [badge, heading, content] { addSubview(view) }
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            badge.widthAnchor.constraint(equalToConstant: 22),
            badge.heightAnchor.constraint(equalToConstant: 22),
            glyph.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            heading.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 9),
            heading.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            content.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// The status icon as it looks in each place it can go, live.
final class StatusIconPreview: NSStackView {
    private let menuLight = NSImageView()
    private let menuDark = NSImageView()
    private let ball = NSImageView()
    private let dock = NSImageView()

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 18
        alignment = .top
        addArrangedSubview(tile(menuLight, caption: "Menu bar (light)", size: NSSize(width: 64, height: 30),
                                plate: NSColor(white: 0.93, alpha: 1), light: true))
        addArrangedSubview(tile(menuDark, caption: "Menu bar (dark)", size: NSSize(width: 64, height: 30),
                                plate: NSColor(white: 0.16, alpha: 1), light: false))
        addArrangedSubview(tile(ball, caption: "Dock ball", size: NSSize(width: 52, height: 52),
                                plate: NSColor(white: 0.04, alpha: 1), light: false, round: true))
        addArrangedSubview(tile(dock, caption: "macOS Dock", size: NSSize(width: 60, height: 60), plate: nil, light: false))
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(redraw), name: .statusIconChanged, object: nil)
        center.addObserver(self, selector: #selector(redraw), name: .settingsChanged, object: nil)
        redraw()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func tile(_ image: NSImageView, caption: String, size: NSSize, plate: NSColor?, light: Bool,
                      round: Bool = false) -> NSView {
        let holder = NSView()
        holder.wantsLayer = true
        holder.layer?.backgroundColor = plate?.cgColor
        holder.layer?.cornerRadius = round ? size.height / 2 : 7
        holder.translatesAutoresizingMaskIntoConstraints = false
        image.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(image)
        let label = NSTextField(labelWithString: L(caption))
        label.font = .systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        // Every picture sits centred in the same height, so the captions line up.
        let stage = NSView()
        stage.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(holder)
        let column = NSStackView(views: [stage, label])
        column.orientation = .vertical
        column.spacing = 5
        NSLayoutConstraint.activate([
            stage.heightAnchor.constraint(equalToConstant: 62),
            stage.widthAnchor.constraint(equalToConstant: max(size.width, 64)),
            holder.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            holder.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            holder.widthAnchor.constraint(equalToConstant: size.width),
            holder.heightAnchor.constraint(equalToConstant: size.height),
            image.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: min(size.width, size.height) - (plate == nil ? 0 : 8)),
            image.heightAnchor.constraint(equalTo: image.widthAnchor)
        ])
        return column
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { StatusIcon.shared.previewShown = true }
    }

    @objc private func redraw() {
        let icon = StatusIcon.shared
        menuLight.image = icon.image(size: 22, foreground: .labelColor)
        menuDark.image = icon.image(size: 22, foreground: .labelColor)
        ball.image = icon.image(size: 88, foreground: .white, plate: .circle, inset: 88 * 0.15)
        dock.image = icon.image(size: 120, foreground: .white, plate: .square)
    }
}

/// Shows `content` only while `when` holds, re-checked on every settings
/// change (a setting that only applies to one choice of another).
final class ConditionalRow: NSStackView {
    private let when: () -> Bool

    init(when: @escaping () -> Bool, _ content: NSView) {
        self.when = when
        super.init(frame: .zero)
        orientation = .horizontal
        addArrangedSubview(content)
        isHidden = !when()
        NotificationCenter.default.addObserver(self, selector: #selector(sync), name: .settingsChanged, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func sync() {
        let hidden = !when()
        if isHidden != hidden { isHidden = hidden }
    }
}
