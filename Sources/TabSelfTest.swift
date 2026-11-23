import AppKit

/// Headless keyboard checks of the dock card (`OmniHub --tab-selftest`).
///
/// Real Tab / ⇧Tab key events go to the card: in every settings tab, in the
/// terminal settings (Connections, Vault, Proxies) and in the Agenda form,
/// Tab must visit every control once, in layout order, and wrap around; ⇧Tab
/// goes back. Every control that changes a setting must be a Tab stop.
/// Also: the terminal's block cursor is light on the dark card.
/// A connection, password entry or proxy it adds (only when that list is
/// empty) is deleted again; settings it touches are put back.
enum TabSelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)\(ok || detail.isEmpty ? "" : "  — \(detail)")")
    }

    /// Opening pages moves the dock (test layout); put it back afterwards.
    private static let savedKeys = ["dock.posX", "dock.posY"]
    private static var saved: [String: Any] = [:]

    static func run() {
        for key in savedKeys { saved[key] = UserDefaults.standard.object(forKey: key) }
        CalendarSource.allowPrompt = false
        FloatingDockPanel.headless = true
        settingsTabs()
        agenda()
        terminal()
    }

    /// OMNIHUB_SNAP_DIR=<dir>: also save PNGs of the card.
    private static func snap(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["OMNIHUB_SNAP_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FloatingDockPanel.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    // MARK: Key events

    private static func key(_ window: NSWindow, code: UInt16, characters: String) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: code) else { return }
        window.sendEvent(event)
    }

    private static func press(_ window: NSWindow, backwards: Bool = false) {
        let characters = backwards ? "\u{19}" : "\t"
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: backwards ? [.shift] : [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: 48) else { return }
        window.sendEvent(event)
    }

    private static func name(_ view: NSView?) -> String {
        guard let view else { return "nothing" }
        switch view {
        case let field as NSTextField: return "[\(field.placeholderString ?? field.stringValue)]"
        case let popup as NSPopUpButton: return "popup(\(popup.titleOfSelectedItem ?? ""))"
        case is NSSlider: return "slider"
        case is NSSegmentedControl: return "segments"
        case is NSTableView: return "list"
        case let button as NSButton:
            return button.image != nil && button.imagePosition == .imageOnly || button.title.isEmpty
                ? "button(\(button.toolTip ?? "?"))" : "button(\(button.title))"
        default: return "\(type(of: view))"
        }
    }

    /// Every control in `scope` a person can use (labels and scroll bars
    /// aside), panels shown over it left out.
    private static func controls(in scope: NSView) -> [NSView] {
        var result: [NSView] = []
        func visit(_ view: NSView) {
            guard !view.isHidden else { return }
            if view !== scope, view is TabScope { return }
            if let control = view as? NSControl {
                let label = (control as? NSTextField).map { !$0.isEditable } ?? false
                if control.isEnabled, !label, !(control is NSScroller), control.bounds.width > 0 {
                    result.append(control)
                }
                return
            }
            view.subviews.forEach(visit)
        }
        visit(scope)
        return result
    }

    /// Top to bottom, and left to right within a line.
    private static func inLayoutOrder(_ views: [NSView]) -> Bool {
        let frames = views.map { $0.convert($0.bounds, to: nil) }
        return zip(frames, frames.dropFirst()).allSatisfy { a, b in
            abs(a.midY - b.midY) <= 4 ? b.minX > a.minX : b.midY < a.midY
        }
    }

    /// Focuses the first stop, then presses Tab once per stop: the focus
    /// must go round the stops in order and come back; ⇧Tab steps back.
    @discardableResult
    private static func walk(_ title: String, scope: NSView, window: FloatingDockPanel,
                             layoutOrder: [NSView]? = nil) -> [NSView] {
        scope.layoutSubtreeIfNeeded()
        let stops = TabOrder.stops(in: scope)
        print("      \(title): \(stops.map(name).joined(separator: " → "))")
        guard let first = stops.first, window.makeFirstResponder(first) else {
            check("\(title): has controls to Tab through", false, "no stops")
            return []
        }
        var visited: [NSView?] = []
        for _ in stops.indices {
            press(window)
            visited.append(window.focusedControl)
        }
        let expected = Array(stops.dropFirst()) + [first]
        let same = visited.count == expected.count && zip(visited, expected).allSatisfy { $0 === $1 }
        check("\(title): Tab goes through all \(stops.count) controls in order and wraps", same,
              "got \(visited.map(name))")
        press(window, backwards: true)
        check("\(title): ⇧Tab goes back", window.focusedControl === stops.last, "at \(name(window.focusedControl))")

        let missing = controls(in: scope).filter { control in !stops.contains { $0 === control } }
        check("\(title): every control is a Tab stop", missing.isEmpty, "skipped \(missing.map(name))")
        let ordered = layoutOrder ?? stops
        check("\(title): the order follows the layout", inLayoutOrder(ordered),
              "\(ordered.map { "\(name($0))@\(Int($0.convert($0.bounds, to: nil).midY))" })")
        return stops
    }

    // MARK: Pages

    private static func settingsTabs() {
        _ = FloatingDockPanel.debugCardSize(page: .settings, x: 0.5, y: 0)
        let pane = FloatingDockPanel.settings
        guard let window = pane.window as? FloatingDockPanel else {
            check("settings page is in the card", false)
            return
        }
        let titles = ["General", "Shortcuts", "Screenshot", "Clipboard", "Agenda", "Dock", "Activity", "Terminal"]
        for (index, title) in titles.enumerated() {
            pane.select(tab: index)
            walk("Settings › \(title)", scope: pane, window: window)
        }
        // Space works a focused check box (pressed twice: the setting is left as it was).
        pane.select(tab: 2)
        if let box = TabOrder.stops(in: pane).first(where: { ($0 as? NSButton)?.title == "Magnifier" }) as? NSButton {
            let before = box.state
            let stored = UserDefaults.standard.object(forKey: "snip.magnifier")
            defer { UserDefaults.standard.set(stored, forKey: "snip.magnifier") }
            window.makeFirstResponder(box)
            key(window, code: 49, characters: " ")
            let flipped = box.state != before && Prefs.bool("snip.magnifier", true) == (box.state == .on)
            key(window, code: 49, characters: " ")
            check("Settings: Space toggles the focused check box (and its setting)", flipped && box.state == before)
        } else {
            check("Settings: Space toggles the focused check box", false, "no Magnifier box")
        }
        // ← / → on the focused tab strip switch the settings tab.
        if let strip = TabOrder.stops(in: pane).first as? NSSegmentedControl {
            window.makeFirstResponder(strip)
            key(window, code: 124, characters: "\u{F703}")
            let right = strip.selectedSegment
            key(window, code: 123, characters: "\u{F702}")
            check("Settings: ← / → on the tab strip switch tabs", right == 3 && strip.selectedSegment == 2,
                  "→ \(right), ← \(strip.selectedSegment)")
        }

        // Nothing focused yet: Tab starts at the top of the page.
        window.makeFirstResponder(nil)
        press(window)
        check("Settings: with nothing focused, Tab starts at the tab strip",
              window.focusedControl is NSSegmentedControl, "at \(name(window.focusedControl))")
    }

    private static func agenda() {
        _ = FloatingDockPanel.debugCardSize(page: .tasks, x: 0.5, y: 0)
        guard let page = FloatingDockPanel.debugShownPage, let window = page.window as? FloatingDockPanel,
              let titleField = TabOrder.stops(in: page).first(where: { ($0 as? NSTextField)?.placeholderString == "New to-do" }) else {
            check("Agenda form is on the page", false)
            return
        }
        window.makeFirstResponder(titleField)
        press(window)
        let afterTitle = window.focusedControl
        check("Agenda: Tab moves from the title to the note",
              (afterTitle as? NSTextField)?.placeholderString == "Note (optional)", "at \(name(afterTitle))")
        var form: [String] = []
        for _ in 0..<4 {
            press(window)
            form.append(name(window.focusedControl))
        }
        check("Agenda: the form keeps its order (title → note → date → time → Add)",
              Array(form.prefix(3)) == ["button(Date)", "NSDatePicker", "button(Add)"], "\(form)")
        window.makeFirstResponder(afterTitle)
        press(window, backwards: true)
        check("Agenda: ⇧Tab moves back to the title", window.focusedControl === titleField,
              "at \(name(window.focusedControl))")
    }

    private static func terminal() {
        _ = FloatingDockPanel.debugCardSize(page: .terminal, x: 0.5, y: 0)
        let pane = FloatingDockPanel.terminal
        pane.pageWillAppear()
        guard let window = pane.window as? FloatingDockPanel else {
            check("terminal page is in the card", false)
            return finish()
        }
        // ---- cursor
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, (pane.activeSession?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        cursorChecks(pane.activeSession)

        // ---- settings panel
        pane.debugToggle("settings")
        let scope = TabOrder.topScope(in: pane)
        guard let settings = scope as? TerminalSettingsView else {
            check("terminal settings open over the page", false, "\(type(of: scope))")
            return finish()
        }
        let titles = ["Connections", "Vault", "Proxies"]
        for (index, title) in titles.enumerated() {
            settings.select(tab: index)
            let editor = settings.debugEditor
            var added: Bool = false
            if !editor.debugList.contains(where: { !$0.hasPrefix("[") }) {
                editor.debugAdd()
                added = true
            }
            settings.layoutSubtreeIfNeeded()
            let formStops = TabOrder.stops(in: settings).filter { $0.isDescendant(of: editor.form) }
            walk("Terminal settings › \(title)", scope: settings, window: window, layoutOrder: formStops)
            if index == 0 {
                window.makeFirstResponder(formStops.first)
                snap("tab-terminal-settings.png")
            }
            if added { editor.debugDelete() }
        }
        window.makeFirstResponder(nil)
        press(window)
        check("Terminal settings: with nothing focused, Tab starts inside the settings panel",
              window.focusedControl.map { $0.isDescendant(of: settings) } ?? false, "at \(name(window.focusedControl))")
        pane.debugToggle("settings")
        pane.terminateAll()
        finish()
    }

    /// The cursor is light on the dark card and breathes while focused:
    /// sampled through its real timer at the start, middle and end of a cycle.
    private static func cursorChecks(_ session: TerminalSession?) {
        guard let session else { return check("terminal: a shell tab is open", false) }
        func sample(at seconds: TimeInterval, from start: Date) -> NSColor? {
            RunLoop.main.run(until: start.addingTimeInterval(seconds))
            return session.debugCursorColor
        }
        func describe(_ color: NSColor?) -> String {
            guard let color else { return "none" }
            return String(format: "rgb %.2f %.2f %.2f alpha %.2f", color.redComponent, color.greenComponent,
                          color.blueComponent, color.alphaComponent)
        }
        let period = TerminalCursor.period
        TerminalCursor.debugAlwaysFocused = true
        session.debugRestartCursor()
        let start = Date()
        let bright = sample(at: 0.05, from: start)
        snap("tab-terminal-cursor.png")
        let faint = sample(at: period / 2, from: start)
        snap("tab-terminal-cursor-faint.png")
        let again = sample(at: period * 0.98, from: start)
        let light = bright.map { $0.redComponent * 0.3 + $0.greenComponent * 0.59 + $0.blueComponent * 0.11 } ?? 0
        check("terminal: the block cursor is light on the dark card", light > 0.7 && (bright?.alphaComponent ?? 0) >= 0.8,
              describe(bright))
        check("terminal: focused, the cursor breathes — bright, faint half way through, bright again",
              (bright?.alphaComponent ?? 0) >= 0.8 && (faint?.alphaComponent ?? 1) <= 0.2
                && (again?.alphaComponent ?? 0) >= 0.75,
              "start \(describe(bright)) · middle \(describe(faint)) · end \(describe(again))")
        TerminalCursor.debugAlwaysFocused = false
        session.debugCursorFocusChanged()
        let rest = Date()
        let still = [sample(at: 0.1, from: rest), sample(at: period / 2, from: rest)].map { $0?.alphaComponent ?? -1 }
        check("terminal: without the keyboard the cursor rests as a steady dim block",
              still.allSatisfy { abs($0 - TerminalCursor.resting) < 0.01 }, "\(still)")
    }

    private static func finish() {
        for key in savedKeys { UserDefaults.standard.set(saved[key], forKey: key) }
        print(failures == 0 ? "RESULT: all passed" : "RESULT: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
