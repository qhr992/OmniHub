import AppKit
import ServiceManagement

/// Checkbox bound to a boolean preference.
final class PrefCheckbox: FocusButton {
    private let key: String
    private let onChange: (() -> Void)?

    init(_ title: String, key: String, fallback: Bool, onChange: (() -> Void)? = nil) {
        self.key = key
        self.onChange = onChange
        self.fallback = fallback
        super.init(frame: .zero)
        setButtonType(.switch)
        self.title = L(title)
        state = Prefs.bool(key, fallback) ? .on : .off
        target = self
        action = #selector(toggled)
        // Kept in step when the same setting changes elsewhere (a menu).
        NotificationCenter.default.addObserver(self, selector: #selector(sync), name: .settingsChanged, object: nil)
    }

    private let fallback: Bool

    @objc private func sync() {
        let wanted: NSControl.StateValue = Prefs.bool(key, fallback) ? .on : .off
        if state != wanted { state = wanted }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggled() {
        Prefs.set(key, state == .on)
        onChange?()
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }
}

/// Pop-up bound to an integer preference.
final class PrefPopup: FocusPopUp {
    private let key: String
    private let values: [Int]

    init(key: String, fallback: Int, values: [Int], suffix: String) {
        self.key = key
        self.values = values
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: values.map { L("%ld " + suffix, $0) })
        selectItem(at: values.firstIndex(of: Prefs.int(key, fallback)) ?? 0)
        target = self
        action = #selector(changed)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() {
        guard indexOfSelectedItem >= 0, indexOfSelectedItem < values.count else { return }
        Prefs.set(key, values[indexOfSelectedItem])
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }
}

/// Pop-up with named choices, bound to an integer preference.
final class PrefChoice: FocusPopUp {
    private let key: String
    private let values: [Int]

    init(key: String, fallback: Int, options: [(Int, String)]) {
        self.key = key
        self.values = options.map(\.0)
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: options.map { L($0.1) })
        selectItem(at: values.firstIndex(of: Prefs.int(key, fallback)) ?? 0)
        target = self
        action = #selector(changed)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() {
        guard indexOfSelectedItem >= 0, indexOfSelectedItem < values.count else { return }
        Prefs.set(key, values[indexOfSelectedItem])
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }
}

/// Slider bound to an integer preference; the label follows the value.
final class PrefSlider: NSStackView {
    private let key: String
    private let slider: FocusSlider
    private let valueLabel = NSTextField(labelWithString: "")

    private let suffix: String

