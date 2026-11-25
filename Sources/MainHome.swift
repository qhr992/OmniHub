import AppKit

/// Home in the main window: a greeting and clock, then a bento of cards —
/// Now Playing (washed in the cover's colour), the system at a glance,
/// today's to-dos and quick actions. Its own view; the card keeps its
/// compact Home.
final class MainHomeView: NSView, DockPage {
    static let sideColumn: CGFloat = 300
    private static let gap: CGFloat = 14

    private let greeting = NSTextField(labelWithString: "")
    private let dateLine = NSTextField(labelWithString: "")
    private let holiday = NSTextField(labelWithString: "")
    private let clock = NSTextField(labelWithString: "")
    private let playing = NowPlayingTile()
    private let system = SystemTile()
    private let todos = TodoTile()
    private let actions = ActionsTile()
    private var widthConstraint: NSLayoutConstraint!
    private var timer: Timer?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(mediaChanged), name: .mediaChanged, object: nil)
        center.addObserver(self, selector: #selector(mediaChanged), name: .lyricsChanged, object: nil)
        center.addObserver(self, selector: #selector(tasksChanged), name: .tasksChanged, object: nil)
        center.addObserver(self, selector: #selector(statsChanged), name: .activityChanged, object: nil)
        center.addObserver(self, selector: #selector(statsChanged), name: .keepAwakeChanged, object: nil)
        refreshAll()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func preferredSize(horizontal: Bool) -> NSSize { NSSize(width: 820, height: 560) }

    func setWidth(_ width: CGFloat) {
        guard widthConstraint.constant != width else { return }
        widthConstraint.constant = width
    }

    private func build() {
        greeting.font = .systemFont(ofSize: 30, weight: .bold)
        greeting.textColor = .white
        dateLine.font = .systemFont(ofSize: 13, weight: .medium)
        dateLine.textColor = NSColor(white: 1, alpha: 0.55)
        holiday.font = .systemFont(ofSize: 12, weight: .semibold)
        holiday.textColor = NSColor(srgbRed: 1.0, green: 0.80, blue: 0.45, alpha: 1)
        clock.font = .monospacedDigitSystemFont(ofSize: 40, weight: .light)
        clock.textColor = NSColor(white: 1, alpha: 0.92)
        clock.alignment = .right

        let subline = NSStackView(views: [dateLine, holiday])
        subline.spacing = 12
        let words = NSStackView(views: [greeting, subline])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 4
        let hero = NSView()
        for view in [words, clock] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            hero.addSubview(view)
        }
        NSLayoutConstraint.activate([
            words.topAnchor.constraint(equalTo: hero.topAnchor),
            words.leadingAnchor.constraint(equalTo: hero.leadingAnchor, constant: 4),
            words.bottomAnchor.constraint(equalTo: hero.bottomAnchor),
            clock.trailingAnchor.constraint(equalTo: hero.trailingAnchor, constant: -4),
            clock.lastBaselineAnchor.constraint(equalTo: subline.lastBaselineAnchor)
        ])

        let top = row(playing, system)
        let bottom = row(todos, actions)
        for view in [hero, top, bottom] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        widthConstraint = widthAnchor.constraint(equalToConstant: 760)
        NSLayoutConstraint.activate([
            widthConstraint,
            hero.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            hero.leadingAnchor.constraint(equalTo: leadingAnchor),
            hero.trailingAnchor.constraint(equalTo: trailingAnchor),
            top.topAnchor.constraint(equalTo: hero.bottomAnchor, constant: 22),
            top.leadingAnchor.constraint(equalTo: leadingAnchor),
            top.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottom.topAnchor.constraint(equalTo: top.bottomAnchor, constant: Self.gap),
            bottom.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    /// A wide card and a 300-point one, the same height.
    private func row(_ wide: HomeTile, _ narrow: HomeTile) -> NSView {
        let row = NSView()
        for view in [wide, narrow] { row.addSubview(view) }
        NSLayoutConstraint.activate([
            wide.topAnchor.constraint(equalTo: row.topAnchor),
            wide.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            wide.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            narrow.topAnchor.constraint(equalTo: row.topAnchor),
            narrow.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            narrow.leadingAnchor.constraint(equalTo: wide.trailingAnchor, constant: Self.gap),
            narrow.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            narrow.widthAnchor.constraint(equalToConstant: Self.sideColumn),
            row.heightAnchor.constraint(greaterThanOrEqualTo: wide.content.heightAnchor, constant: 64),
            row.heightAnchor.constraint(greaterThanOrEqualTo: narrow.content.heightAnchor, constant: 64),
            row.heightAnchor.constraint(equalToConstant: 0).withPriority(.init(1))
        ])
        return row
    }

    // MARK: Refreshing

    func pageWillAppear() {
        SystemStats.shared.retain()
        refreshAll()
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func pageDidDisappear() {
        timer?.invalidate()
        timer = nil
        SystemStats.shared.release()
    }

    private func refreshAll() {
        tick()
        playing.update()
        system.update()
        todos.update()
    }

    private func tick() {
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        greeting.stringValue = L(hour < 5 ? "Late night" : hour < 11 ? "Good morning" : hour < 13 ? "Good noon"
                                 : hour < 18 ? "Good afternoon" : "Good evening")
        let date = DateFormatter()
        date.locale = AppLanguage.chosen.locale
        date.setLocalizedDateFormatFromTemplate("MMMMdEEEE")
        dateLine.stringValue = date.string(from: now)
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        clock.stringValue = time.string(from: now)
        let countdown = Prefs.bool("dock.showHoliday", true) ? Holidays.countdownText(from: now) : ""
        holiday.stringValue = countdown
        holiday.isHidden = countdown.isEmpty
        playing.tick()
    }

    @objc private func mediaChanged() { playing.update() }
    @objc private func tasksChanged() { todos.update() }
    @objc private func statsChanged() { system.update() }

    /// Test hook: what the cards show.
    var debugText: String {
        "greeting=\(greeting.stringValue) date=\(dateLine.stringValue) clock=\(clock.stringValue) "
            + "playing=\(playing.debugText) todos=\(todos.debugCount) actions=\(actions.debugCount)"
    }
}

// MARK: - Cards

/// Now Playing: the cover, title, artist, the current lyric line, progress
/// and transport, washed in the cover's colour.
final class NowPlayingTile: HomeTile {
    private let artwork = CoverView()
    private let title = NSTextField(labelWithString: "")
    private let artist = NSTextField(labelWithString: "")
    private let lyric = NSTextField(labelWithString: "")
    private let progress = HomeProgress()
    private let elapsed = NSTextField(labelWithString: "")
    private let playButton = HomeLink("", symbol: "play.fill", color: .white) { MediaObserver.shared.togglePlayPause() }
    private let playColour = NSColor.white
    private let details = NSStackView()
    private let empty = HomeEmptyState(symbol: "music.note", title: "Nothing playing",
                                       detail: "Play music in any player to see its cover and lyrics here.")
    private var coverKey: ObjectIdentifier?

    init() {
        super.init(title: "Now Playing", symbol: "music.note", tint: SettingsSection.Tint.pink)
        artwork.translatesAutoresizingMaskIntoConstraints = false
        artwork.widthAnchor.constraint(equalToConstant: 116).isActive = true
        artwork.heightAnchor.constraint(equalToConstant: 116).isActive = true
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textColor = .white
        artist.font = .systemFont(ofSize: 13)
        artist.textColor = NSColor(white: 1, alpha: 0.6)
        lyric.font = .systemFont(ofSize: 13, weight: .medium)
        lyric.textColor = NSColor(srgbRed: 1.0, green: 0.80, blue: 0.55, alpha: 1)
        for field in [title, artist, lyric] {
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        elapsed.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        elapsed.textColor = NSColor(white: 1, alpha: 0.5)
        let previous = HomeLink("", symbol: "backward.fill", color: NSColor(white: 1, alpha: 0.8)) { MediaObserver.shared.previousTrack() }
        let next = HomeLink("", symbol: "forward.fill", color: NSColor(white: 1, alpha: 0.8)) { MediaObserver.shared.nextTrack() }
        previous.setAccessibilityTitle(L("Previous"))
        next.setAccessibilityTitle(L("Next"))
        playButton.setAccessibilityTitle(L("Play / Pause"))
        let transport = NSStackView(views: [previous, playButton, next, elapsed])
        transport.spacing = 18
        let text = NSStackView(views: [title, artist, lyric, progress, transport])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 6
        text.setCustomSpacing(12, after: lyric)
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        details.orientation = .horizontal
        details.distribution = .fill
        details.alignment = .centerY
        details.spacing = 18
        details.addArrangedSubview(artwork)
        details.addArrangedSubview(text)
        // The words take the rest of the card, so the progress line runs to its edge.
        text.setContentHuggingPriority(.init(1), for: .horizontal)
        artwork.setContentHuggingPriority(.required, for: .horizontal)
        content.addArrangedSubview(details)
        content.addArrangedSubview(empty)
        details.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        empty.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }

    func update() {
        let item = MediaObserver.shared.current
        let shown = item?.hasContent == true
        details.isHidden = !shown
        empty.isHidden = shown
        guard let item, shown else {
            setWash(nil)
            coverKey = nil
            return
        }
        title.stringValue = item.title
        artist.stringValue = [item.artist, item.appName].filter { !$0.isEmpty }.joined(separator: " · ")
        artwork.image = item.artwork ?? NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
        if let cover = item.artwork, coverKey != ObjectIdentifier(cover) {
            coverKey = ObjectIdentifier(cover)
            setWash(Self.averageColour(cover))
        } else if item.artwork == nil {
            setWash(SettingsSection.Tint.pink)
        }
        playButton.attributedTitle = HomeLink.symbol(item.isPlaying ? "pause.fill" : "play.fill", size: 20, color: playColour)
        tick()
    }

    /// Progress and the lyric line, once a second.
    func tick() {
        guard let item = MediaObserver.shared.current, item.hasContent else { return }
        let position = item.position()
        progress.fraction = position.map { item.duration > 0 ? $0 / item.duration : 0 } ?? 0
        elapsed.stringValue = position.map { "\(Self.time($0)) / \(Self.time(item.duration))" } ?? ""
        let lines = LyricsProvider.shared.lines(title: item.title, artist: item.artist, duration: item.duration) ?? []
        let line = position.flatMap { now in LyricsProvider.current(in: lines, at: now + LyricsProvider.lead) } ?? ""
        lyric.stringValue = line
        lyric.isHidden = line.isEmpty
    }

    var debugText: String { details.isHidden ? "none" : "\(title.stringValue) – \(artist.stringValue)" }

    private static func time(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The cover's average colour, a little brighter (for the wash).
    static func averageColour(_ image: NSImage) -> NSColor? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .medium
        image.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        NSGraphicsContext.restoreGraphicsState()
        guard let colour = rep.colorAt(x: 0, y: 0) else { return nil }
        return colour.blended(withFraction: 0.25, of: .white)
    }
}

/// A thin rounded progress line.
final class HomeProgress: NSView {
    var fraction: Double = 0 { didSet { if fraction != oldValue { needsDisplay = true } } }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 4) }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2)
        NSColor(white: 1, alpha: 0.14).setFill()
        track.fill()
        let filled = NSRect(x: 0, y: 0, width: bounds.width * CGFloat(min(max(fraction, 0), 1)), height: bounds.height)
        NSColor(white: 1, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
    }
}

/// The system at a glance: CPU, memory, disk and battery rings, the
/// network rate and Keep Awake.
final class SystemTile: HomeTile {
    private let cpu = RingGauge(caption: "CPU", tint: StatusIcon.Tint.cpu)
    private let memory = RingGauge(caption: "Memory", tint: StatusIcon.Tint.memory)
    private let disk = RingGauge(caption: "Disk", tint: StatusIcon.Tint.disk)
    private let battery = RingGauge(caption: "Battery", tint: StatusIcon.Tint.charging)
    private let network = NSTextField(labelWithString: "")
    private lazy var awake = HomeLink("", symbol: KeepAwake.symbolName) { [weak self] in self?.awakeMenu() }

    init() {
        super.init(title: "System", symbol: "gauge.with.dots.needle.67percent", tint: SettingsSection.Tint.green)
        let rings = NSStackView(views: [cpu, memory, disk, battery])
        rings.distribution = .equalSpacing
        content.addArrangedSubview(rings)
        rings.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        network.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        network.textColor = NSColor(white: 1, alpha: 0.7)
        let line = NSStackView(views: [network, NSView(), awake])
        line.distribution = .fill
        content.addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }

    func update() {
        let stats = SystemStats.shared.snapshot
        cpu.value = stats.cpu
        memory.value = stats.memoryTotal > 0 ? Double(stats.memoryUsed) / Double(stats.memoryTotal) : nil
        disk.value = stats.diskTotal > 0 ? Double(stats.diskUsed) / Double(stats.diskTotal) : nil
        let info = stats.battery ?? BatteryInfo.read()
        battery.value = info.map { Double($0.percent) / 100 }
        if let info { battery.tint = StatusIcon.batteryTint(info) ?? .white }
        battery.detail = info.map { $0.charging ? L("Charging") : L("Battery") } ?? L("Battery")
        battery.isHidden = info == nil
        network.stringValue = "↓ \(SystemStats.rate(stats.netIn))   ↑ \(SystemStats.rate(stats.netOut))"
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
}

/// Today's to-dos (the first five), ticked off in place.
final class TodoTile: HomeTile {
    private let list = NSStackView()
    private let empty = HomeEmptyState(symbol: "checkmark.circle", title: "No to-dos",
                                       detail: "Nothing waiting. Add one when something comes up.")
    private let count = NSTextField(labelWithString: "")
    private(set) var debugCount = 0

    init() {
        super.init(title: "To-dos", symbol: "checklist", tint: SettingsSection.Tint.red)
        setAccessory(HomeLink("All", symbol: nil) { MainWindow.open(.tasks) })
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        count.font = .systemFont(ofSize: 11, weight: .medium)
        count.textColor = NSColor(white: 1, alpha: 0.45)
        content.addArrangedSubview(list)
        content.addArrangedSubview(empty)
        empty.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        content.addArrangedSubview(HomeLink("New to-do", symbol: "plus", color: StatusIcon.Tint.cpu) { MainWindow.open(.tasks) })
        list.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }

    func update() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let items = Array(TaskStore.shared.active.prefix(5))
        debugCount = items.count
        for item in items {
            let row = HomeTodoRow(item) { TaskStore.shared.complete(item.id) }
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        empty.isHidden = !items.isEmpty
    }
}

/// Quick actions: screenshots, pinning, and the pages used most.
final class ActionsTile: HomeTile {
    private(set) var debugCount = 0

    init() {
        super.init(title: "Quick Actions", symbol: "bolt.fill", tint: SettingsSection.Tint.yellow)
        typealias Tint = SettingsSection.Tint
        func url(_ command: String) -> () -> Void {
            { if let url = URL(string: "omnihub://\(command)") { NSWorkspace.shared.open(url) } }
        }
        let buttons = [
            HomeAction("Screenshot", symbol: "camera.viewfinder", tint: Tint.blue, action: url("snip")),
            HomeAction("Pin Image", symbol: "pin.fill", tint: Tint.purple, action: url("pin")),
            HomeAction("Terminal", symbol: "terminal.fill", tint: Tint.orange) { MainWindow.open(.terminal) },
            HomeAction("Clipboard", symbol: "doc.on.clipboard.fill", tint: Tint.teal) { MainWindow.open(.clipboard) },
            HomeAction("Shelf", symbol: "tray.full.fill", tint: Tint.yellow) { MainWindow.open(.shelf) },
            HomeAction("Agenda", symbol: "checklist", tint: Tint.red) { MainWindow.open(.tasks) }
        ]
        debugCount = buttons.count
        let grid = NSGridView(views: [Array(buttons.prefix(3)), Array(buttons.suffix(3))])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        for index in 0..<3 { grid.column(at: index).width = (MainHomeView.sideColumn - 32 - 16) / 3 }
        for button in buttons {
            button.widthAnchor.constraint(equalToConstant: (MainHomeView.sideColumn - 32 - 16) / 3).isActive = true
        }
        content.addArrangedSubview(grid)
    }
}

/// The cover, filling a rounded square (a 16:9 video frame is cropped, not
/// letterboxed).
final class CoverView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let clip = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSColor(white: 1, alpha: 0.06).setFill()
        clip.fill()
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                              width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
    }
}
