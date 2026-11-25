import AppKit

/// A left click on the menu bar icon: a panel drops down with the player on
/// top and the system's load listed below (CPU, memory, GPU, disk, battery,
/// network, Keep Awake), ending in a way into the dashboard.
final class MenuBarPanel: NSObject, NSPopoverDelegate {
    static let shared = MenuBarPanel()

    private let popover = NSPopover()
    private lazy var content = MenuBarPanelView()

    var isShown: Bool { popover.isShown }

    func toggle(from button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        if popover.contentViewController == nil {
            let controller = NSViewController()
            controller.view = content
            popover.contentViewController = controller
            popover.behavior = .transient
            popover.animates = true
            popover.appearance = NSAppearance(named: .darkAqua)
            popover.delegate = self
        }
        content.willShow()
        popover.contentSize = content.fittingSize
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func close() { popover.performClose(nil) }

    var debugState: String {
        "menubarPanel shown=\(popover.isShown) frame=\(content.window.map { NSStringFromRect($0.frame) } ?? "-") screen=\(content.window?.screen.map { NSStringFromRect($0.frame) } ?? "-") \(popover.isShown ? content.debugText : "")"
    }

    func popoverDidClose(_ notification: Notification) { content.didHide() }

    /// Test hook: the panel laid out (and refreshed) without showing it.
    static func debugContent() -> MenuBarPanelView {
        let view = shared.content
        view.willShow()
        view.layoutSubtreeIfNeeded()
        return view
    }

    static func debugDidHide() { shared.content.didHide() }
}

/// What the panel shows.
final class MenuBarPanelView: NSView {
    static let width: CGFloat = 384

