import AppKit

/// Checks of the main window and the trimmed card (`OmniHub --main-selftest
/// [dir]`): which pages the card keeps, every page laid out in the window,
/// pages handed between card and window, and Settings' category column.
/// With a folder, a picture of each page is saved there.
enum MainSelfTest {
    private static var failures = 0
    typealias Page = FloatingDockPanel.Page

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)\(ok || detail.isEmpty ? "" : "  — \(detail)")")
    }

    private static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }

    static func run(pictures: URL?) {
        setlinebuf(stdout)
        CalendarSource.allowPrompt = false
        FloatingDockPanel.headless = true
        let saved = ["dock.posX", "dock.posY", "main.page"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        if let pictures { try? FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true) }

        card()
        pages(pictures: pictures)
        sharing()
        settings(pictures: pictures)

        for (key, value) in saved { Prefs.set(key, value) }
        print(failures == 0 ? "RESULT: all passed" : "RESULT: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    /// The card keeps Home, Terminal, Shelf | Clipboard, Settings; the
    /// others open in the window, and so does the card's Settings icon.
    private static func card() {
        _ = FloatingDockPanel.debugCardSize(page: .home, x: 0.5, y: 0)
        let nav = FloatingDockPanel.debugNav
        check("card entry icons: Home, Terminal, Shelf | Clipboard, Settings",
              nav.leading == ["Home", "Terminal", "Shelf"] && nav.trailing == ["Clipboard", "Settings"], "\(nav)")

        for target in [Page.activity, .tasks, .settings] {
            FloatingDockPanel.open(target, toggle: false)
            settle()
            check("\(target.rawValue) opens in the main window, not the card",
                  MainWindow.debugWindow?.page == target && FloatingDockPanel.debugPage != target,
                  "\(MainWindow.debugState) card=\(FloatingDockPanel.debugPage?.rawValue ?? "-")")
        }

        _ = FloatingDockPanel.debugCardSize(page: .home, x: 0.5, y: 0)
        FloatingDockPanel.debugTapNav(.settings)
        settle()
        check("the card's Settings icon opens Settings in the main window and folds the card",
              MainWindow.debugWindow?.page == .settings && FloatingDockPanel.debugPage == nil,
              "\(MainWindow.debugState) card=\(FloatingDockPanel.debugPage?.rawValue ?? "-")")

        FloatingDockPanel.open(.terminal, toggle: false)
        settle()
        check("Terminal still opens in the card", FloatingDockPanel.debugPage == .terminal)
        FloatingDockPanel.closeCard()
    }

    /// Every page fills the window's content area.
    private static func pages(pictures: URL?) {
        let window = MainWindow.debugOpen(.home)
        let titles = window.debugSidebar.titles
        check("sidebar: \(titles.joined(separator: ", "))",
              titles == ["Home", "Activity", "Agenda", "Terminal", "Shelf", "Clipboard", "Settings"])
        let rows = window.debugSidebar.rows.map { $0.convert($0.bounds, to: nil) }
        check("sidebar rows stacked down one column",
              Set(rows.map { Int($0.minX) }).count == 1 && zip(rows, rows.dropFirst()).allSatisfy { $0.0.minY > $0.1.minY })

        for target in MainWindow.pages {
            let window = MainWindow.debugOpen(target)
            let host = window.debugHost.bounds.size
            let view = window.debugShown
            let size = view?.frame.size ?? .zero
            let inWindow = view?.isDescendant(of: window.debugHost) ?? false
            // Home and Activity scroll: as wide as the area; the rest fill it.
            let fits = [.home, .activity].contains(target)
                ? abs(size.width - host.width) <= 2 && size.height > 200
                : abs(size.width - host.width) <= 1 && abs(size.height - host.height) <= 1
            check("\(target.rawValue): in the window, \(Int(size.width))×\(Int(size.height)) in \(Int(host.width))×\(Int(host.height))",
                  inWindow && fits)
            // Not the clipboard: its picture would show the user's history.
            if let pictures, target != .clipboard {
                snapshot(window, to: pictures.appendingPathComponent("main-\(target.rawValue).png"))
            }
        }

        // Settings takes the whole window, with Back to the page before it.
        _ = MainWindow.debugOpen(.activity)
        let settingsWindow = MainWindow.debugOpen(.settings)
        let settingsLeft = settingsWindow.debugHost.convert(settingsWindow.debugHost.bounds, to: nil).minX
        check("settings: no page list, Back shown, the settings start at the left edge (x \(Int(settingsLeft)))",
              !settingsWindow.debugListShown && settingsWindow.debugBackShown && settingsLeft < 40)
        settingsWindow.debugBack()
        let afterBack = settingsWindow.page
        check("Back returns to the page before Settings (\(afterBack.rawValue)), with the list again",
              afterBack == .activity && settingsWindow.debugListShown && !settingsWindow.debugBackShown)
        let small = MainWindow.debugOpen(.settings, size: NSSize(width: 860, height: 540))
        let host = small.debugHost.bounds.size
        check("settings at the smallest window: fills \(Int(host.width))×\(Int(host.height))",
              abs((small.debugShown?.frame.width ?? 0) - host.width) <= 1)
        _ = MainWindow.debugOpen(.settings)
    }

    /// One view per page: the card borrows it, the window takes it back.
    private static func sharing() {
        let window = MainWindow.debugOpen(.clipboard)
        _ = FloatingDockPanel.debugCardSize(page: .clipboard, x: 0.5, y: 0)
        settle()
        check("the card borrows Clipboard from the window (which says so)",
              FloatingDockPanel.debugPage == .clipboard && window.debugPlaceholderShown)
        _ = MainWindow.debugOpen(.clipboard)
        settle()
        let host = window.debugHost.bounds.size
        let size = window.debugShown?.frame.size ?? .zero
        check("the window takes it back, the card folds, its pinned size is dropped (\(Int(size.width))×\(Int(size.height)))",
              FloatingDockPanel.debugPage == nil && !window.debugPlaceholderShown
                && abs(size.width - host.width) <= 1 && abs(size.height - host.height) <= 1)

        // Home: the window has its own; the card keeps its compact one.
        let homeWindow = MainWindow.debugOpen(.home)
        _ = FloatingDockPanel.debugCardSize(page: .home, x: 0.5, y: 0)
        settle()
        check("Home in the window stays while the card shows its own",
              FloatingDockPanel.debugPage == .home && homeWindow.debugShown === homeWindow.debugHome
                && !homeWindow.debugPlaceholderShown)
        FloatingDockPanel.closeCard()
        let text = homeWindow.debugHome.debugText
        check("Home: greeting, date, clock, six quick actions (\(text))",
              !text.contains("greeting= ") && text.contains("clock=") && text.contains("actions=6"))
        let height = homeWindow.debugHome.frame.height
        check("Home: hero and two rows of cards (\(Int(height)) pt tall)", height > 300)
        for target in MainWindow.pages {
            _ = MainWindow.debugOpen(target)
            settle()
            if window.debugPlaceholderShown { check("no card note on \(target.rawValue) while it is shown", false) }
        }
    }

    /// Settings: every topic as a card; a card opens the topic, Back
    /// returns to the cards, then to the page before Settings.
    private static func settings(pictures: URL?) {
        let pane = FloatingDockPanel.settings
        MainWindow.open(.settings, settingsTab: 6)
        let window = MainWindow.debugOpen(.activity)
        MainWindow.open(.settings, settingsTab: 6)
        check("open(.settings, tab 6) goes straight to Appearance, titled so (\(window.debugTitle))",
              pane.selectedTab == 6 && !pane.isOverview && window.debugTitle == L("Appearance") && window.debugBackShown)
        window.debugBack()
        check("Back from a topic: the overview, still in Settings (\(window.debugTitle))",
              pane.isOverview && window.page == .settings && window.debugTitle == L("Settings"))
        guard let overview = pane.debugOverview else {
            check("settings has an overview", false)
            return
        }
        settle()
        let cards = overview.cards.map { $0.convert($0.bounds, to: nil) }
        let columns = Set(cards.map { Int($0.minX) }).count
        let rows = Set(cards.map { Int($0.minY) }).count
        check("overview: \(cards.count) topics in \(columns) columns × \(rows) rows, none empty",
              cards.count == pane.tabCount && columns == SettingsOverview.columns
                && rows == (cards.count + columns - 1) / columns && cards.allSatisfy { $0.width > 150 && $0.height > 80 })
        overview.cards[2].performClick(nil)
        check("clicking a topic opens it (\(window.debugTitle))",
              pane.selectedTab == 2 && !pane.isOverview && window.debugTitle == L("Screenshot"))
        pane.select(tab: 6)
        check("one topic to another: the title follows (\(window.debugTitle))", window.debugTitle == L("Appearance"))
        if let pictures {
            pane.showOverview()
            settle()
            snapshot(window, to: pictures.appendingPathComponent("main-settings-overview.png"))
            for (tab, name) in [(0, "general"), (6, "appearance")] {
                pane.select(tab: tab)
                settle()
                snapshot(window, to: pictures.appendingPathComponent("main-settings-\(name).png"))
            }
        }
        // Leave on a topic, scrolled down; coming back starts over.
        pane.select(tab: 6)
        _ = pane.debugScrollToBottom()
        window.debugBack()
        window.debugBack()
        check("Back from the overview: the page before Settings", window.page == .activity && !window.debugBackShown)
        pane.select(tab: 6)
        _ = MainWindow.debugOpen(.settings)
        check("entering Settings again starts at the overview", pane.isOverview && window.debugTitle == L("Settings"))
        pane.select(tab: 6)
        check("a topic opens at its top", pane.debugScrollOffset == 0, "offset \(pane.debugScrollOffset)")
        pane.showOverview()
    }

    private static func snapshot(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