    init(key: String, fallback: Int, range: ClosedRange<Int>, width: CGFloat = 260, continuous: Bool = true,
         suffix: String = "") {
        self.key = key
        self.suffix = suffix
        slider = FocusSlider(value: Double(Prefs.int(key, fallback)), minValue: Double(range.lowerBound),
                          maxValue: Double(range.upperBound), target: nil, action: nil)
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 8
        slider.isContinuous = continuous
        slider.target = self
        slider.action = #selector(changed)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: width).isActive = true
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.stringValue = "\(Int(slider.doubleValue))\(suffix)"
        addArrangedSubview(slider)
        addArrangedSubview(valueLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() {
        let value = Int(slider.doubleValue.rounded())
        valueLabel.stringValue = "\(value)\(suffix)"
        Prefs.set(key, value)
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }
}

/// Settings, in the main window: every topic as a card first; a card opens
/// that topic's settings (Back returns to the cards).
final class SettingsPane: NSView, DockPage {
    private let tabs = NSTabView()
    /// Every topic as a card: what Settings opens on.
    private var overview: SettingsOverview?
    private let detail = NSView()
    /// The overview is showing (not one topic).
    private(set) var isOverview = true
    /// The overview / topic switch, for the window's title and Back.
    var onChange: (() -> Void)?
    private let loginCheckbox = FocusButton(checkboxWithTitle: L("Open at login"), target: nil, action: nil)
    private let languagePopup = FocusPopUp(frame: .zero, pullsDown: false)
    private let restartNote = NSTextField(labelWithString: L("Takes effect after OmniHub restarts."))
    private let updateStatus = NSTextField(labelWithString: "")
    private lazy var restartButton = button("Restart Now", #selector(restartNow))
    /// Shown only while a newer version is out.
    private lazy var updateButton = button("Update", #selector(updateNow))
    private let screenStatus = NSTextField(labelWithString: "")
    private let accessStatus = NSTextField(labelWithString: "")
    private let calendarStatus = NSTextField(labelWithString: "")
    private let completedLabel = NSTextField(labelWithString: "")
    private let historyLabel = NSTextField(labelWithString: "")
    private let dockVisible = FocusButton(checkboxWithTitle: L("Show dock"), target: nil, action: nil)
    private var statusTimer: Timer?
    /// Wrapping notes: their width follows the card's.
    private var hintFields: [NSTextField] = []

    init() {
        super.init(frame: .zero)
        buildContent()
        let center = NotificationCenter.default
        for name in [Notification.Name.tasksChanged, .clipboardChanged, .settingsChanged, .updateStatusChanged] {
            center.addObserver(self, selector: #selector(refreshStatus), name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func preferredSize(horizontal: Bool) -> NSSize { NSSize(width: 820, height: 520) }

    var tabCount: Int { tabs.numberOfTabViewItems }
    /// The tabs' English names (they are the identifiers).
    var tabTitles: [String] { tabs.tabViewItems.map { "\($0.identifier ?? "")" } }

    /// Opens one topic, from its top.
    func select(tab: Int, animated: Bool = false) {
        guard tab >= 0, tab < tabs.numberOfTabViewItems else { return }
        let moved = tab != selectedTab
        tabs.selectTabViewItem(at: tab)
        scrollToTop()
        // A topic to another one: the title still has to follow.
        if !setOverview(false, animated: animated), moved { onChange?() }
        flashScroller()
    }

    /// Back to every topic.
    func showOverview(animated: Bool = false) {
        setOverview(true, animated: animated)
    }

    /// True when it switched (and told `onChange`).
    @discardableResult
    private func setOverview(_ on: Bool, animated: Bool) -> Bool {
        let changed = on != isOverview
        isOverview = on
        overview?.isHidden = !on
        detail.isHidden = on
        if on, let focus = window?.firstResponder as? NSView, focus.isDescendant(of: detail) {
            window?.makeFirstResponder(nil)
        }
        if changed { onChange?() }
        guard animated, changed else { return changed }
        if on {
            overview?.animateIn()
        } else {
            MainWindowMotion.arrive(detail.layer, dx: MainWindowMotion.travel, dy: 0, duration: MainWindowMotion.settingsDuration)
        }
        return changed
    }

    private func scrollToTop() {
        guard let scroll = shownScroll else { return }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    var selectedTab: Int { tabs.selectedTabViewItem.map { tabs.indexOfTabViewItem($0) } ?? 0 }

    /// The shown topic's name (nil on the overview).
    var topicTitle: String? { isOverview ? nil : tabs.selectedTabViewItem?.label }

    /// The topic cards (test hook).
    var debugOverview: SettingsOverview? { overview }

    /// Icon and colour of each category, by its English name.
    private static func badge(_ title: String) -> (String, NSColor) {
        typealias Tint = SettingsSection.Tint
        switch title {
        case "General": return ("gearshape.fill", Tint.gray)
        case "Shortcuts": return ("command", Tint.indigo)
        case "Screenshot": return ("camera.viewfinder", Tint.blue)
        case "Clipboard": return ("doc.on.clipboard.fill", Tint.teal)
        case "Agenda": return ("calendar", Tint.red)
        case "Dock": return ("circle.circle.fill", Tint.purple)
        case "Appearance": return ("paintbrush.fill", Tint.pink)
        case "Activity": return ("gauge.with.dots.needle.67percent", Tint.green)
        case "Terminal": return ("terminal.fill", Tint.orange)
        default: return ("square.fill", Tint.gray)
        }
    }

    private var shownScroll: NSScrollView? { tabs.selectedTabViewItem?.view as? NSScrollView }

    /// The overlay scroller only shows while scrolling: flash it so a tab
    /// longer than the card shows there is more below.
    private func flashScroller() {
        DispatchQueue.main.async { [weak self] in
            guard let scroll = self?.shownScroll, let document = scroll.documentView,
                  document.frame.height > scroll.contentView.bounds.height + 1 else { return }
            scroll.flashScrollers()
        }
    }

    /// Test hook: the shown tab's content and visible heights, after
    /// scrolling it to the bottom.
    func debugScrollToBottom() -> (content: CGFloat, visible: CGFloat)? {
        guard let scroll = shownScroll, let document = scroll.documentView else { return nil }
        layoutSubtreeIfNeeded()
        let visible = scroll.contentView.bounds.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - visible)))
        scroll.reflectScrolledClipView(scroll.contentView)
        return (document.frame.height, visible)
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0 else { return }
        // Page margins (18 + 18), a card's indent (43) and margin (14).
        let wrap = max(200, min(640, bounds.width - 36 - 57))
        for field in hintFields where field.preferredMaxLayoutWidth != wrap { field.preferredMaxLayoutWidth = wrap }
    }

    /// Test hook: how far the shown topic is scrolled.
    var debugScrollOffset: CGFloat { shownScroll?.contentView.bounds.minY ?? 0 }

    /// Test hook: start recording a shortcut exactly as a click would.
    func debugRecord(_ action: HotKeyAction) -> Bool {
        func find(_ view: NSView) -> ShortcutRecorder? {
            if let recorder = view as? ShortcutRecorder, recorder.hotKeyAction == action { return recorder }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        for item in tabs.tabViewItems {
            if let view = item.view, let recorder = find(view) { recorder.performClick(nil); return true }
        }
        return false
    }

    func pageWillAppear() {
        refreshStatus()
        flashScroller()
        // Permissions are granted in System Settings, so poll while open.
        statusTimer?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.refreshStatus() }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    func pageDidDisappear() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    // MARK: Layout helpers

    /// A tab's content, scrolling when it is taller than the card.
    private func page(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // An overlay scroller floats over the page and takes no width: a
        // legacy one that comes and goes changes the width the page lays
        // out in, which can flip it on and off for ever.
        scroll.scrollerStyle = .overlay
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -14)
        ])
        for view in views where view is SettingsSection {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return scroll
    }

    func row(_ views: NSView...) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        return stack
    }

    func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: L(text))
        // A word some languages do without: no gap where it would be.
        field.isHidden = field.stringValue.isEmpty
        field.font = .systemFont(ofSize: 13)
        return field
    }

    func hint(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: L(text))
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = 520
        hintFields.append(field)
        return field
    }