    private let playing = NowPlayingTile()
    private let system = SystemListTile()
    private var timer: Timer?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 400))
        let open = HomeLink("Open Dashboard", symbol: "rectangle.grid.2x2.fill", color: .white) {
            MenuBarPanel.shared.close()
            MainWindow.openDashboard()
        }
        let settings = HomeLink("Settings", symbol: "gearshape.fill") {
            MenuBarPanel.shared.close()
            MainWindow.open(.settings)
        }
        let footer = NSStackView(views: [open, NSView(), settings])
        let stack = NSStackView(views: [playing, system, footer])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            playing.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            system.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40)
        ])
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(mediaChanged), name: .mediaChanged, object: nil)
        center.addObserver(self, selector: #selector(mediaChanged), name: .lyricsChanged, object: nil)
        center.addObserver(self, selector: #selector(statsChanged), name: .activityChanged, object: nil)
        center.addObserver(self, selector: #selector(statsChanged), name: .keepAwakeChanged, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func willShow() {
        if timer == nil {
            SystemStats.shared.retain()
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.playing.tick() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        playing.update()
        system.update()
    }

    func didHide() {
        guard let timer else { return }
        timer.invalidate()
        self.timer = nil
        SystemStats.shared.release()
    }

    @objc private func mediaChanged() { playing.update() }
    @objc private func statsChanged() { system.update() }

    var debugText: String { "playing=\(playing.debugText) \(system.debugText)" }
}

/// The system's load as a list: a bar and a figure per line.
final class SystemListTile: HomeTile {
    private let cpu = LoadRow("CPU", tint: StatusIcon.Tint.cpu)
    private let memory = LoadRow("Memory", tint: StatusIcon.Tint.memory)
    private let gpu = LoadRow("GPU", tint: SettingsSection.Tint.purple)
    private let disk = LoadRow("Disk", tint: StatusIcon.Tint.disk)
    private let battery = LoadRow("Battery", tint: .white)
    private let network = NSTextField(labelWithString: "")
    private lazy var awake = HomeLink("", symbol: KeepAwake.symbolName) { [weak self] in self?.awakeMenu() }

    init() {
        super.init(title: "System", symbol: "gauge.with.dots.needle.67percent", tint: SettingsSection.Tint.green)
        content.spacing = 8
        for row in [cpu, memory, gpu, disk, battery] {
            content.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        network.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        network.textColor = NSColor(white: 1, alpha: 0.75)
        let line = NSStackView(views: [network, NSView(), awake])
        content.addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }

    func update() {
        let stats = SystemStats.shared.snapshot
        cpu.set(stats.cpu)
        memory.set(stats.memoryTotal > 0 ? Double(stats.memoryUsed) / Double(stats.memoryTotal) : nil,
                   detail: stats.memoryTotal > 0 ? "\(SystemStats.bytes(Int64(stats.memoryUsed))) / \(SystemStats.bytes(Int64(stats.memoryTotal)))" : nil)
        gpu.set(stats.gpu)
        gpu.isHidden = stats.gpu == nil
        disk.set(stats.diskTotal > 0 ? Double(stats.diskUsed) / Double(stats.diskTotal) : nil)
        let info = stats.battery ?? BatteryInfo.read()
        battery.isHidden = info == nil
        if let info {
            battery.tint = StatusIcon.batteryTint(info) ?? .white
            battery.set(Double(info.percent) / 100, detail: info.stateText)
        }
        network.stringValue = "↑ \(SystemStats.rate(stats.netOut))   ↓ \(SystemStats.rate(stats.netIn))"
        let on = KeepAwake.shared.isOn
        let colour = on ? StatusIcon.Tint.awake : NSColor(white: 1, alpha: 0.5)
        let title = NSMutableAttributedString(attributedString: HomeLink.symbol(KeepAwake.symbolName, size: 11, color: colour))
        title.append(NSAttributedString(string: " " + (on ? KeepAwake.shared.statusText : L("Keep Awake")),
                                        attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                     .foregroundColor: colour]))
        awake.attributedTitle = title
    }

    private func awakeMenu() {
        let menu = KeepAwake.shared.menu(target: self, action: #selector(awakePicked(_:)))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: awake.bounds.height + 4), in: awake)
    }

    @objc private func awakePicked(_ sender: NSMenuItem) {
        KeepAwake.shared.choose(sender.tag < 0 ? nil : sender.tag)
    }

    var debugText: String {
        [cpu, memory, gpu, disk, battery].filter { !$0.isHidden }.map(\.debugText).joined(separator: " ")
            + " net=\(network.stringValue)"
    }
}

/// "CPU  ▇▇▇▇▁▁▁  41 %" with an optional detail under the bar.
final class LoadRow: NSView {
    private let name: NSTextField
    private let bar = LevelBar()
    private let figure = NSTextField(labelWithString: "–")
    private let detail = NSTextField(labelWithString: "")
    var tint: NSColor {
        get { bar.tint }
        set { bar.tint = newValue }
    }

    init(_ title: String, tint: NSColor) {
        name = NSTextField(labelWithString: L(title))
        super.init(frame: .zero)
        bar.tint = tint
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.textColor = NSColor(white: 1, alpha: 0.8)
        figure.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        figure.textColor = .white
        figure.alignment = .right
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = NSColor(white: 1, alpha: 0.45)
        translatesAutoresizingMaskIntoConstraints = false
        for view in [name, bar, figure, detail] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            name.topAnchor.constraint(equalTo: topAnchor),
            name.widthAnchor.constraint(equalToConstant: 64),
            bar.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 6),
            bar.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 6),
            figure.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 10),
            figure.trailingAnchor.constraint(equalTo: trailingAnchor),
            figure.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            figure.widthAnchor.constraint(equalToConstant: 42),
            detail.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            bottomAnchor.constraint(equalTo: detail.bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(_ value: Double?, detail text: String? = nil) {
        bar.level = value ?? 0
        figure.stringValue = value.map { "\(Int(($0 * 100).rounded())) %" } ?? "–"
        detail.stringValue = text ?? ""
        detail.isHidden = (text ?? "").isEmpty
    }

    var debugText: String { "\(name.stringValue)=\(figure.stringValue)" }
}
