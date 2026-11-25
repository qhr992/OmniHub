import AppKit

extension StatusIcon {
    /// The status icon's colours: a theme, or four colours of one's own.
    /// Nil parts are automatic — the ring and dots take the colour of what
    /// they show, the middle the menu bar's or white.
    struct Palette: Equatable {
        var ring: NSColor?
        var center: NSColor?
        var dots: NSColor?
        var plate: NSColor?
        /// Battery coloured by its charge (green to red) whatever the theme.
        var semantic = true

        static let defaultPlate = NSColor(srgbRed: 0.10, green: 0.11, blue: 0.16, alpha: 1)

        static let themeKey = "statusIcon.theme"
        static let semanticKey = "statusIcon.semantic"
        static func colorKey(_ part: String) -> String { "statusIcon.color.\(part)" }

        static var current: Palette {
            let theme = Theme(rawValue: Prefs.int(themeKey, Theme.automatic.rawValue)) ?? .automatic
            var palette = theme == .custom ? custom : theme.palette
            palette.semantic = Prefs.bool(semanticKey, true)
            return palette
        }

        /// The colours of the Custom theme (each falls back to the
        /// automatic one when not set).
        static var custom: Palette {
            func stored(_ part: String) -> NSColor? { NSColor(hex: Prefs.string(colorKey(part))) }
            return Palette(ring: stored("ring"), center: stored("center"), dots: stored("dots"), plate: stored("plate"))
        }
    }

    enum Theme: Int, CaseIterable {
        case automatic, aurora, sunset, mint, sakura, violet, paper, custom

        var title: String {
            switch self {
            case .automatic: return L("Automatic")
            case .aurora: return L("Aurora")
            case .sunset: return L("Sunset")
            case .mint: return L("Mint")
            case .sakura: return L("Sakura")
            case .violet: return L("Violet")
            case .paper: return L("Paper")
            case .custom: return L("Custom")
            }
        }

        var palette: Palette {
            func c(_ hex: String) -> NSColor? { NSColor(hex: hex) }
            switch self {
            case .automatic, .custom: return Palette()
            case .aurora: return Palette(ring: c("#5AC8FA"), center: c("#FFFFFF"), dots: c("#8BE0FF"), plate: c("#1B2B50"))
            case .sunset: return Palette(ring: c("#FF8A4C"), center: c("#FFE6CC"), dots: c("#FFB36B"), plate: c("#3D1E2E"))
            case .mint: return Palette(ring: c("#34D399"), center: c("#FFFFFF"), dots: c("#7EEBC0"), plate: c("#0F3330"))
            case .sakura: return Palette(ring: c("#FF7EB6"), center: c("#FFFFFF"), dots: c("#FFB8D5"), plate: c("#3E1D36"))
            case .violet: return Palette(ring: c("#A78BFA"), center: c("#FFFFFF"), dots: c("#C9B8FF"), plate: c("#241C4A"))
            case .paper: return Palette(ring: c("#2563EB"), center: c("#1F2937"), dots: c("#475569"), plate: c("#F2F3F5"))
            }
        }
    }
}

extension NSColor {
    /// "#RRGGBB" (nil for anything else, an empty string included).
    convenience init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()),
                      Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
    }
}

/// A colour well Tab can reach; Space or Return opens the colour panel.
final class FocusColorWell: NSColorWell {
    override var canBecomeKeyView: Bool { isEnabled && !isHidden }
    override var acceptsFirstResponder: Bool { isEnabled }

    override func keyDown(with event: NSEvent) {
        if FocusKeys.presses(event) { performClick(nil) } else { super.keyDown(with: event) }
    }
}

/// Settings › Appearance › Status Icon › Colours: a theme pop-up, a well per
/// part (picking a colour switches to Custom) and the battery-colours switch.
final class StatusIconColorsRow: NSStackView {
    private let theme = FocusPopUp(frame: .zero, pullsDown: false)
    private var wells: [(part: String, well: FocusColorWell)] = []

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        theme.addItems(withTitles: StatusIcon.Theme.allCases.map(\.title))
        theme.target = self
        theme.action = #selector(themePicked)

        var top: [NSView] = [label("Colours"), theme]
        for (part, title) in [("ring", "Ring"), ("center", "Middle"), ("dots", "Dots"), ("plate", "Background")] {
            let well = FocusColorWell(frame: NSRect(x: 0, y: 0, width: 38, height: 22))
            if #available(macOS 13.0, *) { well.colorWellStyle = .minimal }
            well.target = self
            well.action = #selector(wellChanged(_:))
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: 38).isActive = true
            well.heightAnchor.constraint(equalToConstant: 22).isActive = true
            wells.append((part, well))
            top.append(contentsOf: [label(title), well])
        }
        let first = NSStackView(views: top)
        first.spacing = 8
        addArrangedSubview(first)
        addArrangedSubview(PrefCheckbox("Battery coloured by charge",
                                        key: StatusIcon.Palette.semanticKey, fallback: true))
        sync()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: L(text))
        field.font = .systemFont(ofSize: 13)
        return field
    }

    /// Shows the theme and the colours it gives (automatic parts as they
    /// look on the default background).
    private func sync() {
        let current = StatusIcon.Theme(rawValue: Prefs.int(StatusIcon.Palette.themeKey, 0)) ?? .automatic
        theme.selectItem(at: StatusIcon.Theme.allCases.firstIndex(of: current) ?? 0)
        let palette = StatusIcon.Palette.current
        let shown: [String: NSColor] = ["ring": palette.ring ?? StatusIcon.Tint.charging,
                                        "center": palette.center ?? .white,
                                        "dots": palette.dots ?? .white,
                                        "plate": palette.plate ?? StatusIcon.Palette.defaultPlate]
        for (part, well) in wells { well.color = shown[part] ?? .white }
    }

    @objc private func themePicked() {
        let picked = StatusIcon.Theme.allCases[max(0, theme.indexOfSelectedItem)]
        if picked == .custom {
            // Start from what is shown, so Custom changes nothing at first.
            for (part, well) in wells { Prefs.set(StatusIcon.Palette.colorKey(part), well.color.hexString) }
        }
        Prefs.set(StatusIcon.Palette.themeKey, picked.rawValue)
        sync()
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }

    @objc private func wellChanged(_ sender: FocusColorWell) {
        // Any colour picked by hand makes the theme Custom, the others kept.
        if (Prefs.int(StatusIcon.Palette.themeKey, 0)) != StatusIcon.Theme.custom.rawValue {
            for (part, well) in wells { Prefs.set(StatusIcon.Palette.colorKey(part), well.color.hexString) }
            Prefs.set(StatusIcon.Palette.themeKey, StatusIcon.Theme.custom.rawValue)
        }
        if let part = wells.first(where: { $0.well === sender })?.part {
            Prefs.set(StatusIcon.Palette.colorKey(part), sender.color.hexString)
        }
        sync()
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }
}
