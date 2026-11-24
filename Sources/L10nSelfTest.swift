import AppKit

/// Headless check of the Chinese interface (`OmniHub --l10n-selftest [dir]`).
///
/// Runs in Simplified Chinese whatever language is picked in Settings. Every
/// page of the card (each settings tab, the terminal settings panels) is
/// opened and every text on screen read — labels, placeholders, buttons,
/// menu items, segments, tool tips. A text that is still English although
/// the table has a translation for it means a string was not passed through
/// `L(…)`. With a directory, a picture of each page is saved there.
enum L10nSelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)\(ok || detail.isEmpty ? "" : "  — \(detail)")")
    }

    static func run(pictures: URL?) {
        CalendarSource.allowPrompt = false
        FloatingDockPanel.headless = true
        let position = (Prefs.double("dock.posX", 0.5), Prefs.double("dock.posY", 0))
        defer {
            Prefs.set("dock.posX", position.0)
            Prefs.set("dock.posY", position.1)
        }
        formats()

        func page(_ page: FloatingDockPanel.Page, _ name: String) -> NSView? {
            _ = FloatingDockPanel.debugCardSize(page: page, x: 0.5, y: 0)
            guard let view = FloatingDockPanel.debugShownPage else {
                check("\(name): page opens", false)
                return nil
            }
            view.layoutSubtreeIfNeeded()
            return view
        }
        func inspect(_ view: NSView, _ name: String) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            view.layoutSubtreeIfNeeded()
            let texts = Self.texts(in: view)
            let english = texts.filter(AppLanguage.hasTranslation)
            check("\(name): \(texts.count) texts, none left in English", english.isEmpty, "\(english)")
            if let pictures {
                _ = FloatingDockPanel.snapshot(to: pictures.appendingPathComponent("\(name).png"))
            }
        }

        for (kind, name) in [(FloatingDockPanel.Page.home, "home"), (.activity, "activity"), (.tasks, "agenda"),
                             (.shelf, "shelf"), (.clipboard, "clipboard")] {
            if let view = page(kind, name) { inspect(view, name) }
        }
        let settings = FloatingDockPanel.settings
        if page(.settings, "settings") != nil {
            for index in 0..<settings.tabCount {
                settings.select(tab: index)
                inspect(settings, "settings-\(index + 1)")
            }
            // General is longer than the card: it scrolls to its last row.
            settings.select(tab: 0)
            if let size = settings.debugScrollToBottom() {
                check("settings-1 scrolls: \(Int(size.content)) pt of content in \(Int(size.visible)) pt",
                      size.content > size.visible && size.visible > 100)
                inspect(settings, "settings-1-bottom")
            } else {
                check("settings-1 scrolls", false)
            }
        }
        let terminal = FloatingDockPanel.terminal
        if page(.terminal, "terminal") != nil {
            terminal.pageWillAppear()
            inspect(terminal, "terminal")
            terminal.debugToggle("settings")
            if let panel = TabOrder.topScope(in: terminal) as? TerminalSettingsView {
                for index in 0..<3 {
                    panel.select(tab: index)
                    inspect(panel, "terminal-settings-\(index + 1)")
                }
            } else {
                check("terminal settings open", false)
            }
            terminal.debugToggle("settings")
            terminal.terminateAll()
        }
        print(failures == 0 ? "RESULT: all passed" : "RESULT: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    /// Formats with arguments, numbered arguments and plain lookups.
    private static func formats() {
        check("language is Chinese", AppLanguage.current == .chinese)
        check("plain text", L("Settings") == "设置", L("Settings"))
        check("format with a number", L("%ld items", 5) == "5 条", L("%ld items", 5))
        check("numbered arguments", L("%ldd to %@", 12, L("National Day")) == "距国庆还有 12 天",
              L("%ldd to %@", 12, L("National Day")))
        check("a text with no translation stays as it is", L("OmniHub") == "OmniHub")
        check("page titles", FloatingDockPanel.Page.allCases.map(\.title)
                .allSatisfy { !AppLanguage.hasTranslation($0) })
    }

    /// Every text a person can read in `view` and below it.
    private static func texts(in view: NSView) -> [String] {
        var result: [String] = []
        func add(_ text: String?) {
            guard let text, !text.isEmpty else { return }
            result.append(text)
        }
        func visit(_ view: NSView) {
            guard !view.isHidden else { return }
            add(view.toolTip)
            switch view {
            case let field as NSTextField:
                add(field.stringValue)
                add(field.placeholderString)
            case let popup as NSPopUpButton:
                popup.itemTitles.forEach(add)
            case let segments as NSSegmentedControl:
                (0..<segments.segmentCount).forEach { add(segments.label(forSegment: $0)) }
            case let button as NSButton:
                add(button.title)
            default:
                break
            }
            if view is NSTextView { return }      // the shell's output
            view.subviews.forEach(visit)
        }
        visit(view)
        return result
    }
}
