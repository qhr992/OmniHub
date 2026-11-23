import AppKit

/// Activity page: a tile with a live chart per metric (CPU, GPU, memory, disk),
/// then the IP addresses as plain rows. Each can be switched off in settings.
final class ActivityView: NSView {
    private let stack = NSStackView()
    private var widthConstraint: NSLayoutConstraint!
    private var tiles: [String: MetricTile] = [:]
    private var signature = ""

    init() {
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        widthConstraint = widthAnchor.constraint(equalToConstant: 250)
        NSLayoutConstraint.activate([
            widthConstraint,
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(refresh), name: .activityChanged, object: nil)
        center.addObserver(self, selector: #selector(refresh), name: .settingsChanged, object: nil)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setWidth(_ width: CGFloat) {
        guard widthConstraint.constant != width else { return }
        widthConstraint.constant = width
        signature = ""
        refresh()
    }

    /// Text of every visible row (diagnostics).
    private(set) var debugRows: [String] = []

    private static let accent = NSColor(srgbRed: 0.45, green: 0.85, blue: 1.0, alpha: 1)
    private static let palette: [String: NSColor] = [
        "cpu": NSColor(srgbRed: 0.45, green: 0.85, blue: 1.0, alpha: 1),
        "gpu": NSColor(srgbRed: 0.72, green: 0.62, blue: 1.0, alpha: 1),
        "memory": NSColor(srgbRed: 0.45, green: 0.92, blue: 0.62, alpha: 1),
        "disk": NSColor(srgbRed: 1.0, green: 0.72, blue: 0.40, alpha: 1)
    ]

    @objc private func refresh() {
        let stats = SystemStats.shared.snapshot
        let history = SystemStats.shared.history
        var metrics: [String] = []
        for key in ["cpu", "gpu", "memory", "disk"] where Prefs.bool("activity.\(key)", true) { metrics.append(key) }
        let showIP = Prefs.bool("activity.ip", true)
        let showPublic = showIP && Prefs.bool("activity.publicIP", false)
        // The view tree is rebuilt only when what is shown changes; the
        // numbers and charts are updated in place.
        let next = metrics.joined(separator: ",") + "|\(showIP)|\(showPublic)|\(stats.localIPs.map(\.name))|\(widthConstraint.constant)"
        if next != signature {
            signature = next
            rebuild(metrics: metrics)
        }

        func percent(_ value: Double?) -> String {
            value.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
        }
        debugRows = []
        if let tile = tiles["cpu"] {
            tile.update(value: percent(stats.cpu), detail: L("%ld cores", ProcessInfo.processInfo.activeProcessorCount), samples: history.cpu, ceiling: 1)
            debugRows.append("CPU: \(percent(stats.cpu)) samples=\(history.cpu.count)")
        }
        if let tile = tiles["gpu"] {
            tile.update(value: percent(stats.gpu), detail: "", samples: history.gpu, ceiling: 1)
            debugRows.append("GPU: \(percent(stats.gpu)) samples=\(history.gpu.count)")
        }
        if let tile = tiles["memory"] {
            let fraction = stats.memoryTotal > 0 ? Double(stats.memoryUsed) / Double(stats.memoryTotal) : nil
            let detail = stats.memoryTotal > 0
                ? "\(SystemStats.bytes(Int64(stats.memoryUsed))) / \(SystemStats.bytes(Int64(stats.memoryTotal)))" : ""
            tile.update(value: percent(fraction), detail: detail, samples: history.memory, ceiling: 1)
            debugRows.append("Memory: \(percent(fraction)) \(detail) samples=\(history.memory.count)")
        }
        if let tile = tiles["disk"] {
            let fraction = stats.diskTotal > 0 ? Double(stats.diskUsed) / Double(stats.diskTotal) : nil
            let detail = L("R %@ · W %@", SystemStats.rate(stats.diskRead), SystemStats.rate(stats.diskWrite))
            // The chart is read + write throughput, scaled to its own peak.
            tile.update(value: percent(fraction), detail: detail, samples: history.diskIO, ceiling: nil)
            debugRows.append("Disk: \(percent(fraction)) \(detail) samples=\(history.diskIO.count)")
        }
        for (index, entry) in stats.localIPs.enumerated() {
            ipValues["local\(index)"]?.stringValue = entry.address
            debugRows.append("IP · \(entry.name): \(entry.address)")
        }
        ipValues["public"]?.stringValue = stats.publicIP ?? L("Looking up…")
    }

    private var ipValues: [String: NSTextField] = [:]

    private func rebuild(metrics: [String]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        tiles = [:]
        ipValues = [:]
        let width = widthConstraint.constant
        // Two tiles per row when there is room for it.
        let perRow = width >= 480 ? 2 : 1
        let gap: CGFloat = 8
        let tileWidth = (width - gap * CGFloat(perRow - 1)) / CGFloat(perRow)
        let titles = ["cpu": ("cpu", "CPU"), "gpu": ("cube.transparent", "GPU"),
                      "memory": ("memorychip", L("Memory")), "disk": ("internaldrive", L("Disk"))]

        var index = 0
        while index < metrics.count {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = gap
            for key in metrics[index..<min(index + perRow, metrics.count)] {
                let (symbol, title) = titles[key] ?? ("gauge", key)
                let tile = MetricTile(symbol: symbol, title: title, tint: Self.palette[key] ?? Self.accent)
                tile.widthAnchor.constraint(equalToConstant: tileWidth).isActive = true
                tiles[key] = tile
                row.addArrangedSubview(tile)
            }
            stack.addArrangedSubview(row)
            index += perRow
        }

        if Prefs.bool("activity.ip", true) {
            let stats = SystemStats.shared.snapshot
            if stats.localIPs.isEmpty { addText("network", "IP", L("Offline"), key: "none") }
            for (index, entry) in stats.localIPs.enumerated() {
                addText("network", "IP · \(entry.name)", entry.address, key: "local\(index)")
            }
            if Prefs.bool("activity.publicIP", false) {
                addText("globe", L("Public IP"), stats.publicIP ?? L("Looking up…"), key: "public")
            }
        }
        if stack.arrangedSubviews.isEmpty {
            let empty = NSTextField(labelWithString: L("Everything is switched off in Settings"))
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = NSColor(white: 1, alpha: 0.5)
            stack.addArrangedSubview(empty)
        }
    }

    private func addText(_ symbol: String, _ title: String, _ value: String, key: String) {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        icon.contentTintColor = NSColor(white: 1, alpha: 0.75)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true

        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.textColor = .white

        let gap = NSView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)

        let figure = NSTextField(labelWithString: value)
        figure.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        figure.textColor = NSColor(white: 1, alpha: 0.75)
        figure.isSelectable = true
        ipValues[key] = figure

        let row = NSStackView(views: [icon, name, gap, figure])
        row.orientation = .horizontal
        row.spacing = 6
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
}

// MARK: - Tile

/// One metric: name and current value on top, a moving area chart below.
final class MetricTile: NSView {
    private let valueLabel = NSTextField(labelWithString: "—")
    private let detailLabel = NSTextField(labelWithString: "")
    private let chart = SparklineView()

    init(symbol: String, title: String, tint: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        icon.contentTintColor = tint
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 11, weight: .semibold)
        name.textColor = NSColor(white: 1, alpha: 0.85)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        valueLabel.textColor = .white
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        detailLabel.textColor = NSColor(white: 1, alpha: 0.55)
        detailLabel.lineBreakMode = .byTruncatingTail
        chart.tint = tint

        for view in [icon, name, valueLabel, detailLabel, chart] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 84),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            name.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            valueLabel.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            detailLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 3),
            chart.leadingAnchor.constraint(equalTo: leadingAnchor),
            chart.trailingAnchor.constraint(equalTo: trailingAnchor),
            chart.bottomAnchor.constraint(equalTo: bottomAnchor),
            chart.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 3)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `ceiling` nil = scale the chart to its own highest sample.
    func update(value: String, detail: String, samples: [Double], ceiling: Double?) {
        valueLabel.stringValue = value
        detailLabel.stringValue = detail
        chart.ceiling = ceiling
        chart.samples = samples
    }
}