    func heading(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: L(text))
        field.font = .systemFont(ofSize: 12, weight: .semibold)
        field.textColor = .secondaryLabelColor
        return field
    }

    func button(_ title: String, _ action: Selector) -> NSButton {
        let button = FocusButton(title: L(title), target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    /// A coloured group card.
    func section(_ title: String, _ symbol: String, _ tint: NSColor, _ views: [NSView]) -> NSView {
        SettingsSection(title: title, symbol: symbol, tint: tint, views: views)
    }

    private func addTab(_ title: String, _ views: [NSView]) {
        let item = NSTabViewItem(identifier: title)
        item.label = L(title)
        item.view = page(views)
        tabs.addTabViewItem(item)
    }

    // MARK: Pages

    private func buildContent() {
        // General
        loginCheckbox.target = self
        loginCheckbox.action = #selector(toggleLogin)
        languagePopup.addItems(withTitles: AppLanguage.allCases.map(\.displayName))
        languagePopup.selectItem(at: AppLanguage.allCases.firstIndex(of: AppLanguage.chosen) ?? 0)
        languagePopup.target = self
        languagePopup.action = #selector(languagePicked)
        restartNote.font = .systemFont(ofSize: 11)
        updateStatus.font = .systemFont(ofSize: 11)
        updateStatus.textColor = .secondaryLabelColor
        restartNote.textColor = .secondaryLabelColor
        updateLanguageNote()
        typealias Tint = SettingsSection.Tint
        addTab("General", [
            section("Language", "globe", Tint.blue, [row(languagePopup, restartNote, restartButton)]),
            section("Updates", "arrow.down.circle", Tint.green, [
                row(PrefCheckbox("Check for updates automatically", key: UpdateChecker.autoKey, fallback: true),
                    updateStatus, updateButton)
            ]),
            section("Startup", "power", Tint.orange, [
                loginCheckbox,
                row(PrefCheckbox("Startup animation", key: "boot.enabled", fallback: true),
                    PrefCheckbox("Sound", key: "boot.sound", fallback: true),
                    button("Preview", #selector(previewBoot)))
            ]),
            section("Permissions", "lock.shield", Tint.red, [
                row(screenStatus, button("Screen Recording Settings…", #selector(openScreenSettings))),
                hint("Needed for screenshots and pins. Restart OmniHub after granting."),
                row(accessStatus, button("Grant Accessibility…", #selector(requestAccessibility))),
                hint("Optional: lets players that take no commands from other apps (e.g. NetEase) switch play mode and like through their menus."),
                row(calendarStatus, button("Calendar Settings…", #selector(openCalendarSettings))),
                hint("Optional: shows your events in Agenda.")
            ])
        ])

        // Shortcuts
        var hotkeyRows: [NSView] = []
        for action in HotKeyAction.allCases {
            let name = label(action.title)
            name.translatesAutoresizingMaskIntoConstraints = false
            name.widthAnchor.constraint(equalToConstant: 190).isActive = true
            let clear = FocusButton(title: L("Clear"), target: self, action: #selector(clearHotKey(_:)))
            clear.bezelStyle = .rounded
            clear.controlSize = .small
            clear.tag = HotKeyAction.allCases.firstIndex(of: action) ?? 0
            let line = row(name, ShortcutRecorder(action: action), clear)
            line.spacing = 8
            hotkeyRows.append(line)
        }
        hotkeyRows.append(button("Reset All", #selector(resetHotKeys)))
        let keys = section("Global Shortcuts", "keyboard", Tint.indigo, hotkeyRows)
        (keys as? SettingsSection)?.content.spacing = 6
        addTab("Shortcuts", [keys])

        // Screenshot
        addTab("Screenshot", [
            section("Screenshot", "camera.viewfinder", Tint.teal, [
                PrefCheckbox("Detect windows on hover (click selects the window)", key: "snip.detectWindows", fallback: true),
                PrefCheckbox("Magnifier", key: "snip.magnifier", fallback: true),
                PrefCheckbox("Show “Copied” when done", key: "snip.toast", fallback: true)
            ])
        ])

        // Clipboard
        addTab("Clipboard", [
            section("Clipboard", "doc.on.clipboard", Tint.yellow, [
                row(label("Keep history"), PrefPopup(key: "clipboard.maxRecent", fallback: 120,
                                                   values: [50, 120, 300, 500], suffix: "items")),
                PrefCheckbox("Record images", key: "clipboard.images", fallback: true),
                row(historyLabel, button("Clear History", #selector(clearHistory)))
            ]),
            section("Shelf", "tray.full", Tint.orange, [
                row(label("Keep files for"), PrefPopup(key: "shelf.days", fallback: 7,
                                                     values: ShelfStore.retentionChoices, suffix: "days")),
                PrefCheckbox("Keep Shelf in front after a drop", key: FloatingDockPanel.shelfKeepOpenKey, fallback: true)
            ])
        ])

        // Agenda
        addTab("Agenda", [
            section("Agenda", "checklist", Tint.red, [
                row(label("Show on Home"), PrefPopup(key: "dock.taskLimit", fallback: 5,
                                                  values: [3, 5, 8, 10], suffix: "items")),
                PrefCheckbox("New to-dos have a date by default", key: "task.defaultDate", fallback: true),
                row(completedLabel, button("Clear Done", #selector(clearCompleted)))
            ])
        ])

        // dock
        dockVisible.target = self
        dockVisible.action = #selector(toggleDockVisible)
        addTab("Dock", [
            section("Dock", "circle.circle", Tint.blue, [
                dockVisible
            ]),
            section("While playing", "music.note", Tint.pink, [
                row(label("Dock shows"), PrefChoice(key: "dock.mediaStyle", fallback: 0,
                                                 options: [(0, "Spinning cover + bars"), (1, "Lyrics"), (2, "Static icon")])),
                row(label("Player length"), PrefSlider(key: "dock.pillWidth", fallback: 300, range: 84...680)),
                PrefCheckbox("Now Playing on Home", key: "dock.showMedia", fallback: true),
                PrefCheckbox("Holiday countdown on Home", key: "dock.showHoliday", fallback: true)
            ]),
            section("Card", "rectangle.on.rectangle", Tint.teal, [
                row(label("Card width"), PrefSlider(key: "dock.cardWidth", fallback: FloatingDockPanel.defaultCardWidth,
                                                    range: 480...1100, width: 220, continuous: false)),
                row(label("Entry icons"),
                    PrefCheckbox("Terminal", key: "nav.show.terminal", fallback: true),
                    PrefCheckbox("Shelf", key: "nav.show.shelf", fallback: true),
                    PrefCheckbox("Clipboard", key: "nav.show.clipboard", fallback: true))
            ])
        ])

        // Appearance
        addTab("Appearance", appearanceSections())

        // Activity
        addTab("Activity", [
            section("Activity page shows", "gauge.with.dots.needle.67percent", Tint.green, [
                row(PrefCheckbox("CPU", key: "activity.cpu", fallback: true),
                    PrefCheckbox("GPU", key: "activity.gpu", fallback: true),
                    PrefCheckbox("Memory", key: "activity.memory", fallback: true),
                    PrefCheckbox("Disk (usage and I/O)", key: "activity.disk", fallback: true)),
                row(PrefCheckbox("Network speed", key: "activity.network", fallback: true),
                    PrefCheckbox("Battery", key: "activity.battery", fallback: true),
                    PrefCheckbox("Keep Awake", key: "activity.keepAwake", fallback: true),
                    PrefCheckbox("Top apps", key: "activity.topApps", fallback: true)),
                row(PrefCheckbox("Local IP addresses", key: "activity.ip", fallback: true),
                    PrefCheckbox("Public IP (asks api.ipify.org)", key: "activity.publicIP", fallback: false)),
                row(label("Refresh every"), PrefChoice(key: "activity.interval", fallback: 2,
                                               options: [(1, "1 s"), (2, "2 s"), (5, "5 s")]))
            ])
        ])

        // Terminal
        var terminalRows: [NSView] = []
        for action in TerminalAction.common {
            let name = label(action.title)
            name.translatesAutoresizingMaskIntoConstraints = false
            name.widthAnchor.constraint(equalToConstant: 190).isActive = true
            let line = row(name, LocalKeyRecorder(action: action))
            line.spacing = 8
            terminalRows.append(line)
        }
        terminalRows.append(row(button("Open Config File", #selector(openKeymapFile)),
                                button("Reset", #selector(resetKeymap))))
        let terminal = section("Terminal Shortcuts", "terminal", Tint.gray, terminalRows)
        (terminal as? SettingsSection)?.content.spacing = 7
        addTab("Terminal", [terminal])

        // The overview is our own; the tab view only swaps the topics.
        tabs.tabViewType = .noTabsNoBorder
        tabs.drawsBackground = false
        tabs.translatesAutoresizingMaskIntoConstraints = false
        let grid = SettingsOverview(topics: tabs.tabViewItems.map { item in
            let title = "\(item.identifier ?? "")"
            let (symbol, tint) = Self.badge(title)
            let groups = Self.sectionTitles(in: item.view).map { L($0) }
            return SettingsOverview.Topic(title: title, symbol: symbol, tint: tint,
                                          detail: groups.joined(separator: " · "))
        })
        grid.onPick = { [weak self] index in self?.select(tab: index, animated: true) }
        overview = grid
        detail.wantsLayer = true
        detail.layer?.backgroundColor = NSColor(white: 1, alpha: 0.04).cgColor
        detail.layer?.cornerRadius = 12
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.isHidden = true
        addSubview(grid)
        addSubview(detail)
        detail.addSubview(tabs)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            detail.topAnchor.constraint(equalTo: topAnchor),
            detail.leadingAnchor.constraint(equalTo: leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor),
            tabs.topAnchor.constraint(equalTo: detail.topAnchor),
            tabs.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            tabs.bottomAnchor.constraint(equalTo: detail.bottomAnchor)
        ])
    }

    /// The group titles inside a topic, top to bottom.
    private static func sectionTitles(in view: NSView?) -> [String] {
        guard let view else { return [] }
        if let section = view as? SettingsSection { return [section.title] }
        return view.subviews.flatMap { sectionTitles(in: $0) }
    }

    // MARK: State

    @objc private func refreshStatus() {
        SystemStats.shared.restartIfRunning()
        screenStatus.stringValue = ScreenCapture.isTrusted() ? L("Screen Recording: granted ✓") : L("Screen Recording: not granted")
        screenStatus.textColor = ScreenCapture.isTrusted() ? .labelColor : .systemRed
        accessStatus.stringValue = AXIsProcessTrusted() ? L("Accessibility: granted ✓") : L("Accessibility: not granted")
        accessStatus.textColor = AXIsProcessTrusted() ? .labelColor : .systemRed
        let calendarOK = CalendarSource.shared.access == .granted
        calendarStatus.stringValue = calendarOK ? L("Calendar: granted ✓") : L("Calendar: not granted")
        calendarStatus.textColor = calendarOK ? .labelColor : .systemRed
        if #available(macOS 13.0, *) {
            loginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            loginCheckbox.isEnabled = false
        }
        completedLabel.stringValue = L("%ld done, %ld open", TaskStore.shared.completedCount, TaskStore.shared.active.count)
        historyLabel.stringValue = L("%ld in history, %ld starred",
                                     ClipboardStore.shared.recentItems.count, ClipboardStore.shared.pinnedItems.count)
        dockVisible.state = Prefs.bool("dock.hidden") ? .off : .on
        updateStatus.stringValue = UpdateChecker.shared.statusText
        let action = UpdateChecker.shared.actionTitle
        updateButton.isHidden = action == nil
        updateButton.isEnabled = UpdateChecker.shared.canAct
        if let action, updateButton.title != action { updateButton.title = action }
    }

    // MARK: Actions

    @objc private func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if loginCheckbox.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Toast.show(L("Open at login failed: %@", error.localizedDescription), duration: 2.5)
        }
        refreshStatus()
    }

    @objc private func languagePicked() {
        let index = languagePopup.indexOfSelectedItem
        guard AppLanguage.allCases.indices.contains(index) else { return }
        Prefs.set(AppLanguage.prefKey, AppLanguage.allCases[index].rawValue)
        updateLanguageNote()
    }

    /// The note and the restart button show while the language picked
    /// differs from the one on screen.
    private func updateLanguageNote() {
        let pending = AppLanguage.chosen != AppLanguage.current
        restartNote.isHidden = !pending
        restartButton.isHidden = !pending
    }

    /// Restarting closes the terminal's shells and ssh sessions, so ask
    /// first while any are open.
    @objc private func restartNow() {
        if let terminal = FloatingDockPanel.terminalIfCreated, terminal.openSessionCount > 0 {
            let alert = NSAlert()
            alert.messageText = L("Restart OmniHub?")
            alert.informativeText = L("Open terminal tabs will be closed.")
            alert.addButton(withTitle: L("Restart"))
            alert.addButton(withTitle: L("Cancel"))
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        AppRelaunch.now()
    }

    @objc private func updateNow() { UpdateChecker.shared.updateNow() }

    @objc private func previewBoot() { BootAnimation.playIfEnabled(force: true) }
    @objc private func openScreenSettings() { ScreenCapture.openPrivacySettings() }

    @objc private func openCalendarSettings() {
        if CalendarSource.shared.access == .undetermined {
            CalendarSource.shared.requestIfNeeded { [weak self] in self?.refreshStatus() }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @objc private func clearHotKey(_ sender: NSButton) {
        guard sender.tag < HotKeyAction.allCases.count else { return }
        HotKeyCenter.shared.set(nil, for: HotKeyAction.allCases[sender.tag])
    }

    @objc private func resetHotKeys() { HotKeyCenter.shared.resetAll() }
    @objc private func clearHistory() { ClipboardStore.shared.clearRecent() }
    @objc private func clearCompleted() { TaskStore.shared.clearCompleted() }
    @objc private func toggleDockVisible() {
        Prefs.set("dock.hidden", dockVisible.state == .off)
        refreshStatus()
    }
    @objc func chooseIcon() { FloatingDockPanel.chooseIcon() }
    @objc func resetIcon() { FloatingDockPanel.resetIcon() }
    @objc private func openKeymapFile() {
        TerminalKeymap.shared.reloadIfChanged()
        NSWorkspace.shared.open(TerminalKeymap.fileURL)
    }
    @objc private func resetKeymap() { TerminalKeymap.shared.resetToDefaults() }
}
