import AppKit

/// A left click on the menu bar icon: a panel drops down with the player on
/// top and the system below as on the Activity page (Display Sleep, then CPU,
/// memory, GPU, disk, network and battery with their charts), ending in a
/// way into the dashboard.
final class MenuBarPanel: NSObject, NSPopoverDelegate {
    static let shared = MenuBarPanel()

    private let popover = NSPopover()
    private lazy var content = MenuBarPanelView()

    var isShown: Bool { popover.isShown }

    /// What the popover hangs from: a clear sliver laid over the icon that
    /// was clicked. Once we activate, the status item's button can move to
    /// another display's menu bar (the one with our key window), which put
    /// the panel on the wrong screen over full-screen apps. The sliver stays
    /// where the click was, in every Space.
    private lazy var anchor: NSPanel = {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }()

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
        guard let window = button.window, let host = anchor.contentView else { return }
        // Read before activating: activating is what moves the button away.
        anchor.setFrame(window.convertToScreen(button.convert(button.bounds, to: nil)), display: false)
        anchor.orderFrontRegardless()
        content.willShow()
        popover.contentSize = content.fittingSize
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: host.bounds, of: host, preferredEdge: .minY)
    }

    func close() { popover.performClose(nil) }

    var debugState: String {
        "menubarPanel shown=\(popover.isShown) anchor=\(NSStringFromRect(anchor.frame)) frame=\(content.window.map { NSStringFromRect($0.frame) } ?? "-") screen=\(content.window?.screen.map { NSStringFromRect($0.frame) } ?? "-") \(popover.isShown ? content.debugText : "")"
    }

    func popoverDidClose(_ notification: Notification) {
        anchor.orderOut(nil)
        content.didHide()
    }

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
    private let system = PanelMetrics(width: MenuBarPanelView.width - 24)
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
        // The player opens its app; the panel gets out of the way.
        playing.onOpen = {
            MenuBarPanel.shared.close()
            MediaObserver.shared.activateOwner()
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
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40)
        ])
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(mediaChanged), name: .mediaChanged, object: nil)
        center.addObserver(self, selector: #selector(mediaChanged), name: .lyricsChanged, object: nil)
        center.addObserver(self, selector: #selector(statsChanged), name: .activityChanged, object: nil)
        center.addObserver(self, selector: #selector(statsChanged), name: .keepAwakeChanged, object: nil)
        center.addObserver(self, selector: #selector(statsChanged), name: .settingsChanged, object: nil)
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

    /// Test hook: a click on the player's cover, through to the app switch.
    func debugOpenPlayer() { playing.debugOpen() }
    var debugPlayingCompact: Bool { layoutSubtreeIfNeeded(); return playing.isCompact }
}

/// The system as on the Activity page: Display Sleep, then CPU, memory, GPU,
/// disk, network and battery as tiles with their recent history drawn.
final class PanelMetrics: NSStackView {
    private static let gap: CGFloat = 8
    private let keepAwake = KeepAwakeRow()
    private var tiles: [String: MetricTile] = [:]
    private let battery = BatteryTile()

    init(width: CGFloat) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Self.gap
        translatesAutoresizingMaskIntoConstraints = false
        let tileWidth = (width - Self.gap) / 2
        addArrangedSubview(keepAwake)
        keepAwake.widthAnchor.constraint(equalToConstant: width).isActive = true
        let titles: [(String, String, String)] = [("cpu", "cpu", "CPU"), ("memory", "memorychip", "Memory"),
                                                  ("gpu", "cube.transparent", "GPU"), ("disk", "internaldrive", "Disk"),
                                                  ("network", "arrow.up.arrow.down", "Network")]
        var cells: [NSView] = titles.map { key, symbol, title in
            let tile = MetricTile(symbol: symbol, title: L(title), tint: ActivityView.palette[key] ?? .white)
            tiles[key] = tile
            return tile
        }
        cells.append(battery)
        for start in stride(from: 0, to: cells.count, by: 2) {
            let row = NSStackView(views: Array(cells[start..<min(start + 2, cells.count)]))
            row.spacing = Self.gap
            for cell in row.arrangedSubviews { cell.widthAnchor.constraint(equalToConstant: tileWidth).isActive = true }
            addArrangedSubview(row)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update() {
        let stats = SystemStats.shared.snapshot
        let history = SystemStats.shared.history
        func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0 * 100) } ?? "—" }
        keepAwake.sync()
        tiles["cpu"]?.update(value: percent(stats.cpu),
                             detail: L("%ld cores", ProcessInfo.processInfo.activeProcessorCount),
                             samples: history.cpu, ceiling: 1)
        let memory = stats.memoryTotal > 0 ? Double(stats.memoryUsed) / Double(stats.memoryTotal) : nil
        tiles["memory"]?.update(value: percent(memory),
                                detail: stats.memoryTotal > 0
                                    ? "\(SystemStats.bytes(Int64(stats.memoryUsed))) / \(SystemStats.bytes(Int64(stats.memoryTotal)))" : "",
                                samples: history.memory, ceiling: 1)
        tiles["gpu"]?.update(value: percent(stats.gpu), detail: "", samples: history.gpu, ceiling: 1)
        let disk = stats.diskTotal > 0 ? Double(stats.diskUsed) / Double(stats.diskTotal) : nil
        tiles["disk"]?.update(value: percent(disk),
                              detail: L("R %@ · W %@", SystemStats.rate(stats.diskRead), SystemStats.rate(stats.diskWrite)),
                              samples: history.diskIO, ceiling: nil)
        tiles["network"]?.update(value: "↓ " + SystemStats.rate(stats.netIn), detail: "↑ " + SystemStats.rate(stats.netOut),
                                 samples: history.network, ceiling: nil)
        let info = stats.battery ?? BatteryInfo.read()
        battery.isHidden = info == nil
        if let info { battery.update(info) }
    }

    var debugText: String {
        ["cpu", "memory", "gpu", "disk", "network"].map { "\($0)=\(tiles[$0]?.debugValue ?? "-")" }.joined(separator: " ")
            + (battery.isHidden ? "" : " battery=\(battery.debugText)")
            + " samples=\(SystemStats.shared.history.cpu.count)"
    }
}
