import AppKit

// Parts of the activity page beyond the metric tiles: Keep Awake, the
// battery and the busiest apps.

/// A rounded, faintly lit surface, like the metric tiles.
class ActivitySurface: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, alpha: CGFloat = 1,
                      mono: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        field.textColor = NSColor(white: 1, alpha: alpha)
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    static func symbol(_ name: String, tint: NSColor, size: CGFloat = 13) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold))
        view.contentTintColor = tint
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }
}

// MARK: - Keep Awake

/// "Keep Awake", what it is doing, and a menu of lengths.
final class KeepAwakeRow: ActivitySurface {
    private let icon = ActivitySurface.symbol("cup.and.saucer.fill", tint: NSColor(white: 1, alpha: 0.6))
    private let status = ActivitySurface.label("", size: 11, alpha: 0.6)
    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)

    override init() {
        super.init()
        let title = ActivitySurface.label(L("Keep Awake"), size: 12, weight: .semibold)
        picker.controlSize = .small
        picker.font = .systemFont(ofSize: 11)
        picker.addItem(withTitle: L("Off"))
        for minutes in KeepAwake.choices { picker.addItem(withTitle: KeepAwake.title(minutes: minutes)) }
        picker.target = self
        picker.action = #selector(picked)
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.toolTip = L("Keeps the display from sleeping while you are away")
        for view in [icon, title, status, picker] as [NSView] { addSubview(view) }
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            status.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: picker.leadingAnchor, constant: -6),
            picker.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            picker.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(sync), name: .keepAwakeChanged, object: nil)
        sync()
    }

    @objc private func picked() {
        let index = picker.indexOfSelectedItem
        KeepAwake.shared.choose(index <= 0 ? nil : KeepAwake.choices[index - 1])
    }

    /// Follows changes made from the menu bar, and counts down.
    @objc func sync() {
        let awake = KeepAwake.shared
        let on = awake.isOn
        icon.contentTintColor = on ? StatusIcon.Tint.awake : NSColor(white: 1, alpha: 0.6)
        layer?.backgroundColor = (on ? StatusIcon.Tint.awake.withAlphaComponent(0.16) : NSColor(white: 1, alpha: 0.07)).cgColor
        status.stringValue = awake.statusText
        status.textColor = on ? StatusIcon.Tint.awake : NSColor(white: 1, alpha: 0.6)
        let index = on ? (awake.chosenMinutes.flatMap { KeepAwake.choices.firstIndex(of: $0) }.map { $0 + 1 } ?? 0) : 0
        if picker.indexOfSelectedItem != index { picker.selectItem(at: index) }
    }
}

// MARK: - Battery

/// Charge as a level bar, the state, and the battery's health figures.
final class BatteryTile: ActivitySurface {
    private let icon = ActivitySurface.symbol("battery.100percent", tint: StatusIcon.Tint.charging, size: 14)
    private let value = ActivitySurface.label("—", size: 15, weight: .semibold, mono: true)
    private let state = ActivitySurface.label("", size: 9.5, alpha: 0.6, mono: true)
    private let figures = ActivitySurface.label("", size: 9.5, alpha: 0.6, mono: true)
    private let power = ActivitySurface.label("", size: 9.5, alpha: 0.6, mono: true)
    private let bar = LevelBar()

    override init() {
        super.init()
        let name = ActivitySurface.label(L("Battery"), size: 11, weight: .semibold, alpha: 0.85)
        bar.translatesAutoresizingMaskIntoConstraints = false
        for view in [icon, name, value, state, bar, figures, power] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 84),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            name.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            value.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            value.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            state.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            state.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            state.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            bar.topAnchor.constraint(equalTo: state.bottomAnchor, constant: 4),
            bar.heightAnchor.constraint(equalToConstant: 5),
            figures.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            figures.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            figures.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4),
            power.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            power.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            power.topAnchor.constraint(equalTo: figures.bottomAnchor, constant: 1)
        ])
    }

    /// Text of the tile (diagnostics).
    private(set) var debugText = ""

    func update(_ battery: BatteryInfo) {
        // Green as a rule; red when low, yellow in Low Power Mode.
        let tint = !battery.charging && battery.percent <= 20 ? StatusIcon.Tint.low
            : battery.lowPowerMode ? StatusIcon.Tint.lowPower : StatusIcon.Tint.charging
        icon.image = NSImage(systemSymbolName: battery.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        icon.contentTintColor = tint
        value.stringValue = "\(battery.percent)%"
        var stateParts = [battery.stateText]
        if let minutes = battery.minutesLeft {
            stateParts.append(battery.charging ? L("full in %@", Self.duration(minutes)) : L("%@ left", Self.duration(minutes)))
        }
        if battery.lowPowerMode { stateParts.append(L("Low Power Mode")) }
        state.stringValue = stateParts.joined(separator: " · ")
        bar.level = Double(battery.percent) / 100
        bar.tint = tint

        var figureParts: [String] = []
        if let health = battery.health { figureParts.append(L("Health %ld%%", Int((health * 100).rounded()))) }
        if let cycles = battery.cycleCount { figureParts.append(L("%ld cycles", cycles)) }
        if let temperature = battery.temperature { figureParts.append(String(format: "%.1f °C", temperature)) }
        figures.stringValue = figureParts.joined(separator: " · ")

        var powerParts: [String] = []
        if let watts = battery.watts, abs(watts) >= 0.1 {
            powerParts.append(watts > 0 ? L("In %@ W", String(format: "%.1f", watts)) : L("Out %@ W", String(format: "%.1f", -watts)))
        }
        if let adapter = battery.adapterWatts { powerParts.append(L("%ld W adapter", adapter)) }
        if let voltage = battery.voltage { powerParts.append(String(format: "%.2f V", voltage)) }
        power.stringValue = powerParts.joined(separator: " · ")
        debugText = [value.stringValue, state.stringValue, figures.stringValue, power.stringValue].joined(separator: " | ")
    }

    /// "1 h 20 min" / "45 min".
    static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? L("%ld h %ld min", minutes / 60, minutes % 60) : L("%ld min", minutes)
    }
}