/// Area chart of the latest samples; the newest sits at the right edge.
final class SparklineView: NSView {
    var tint = NSColor.white
    var ceiling: Double?
    var samples: [Double] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard samples.count > 1 else { return }
        let top = max(ceiling ?? (samples.max() ?? 0), 0.0001)
        let slots = CGFloat(SystemStats.History.capacity - 1)
        let step = bounds.width / slots
        let usable = bounds.height - 3
        var points: [NSPoint] = []
        let offset = CGFloat(SystemStats.History.capacity - samples.count)
        for (index, sample) in samples.enumerated() {
            let fraction = CGFloat(min(max(sample / top, 0), 1))
            points.append(NSPoint(x: (offset + CGFloat(index)) * step, y: 1 + fraction * usable))
        }
        let line = NSBezierPath()
        line.move(to: points[0])
        for point in points.dropFirst() { line.line(to: point) }

        let area = line.copy() as! NSBezierPath
        area.line(to: NSPoint(x: points[points.count - 1].x, y: 0))
        area.line(to: NSPoint(x: points[0].x, y: 0))
        area.close()
        NSGradient(starting: tint.withAlphaComponent(0.42), ending: tint.withAlphaComponent(0.02))?
            .draw(in: area, angle: -90)

        tint.setStroke()
        line.lineWidth = 1.4
        line.lineJoinStyle = .round
        line.stroke()
    }
}
