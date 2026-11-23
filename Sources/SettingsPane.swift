import AppKit
import ServiceManagement

/// Checkbox bound to a boolean preference.
final class PrefCheckbox: FocusButton {
    private let key: String
    private let onChange: (() -> Void)?

    init(_ title: String, key: String, fallback: Bool, onChange: (() -> Void)? = nil) {
        self.key = key
        self.onChange = onChange
        super.init(frame: .zero)
        setButtonType(.switch)
        self.title = title
        state = Prefs.bool(key, fallback) ? .on : .off
        target = self
        action = #selector(toggled)
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
        addItems(withTitles: values.map { "\($0) \(suffix)" })
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
        addItems(withTitles: options.map(\.1))
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

    init(key: String, fallback: Int, range: ClosedRange<Int>, width: CGFloat = 260, continuous: Bool = true) {
        self.key = key
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
        valueLabel.stringValue = "\(Int(slider.doubleValue))"
        addArrangedSubview(slider)
        addArrangedSubview(valueLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() {
        let value = Int(slider.doubleValue.rounded())
        valueLabel.stringValue = "\(value)"
        Prefs.set(key, value)
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }
}

/// Settings page of the dock card: one tab per module.
final class SettingsPane: NSView, DockPage {
    private let tabs = NSTabView()
    private let tabPicker = FocusSegments()
    private let loginCheckbox = FocusButton(checkboxWithTitle: "Open at login", target: nil, action: nil)
    private let screenStatus = NSTextField(labelWithString: "")
    private let accessStatus = NSTextField(labelWithString: "")
    private let calendarStatus = NSTextField(labelWithString: "")
    private let completedLabel = NSTextField(labelWithString: "")
    private let historyLabel = NSTextField(labelWithString: "")
    private let dockVisible = FocusButton(checkboxWithTitle: "Show dock", target: nil, action: nil)
    private var statusTimer: Timer?

    init() {
        super.init(frame: .zero)
        buildContent()
        let center = NotificationCenter.default
        for name in [Notification.Name.tasksChanged, .clipboardChanged, .settingsChanged] {
            center.addObserver(self, selector: #selector(refreshStatus), name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func preferredSize(horizontal: Bool) -> NSSize { NSSize(width: 640, height: 430) }

    func select(tab: Int) {
        guard tab >= 0, tab < tabs.numberOfTabViewItems else { return }
        tabs.selectTabViewItem(at: tab)
        tabPicker.selectedSegment = tab
    }

    @objc private func tabPicked() { tabs.selectTabViewItem(at: tabPicker.selectedSegment) }

    /// Eight tabs must fit the card's width: in a narrow card the strip
    /// uses a smaller font and shares the width out evenly.
    override func layout() {
        super.layout()
        let count = tabPicker.segmentCount
        guard count > 0, bounds.width > 0 else { return }
        let narrow = bounds.width < 640
        let font = NSFont.systemFont(ofSize: narrow ? 11 : NSFont.systemFontSize)
        if tabPicker.font != font { tabPicker.font = font }
        // Each tab gets its label's width plus an equal share of what is left.
        let texts = (0..<count).map { ((tabPicker.label(forSegment: $0) ?? "") as NSString).size(withAttributes: [.font: font]).width }
        let spare = max(0, bounds.width - 4 - CGFloat(count) * 1.5 - texts.reduce(0, +)) / CGFloat(count)
        for index in 0..<count {
            let width = narrow ? floor(texts[index] + spare) : 0
            if tabPicker.width(forSegment: index) != width { tabPicker.setWidth(width, forSegment: index) }
        }
    }

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

    private func page(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -18)
        ])
        return container
    }

    private func row(_ views: NSView...) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        return stack
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13)
        return field
    }

    private func hint(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = 520
        return field
    }

    private func heading(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12, weight: .semibold)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = FocusButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func addTab(_ title: String, _ views: [NSView]) {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = page(views)
        tabs.addTabViewItem(item)
    }

    // MARK: Pages

    private func buildContent() {
        // General
        loginCheckbox.target = self
        loginCheckbox.action = #selector(toggleLogin)
        addTab("General", [
            heading("Startup"),
            loginCheckbox,
            row(PrefCheckbox("Startup animation", key: "boot.enabled", fallback: true),
                PrefCheckbox("Sound", key: "boot.sound", fallback: true),
                button("Preview", #selector(previewBoot))),
            heading("Menu Bar Icon"),
            row(PrefCheckbox("Runner", key: "status.animated", fallback: true),
                label("Follows"), PrefChoice(key: "status.metric", fallback: 0, options: [(0, "Memory"), (1, "CPU")])),
            heading("Permissions"),
            row(screenStatus, button("Screen Recording Settings…", #selector(openScreenSettings))),
            hint("Needed for screenshots and pins. Restart OmniHub after granting."),
            row(accessStatus, button("Grant Accessibility…", #selector(requestAccessibility))),
            hint("Optional: lets players that take no commands from other apps (e.g. NetEase) switch play mode and like through their menus."),
            row(calendarStatus, button("Calendar Settings…", #selector(openCalendarSettings))),
            hint("Optional: shows your events in Agenda.")
        ])

        // Shortcuts
        var hotkeyRows: [NSView] = [hint("Global shortcuts. Click a button, then press the new keys. ⌫ clears, Esc cancels.")]
        for action in HotKeyAction.allCases {
            let name = label(action.title)
            name.translatesAutoresizingMaskIntoConstraints = false
            name.widthAnchor.constraint(equalToConstant: 190).isActive = true
            let clear = FocusButton(title: "Clear", target: self, action: #selector(clearHotKey(_:)))
            clear.bezelStyle = .rounded
            clear.controlSize = .small
            clear.tag = HotKeyAction.allCases.firstIndex(of: action) ?? 0
            let line = row(name, ShortcutRecorder(action: action), clear)
            line.spacing = 8
            hotkeyRows.append(line)
        }
        hotkeyRows.append(button("Reset All", #selector(resetHotKeys)))
        let hotkeys = page(hotkeyRows)
        (hotkeys.subviews.first as? NSStackView)?.spacing = 6
        let hotkeyItem = NSTabViewItem(identifier: "Shortcuts")
        hotkeyItem.label = "Shortcuts"
        hotkeyItem.view = hotkeys
        tabs.addTabViewItem(hotkeyItem)

        // Screenshot
        addTab("Screenshot", [
            PrefCheckbox("Detect windows on hover (click selects the window)", key: "snip.detectWindows", fallback: true),
            PrefCheckbox("Magnifier", key: "snip.magnifier", fallback: true),
            PrefCheckbox("Show “Copied” when done", key: "snip.toast", fallback: true),
            heading("Scrolling Screenshot"),
            hint("Start from the screenshot toolbar, or give it a shortcut, then scroll down yourself. It stops a few seconds after you stop, or on Esc / Done."),
            heading("Pins"),
            hint("Zoom with scroll, pinch, or the − ＋ buttons shown on hover; × closes. Text in a pin can be selected and copied.")
        ])

        // Clipboard
        addTab("Clipboard", [
            row(label("Keep history"), PrefPopup(key: "clipboard.maxRecent", fallback: 120,
                                               values: [50, 120, 300, 500], suffix: "items")),
            PrefCheckbox("Record images", key: "clipboard.images", fallback: true),
            row(historyLabel, button("Clear History", #selector(clearHistory))),
            hint("Starred items are kept. Double-click an item to copy it and close the card."),
            heading("Shelf"),
            row(label("Keep files for"), PrefPopup(key: "shelf.days", fallback: 7,
                                                 values: ShelfStore.retentionChoices, suffix: "days")),
            PrefCheckbox("Keep Shelf in front after a drop", key: FloatingDockPanel.shelfKeepOpenKey, fallback: true),
            hint("Drop files on the dock ball to keep a copy on the Shelf. Older ones are deleted automatically. "
                 + "Off: the Shelf folds away when the pointer leaves, like a hover-opened card.")
        ])

        // Agenda
        addTab("Agenda", [
            row(label("Show on Home"), PrefPopup(key: "dock.taskLimit", fallback: 5,
                                              values: [3, 5, 8, 10], suffix: "items")),
            PrefCheckbox("New to-dos have a date by default", key: "task.defaultDate", fallback: true),
            row(completedLabel, button("Clear Done", #selector(clearCompleted))),
            hint("The month view reads your Mac Calendar (macOS asks once). Pick a day to see its events and to-dos.")
        ])

        // dock
        dockVisible.target = self
        dockVisible.action = #selector(toggleDockVisible)
        addTab("Dock", [
            dockVisible,
            heading("While playing"),
            row(label("Dock shows"), PrefChoice(key: "dock.mediaStyle", fallback: 0,
                                             options: [(0, "Spinning cover + bars"), (1, "Lyrics"), (2, "Static icon")])),
            row(label("Player length"), PrefSlider(key: "dock.pillWidth", fallback: 300, range: 84...680)),
            hint("Far left = cover and bars only. Lyrics come from NetEase / LRCLIB (title shown if none); long text scrolls."),
            PrefCheckbox("Now Playing on Home", key: "dock.showMedia", fallback: true),
            PrefCheckbox("Holiday countdown on Home", key: "dock.showHoliday", fallback: true),
            heading("Card"),
            row(label("Card width"), PrefSlider(key: "dock.cardWidth", fallback: FloatingDockPanel.defaultCardWidth,
                                                range: 480...1100, width: 220, continuous: false)),
            hint("Every page has this width (beside the dock, Home and Activity keep their narrow column). Default \(FloatingDockPanel.defaultCardWidth) = Home above or below the dock."),
            row(label("Entry icons"),
                PrefCheckbox("Activity", key: "nav.show.activity", fallback: true),
                PrefCheckbox("Agenda", key: "nav.show.tasks", fallback: true),
                PrefCheckbox("Terminal", key: "nav.show.terminal", fallback: true),
                PrefCheckbox("Shelf", key: "nav.show.shelf", fallback: true),
                PrefCheckbox("Clipboard", key: "nav.show.clipboard", fallback: true)),
            hint("Home and Settings are always shown. Hidden pages still open with their shortcuts."),
            heading("Icon"),
            row(button("Choose Image…", #selector(chooseIcon)), button("Default Icon", #selector(resetIcon))),
            hint("Touch the dock and the card opens beside it; the dock stays visible and can be dragged anywhere.")
        ])

        // Activity
        addTab("Activity", [
            heading("Activity page shows"),
            PrefCheckbox("CPU", key: "activity.cpu", fallback: true),
            PrefCheckbox("GPU", key: "activity.gpu", fallback: true),
            PrefCheckbox("Memory", key: "activity.memory", fallback: true),
            PrefCheckbox("Disk (usage and I/O)", key: "activity.disk", fallback: true),
            PrefCheckbox("Local IP addresses", key: "activity.ip", fallback: true),
            PrefCheckbox("Public IP (asks api.ipify.org)", key: "activity.publicIP", fallback: false),
            row(label("Refresh every"), PrefChoice(key: "activity.interval", fallback: 2,
                                           options: [(1, "1 s"), (2, "2 s"), (5, "5 s")]))
        ])

        // Terminal
        var terminalRows: [NSView] = [hint("Same shortcuts as macOS Terminal. Common ones can be changed here; the rest (copy, paste, font size, paging, ⌘1–9…) are in the config file.")]
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
        terminalRows.append(hint("Connections, Vault and Proxies: the gear at the top right of the Terminal page."))
        let terminal = page(terminalRows)
        (terminal.subviews.first as? NSStackView)?.spacing = 7
        let terminalItem = NSTabViewItem(identifier: "Terminal")
        terminalItem.label = "Terminal"
        terminalItem.view = terminal
        tabs.addTabViewItem(terminalItem)

        // The tab strip is our own segmented control; the tab view only
        // swaps the pages.
        tabs.tabViewType = .noTabsNoBorder
        tabs.drawsBackground = false
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabPicker.segmentCount = tabs.numberOfTabViewItems
        for (index, item) in tabs.tabViewItems.enumerated() {
            tabPicker.setLabel(item.label, forSegment: index)
        }
        tabPicker.trackingMode = .selectOne
        tabPicker.selectedSegment = 0
        tabPicker.target = self
        tabPicker.action = #selector(tabPicked)
        tabPicker.translatesAutoresizingMaskIntoConstraints = false
        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(white: 1, alpha: 0.05).cgColor
        panel.layer?.cornerRadius = 10
        panel.translatesAutoresizingMaskIntoConstraints = false
        // The tab strip first: Tab goes through the subviews in this order.
        addSubview(tabPicker)
        addSubview(panel)
        panel.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabPicker.topAnchor.constraint(equalTo: topAnchor),
            tabPicker.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.topAnchor.constraint(equalTo: tabPicker.bottomAnchor, constant: 8),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            tabs.topAnchor.constraint(equalTo: panel.topAnchor),
            tabs.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            tabs.bottomAnchor.constraint(equalTo: panel.bottomAnchor)
        ])
    }

    // MARK: State

    @objc private func refreshStatus() {
        SystemStats.shared.restartIfRunning()
        screenStatus.stringValue = "Screen Recording: " + (ScreenCapture.isTrusted() ? "granted ✓" : "not granted")
        screenStatus.textColor = ScreenCapture.isTrusted() ? .labelColor : .systemRed
        accessStatus.stringValue = "Accessibility: " + (AXIsProcessTrusted() ? "granted ✓" : "not granted")
        accessStatus.textColor = AXIsProcessTrusted() ? .labelColor : .systemRed
        let calendarOK = CalendarSource.shared.access == .granted
        calendarStatus.stringValue = "Calendar: " + (calendarOK ? "granted ✓" : "not granted")
        calendarStatus.textColor = calendarOK ? .labelColor : .systemRed
        if #available(macOS 13.0, *) {
            loginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            loginCheckbox.isEnabled = false
        }
        completedLabel.stringValue = "\(TaskStore.shared.completedCount) done, \(TaskStore.shared.active.count) open"
        historyLabel.stringValue = "\(ClipboardStore.shared.recentItems.count) in history, \(ClipboardStore.shared.pinnedItems.count) starred"
        dockVisible.state = Prefs.bool("dock.hidden") ? .off : .on
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
            Toast.show("Open at login failed: \(error.localizedDescription)", duration: 2.5)
        }
        refreshStatus()
    }

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
    @objc private func chooseIcon() { FloatingDockPanel.chooseIcon() }
    @objc private func resetIcon() { FloatingDockPanel.resetIcon() }
    @objc private func openKeymapFile() {
        TerminalKeymap.shared.reloadIfChanged()
        NSWorkspace.shared.open(TerminalKeymap.fileURL)
    }
    @objc private func resetKeymap() { TerminalKeymap.shared.resetToDefaults() }
}