/// A thin rounded bar filled to `level`.
final class LevelBar: NSView {
    var level: Double = 0 { didSet { needsDisplay = true } }
    var tint = NSColor.white { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor(white: 1, alpha: 0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let width = max(bounds.height, bounds.width * CGFloat(min(max(level, 0), 1)))
        let filled = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        NSGradient(starting: tint.withAlphaComponent(0.75), ending: tint)?
            .draw(in: NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius), angle: 0)
    }
}

// MARK: - Top apps

/// The apps using the most CPU or memory, each over a bar showing its
/// share against the busiest one.
final class TopAppsBox: ActivitySurface {
    static let rowCount = 5
    static let orderKey = "activity.topAppsOrder"

    private let picker = NSSegmentedControl(labels: [L("CPU"), L("Memory")], trackingMode: .selectOne, target: nil, action: nil)
    private var rows: [TopAppRow] = []
    private var entries: [TopApps.Entry] = []
    private let empty = ActivitySurface.label(L("Reading…"), size: 11, alpha: 0.5)

    private(set) var debugRows: [String] = []

    override init() {
        super.init()
        let icon = ActivitySurface.symbol("flame.fill", tint: NSColor(srgbRed: 1.0, green: 0.55, blue: 0.35, alpha: 1))
        let title = ActivitySurface.label(L("Top Apps"), size: 11, weight: .semibold, alpha: 0.85)
        picker.controlSize = .mini
        picker.font = .systemFont(ofSize: 10)
        picker.selectedSegment = Prefs.int(Self.orderKey, 0)
        picker.target = self
        picker.action = #selector(orderPicked)
        picker.translatesAutoresizingMaskIntoConstraints = false
        let list = NSStackView()
        list.orientation = .vertical
        list.spacing = 3
        list.translatesAutoresizingMaskIntoConstraints = false
        for _ in 0..<Self.rowCount {
            let row = TopAppRow()
            rows.append(row)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        for view in [icon, title, picker, list, empty] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            title.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            picker.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            picker.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            list.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            list.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            list.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 8),
            list.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            empty.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: list.centerYAnchor)
        ])
        show()
    }

    private var order: TopApps.Order { TopApps.Order(rawValue: picker.selectedSegment) ?? .cpu }

    @objc private func orderPicked() {
        Prefs.set(Self.orderKey, picker.selectedSegment)
        show()
    }

    /// Reads again (only while the page is on screen).
    func refresh() {
        // The card is hidden while folded, which hides this too.
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return }
        TopApps.sample { [weak self] entries in
            self?.entries = entries
            self?.show()
        }
    }

    /// Test hook: show these entries.
    func debugShow(_ entries: [TopApps.Entry]) {
        self.entries = entries
        show()
    }

    private func show() {
        let order = order
        let top = TopApps.top(entries, by: order, count: Self.rowCount)
        let peak = top.map { order == .cpu ? $0.cpu : Double($0.memory) }.max() ?? 0
        let tint = order == .cpu ? StatusIcon.Tint.cpu : StatusIcon.Tint.memory
        debugRows = []
        for (index, row) in rows.enumerated() {
            guard index < top.count else {
                row.alphaValue = 0
                continue
            }
            let entry = top[index]
            let amount = order == .cpu ? entry.cpu : Double(entry.memory)
            let value = order == .cpu ? String(format: "%.1f%%", entry.cpu)
                : SystemStats.bytes(Int64(entry.memory))
            let name = TopApps.displayName(for: entry)
            row.alphaValue = 1
            row.show(icon: TopApps.icon(for: entry), name: name, value: value,
                     share: peak > 0 ? amount / peak : 0, tint: tint)
            debugRows.append("\(name): \(value)")
        }
        empty.isHidden = !top.isEmpty
    }
}

/// One app: a bar behind (its share), icon, name and the figure.
final class TopAppRow: NSView {
    private let icon = NSImageView()
    private let name = ActivitySurface.label("", size: 11, weight: .medium)
    private let value = ActivitySurface.label("", size: 10.5, alpha: 0.75, mono: true)
    private var share: Double = 0
    private var tint = NSColor.white

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        value.alignment = .right
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [icon, name, value] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: value.leadingAnchor, constant: -6),
            value.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            value.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(icon image: NSImage, name text: String, value figure: String, share: Double, tint: NSColor) {
        icon.image = image
        name.stringValue = text
        value.stringValue = figure
        self.share = share
        self.tint = tint
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let width = bounds.width * CGFloat(min(max(share, 0), 1))
        guard width > 1 else { return }
        let bar = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        NSGradient(starting: tint.withAlphaComponent(0.28), ending: tint.withAlphaComponent(0.08))?
            .draw(in: NSBezierPath(roundedRect: bar, xRadius: 5, yRadius: 5), angle: 0)
    }
}
