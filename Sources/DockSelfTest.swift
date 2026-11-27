import AppKit

/// Headless checks of the dock card (`OmniHub --dock-selftest`): page
/// widths, entry icons, header clicks, the Home to-do list, the Agenda
/// (open a to-do, Done history, Tab order), the player and pins.
/// To-dos it adds are removed again; nothing is put on the pasteboard.
enum DockSelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)\(ok || detail.isEmpty ? "" : "  — \(detail)")")
    }

    /// OMNIHUB_SNAP_DIR=<dir>: also save PNGs of the states checked.
    private static func snap(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["OMNIHUB_SNAP_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FloatingDockPanel.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    /// A to-do with a long title and a note of several lines: one line in
    /// every row, clear of the time; the Home preview shows all of it.
    private static func longTodo(_ long: TaskItem, note: String) {
        _ = FloatingDockPanel.debugCardSize(page: .home, x: 0.5, y: 0)
        let homeClash = FloatingDockPanel.debugTaskRowClashes
        check("Home to-do rows stay on one line, clear of the time", homeClash.isEmpty, homeClash.joined(separator: "; "))
        let preview = FloatingDockPanel.debugPreview
        // A real click, the card not key (OmniHub in the background).
        FloatingDockPanel.debugMouseClickTask(long.id)
        check("a real click on a Home to-do, the card not key (key=\(FloatingDockPanel.debugCardIsKey)), previews it",
              preview.taskID == long.id, "preview=\(String(describing: preview.taskID))")
        check("a click on a Home to-do previews it in full: title, time, the note with its line breaks; the card stays",
              preview.taskID == long.id && preview.debugText.contains("title=" + long.title)
                && preview.debugText.contains("note=" + note) && FloatingDockPanel.debugPage == .home,
              preview.debugText)
        let lit = FloatingDockPanel.debugPreviewedRows
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        check("the previewed row, and only it, gets the moving highlight" + (still ? " (still: Reduce Motion is on)" : ""),
              lit.count == 1 && lit.first?.id == long.id && (lit.first?.moving == !still), "\(lit)")
        snap("dock-home-previewed.png")
        if let dir = ProcessInfo.processInfo.environment["OMNIHUB_SNAP_DIR"] {
            preview.debugSnapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("dock-task-preview.png"))
        }
        FloatingDockPanel.debugMouseClickTask(long.id)
        check("a second click on the same to-do closes the preview and drops the highlight",
              preview.taskID == nil && FloatingDockPanel.debugPreviewedRows.isEmpty)

        FloatingDockPanel.debugMouseClickTask(long.id, count: 2)
        check("a real double-click, the card not key, opens the to-do in the Agenda (no preview left)",
              preview.taskID == nil && FloatingDockPanel.debugPage == .tasks && FloatingDockPanel.agenda.editingID == long.id,
              "page=\(String(describing: FloatingDockPanel.debugPage)) preview=\(String(describing: preview.taskID))")
        FloatingDockPanel.closeCard()
        _ = FloatingDockPanel.debugCardSize(page: .home, x: 0.5, y: 0)
        FloatingDockPanel.debugMouseClickTask(long.id)
        preview.debugEdit()
        let agenda = FloatingDockPanel.agenda
        check("Edit in the preview opens the to-do in the Agenda for editing",
              preview.taskID == nil && FloatingDockPanel.debugPage == .tasks && agenda.editingID == long.id,
              agenda.debugForm)
        let form = agenda.debugFormHeights
        let scrolled = agenda.debugEditNoteAtEnd()
        check("editing a note of a dozen lines: the box stays at 4 lines (\(Int(form.note)) pt) with a scroller and scrolls to its end "
              + "(\(Int(scrolled)) pt); the list keeps \(Int(form.list)) pt",
              form.note <= 76 && agenda.debugNoteScrollerShown && scrolled > 20 && form.list >= 120)
        let cardClash = agenda.debugRowClashes
        check("Agenda rows on the card: long title and note on one line each, clear of the time",
              cardClash.isEmpty, cardClash.joined(separator: "; "))
        snap("dock-agenda-long.png")
        FloatingDockPanel.closeCard()
        let window = MainWindow.debugOpen(.tasks)
        agenda.focus(taskID: long.id)
        let windowForm = agenda.debugFormHeights
        check("main window Agenda, the same note: 4 lines (\(Int(windowForm.note)) pt) with a scroller, the list keeps \(Int(windowForm.list)) pt",
              agenda.editingID == long.id && windowForm.note <= 76 && agenda.debugNoteScrollerShown && windowForm.list >= 200)
        if let dir = ProcessInfo.processInfo.environment["OMNIHUB_SNAP_DIR"], let view = window.contentView {
            view.layoutSubtreeIfNeeded()
            view.display()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("main-agenda-long-note.png"))
            }
        }
        agenda.debugNoteKey(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        let newLine = agenda.debugForm.contains("note=" + note + "\n button=")
        agenda.debugNoteKey(#selector(NSResponder.insertNewline(_:)))
        let savedNote = TaskStore.shared.item(long.id)?.note ?? ""
        check("in the note box Option-Return adds a line and Return saves",
              newLine && agenda.editingID == nil && savedNote == note,
              "editing=\(String(describing: agenda.editingID)) note ends \(savedNote.suffix(12).debugDescription)")
        agenda.focus(taskID: long.id)
        let windowClash = agenda.debugRowClashes
        check("Agenda rows in the main window: the same", windowClash.isEmpty, windowClash.joined(separator: "; "))
        _ = MainWindow.debugOpen(.home)

        _ = FloatingDockPanel.debugCardSize(page: .home, x: 0.5, y: 0)
        FloatingDockPanel.debugClickTask(long.id)
        preview.debugMarkDone()
        check("Mark done in the preview finishes the to-do and closes the preview",
              TaskStore.shared.item(long.id)?.done == true && preview.taskID == nil)
        FloatingDockPanel.closeCard()
    }

    /// + beside To-dos on Home: a field right there; Return adds a to-do
    /// with no date and keeps the field for the next; Esc or an empty
    /// Return closes it.
    private static func quickAddTodo() {
        let store = TaskStore.shared
        let before = Set(store.items.map(\.id))
        _ = FloatingDockPanel.debugCardSize(page: .home, x: 0.5, y: 0)
        let rowsBefore = FloatingDockPanel.debugTasks.rows
        // With music playing (player beside the list) and without: the
        // to-dos show as soon as Home opens, before + is touched.
        for playing in [true, false] {
            var song = MediaObserver.NowPlaying()
            song.title = "Test Song"; song.artist = "Tester"; song.isPlaying = true; song.duration = 200; song.elapsed = 20
            MediaObserver.shared.debugInject(playing ? song : nil)
            FloatingDockPanel.closeCard()
            _ = FloatingDockPanel.debugCardSize(page: .home, x: 0.5, y: 0)
            let visible = FloatingDockPanel.debugVisibleTaskRows
            let expected = min(store.active.count, max(1, Prefs.int("dock.taskLimit", 5)))
            check("Home \(playing ? "with music playing" : "with nothing playing"): \(visible.rows) of \(expected) to-dos show "
                  + "before + (list \(Int(visible.listHeight)) pt)", visible.rows == expected && expected > 0)
            snap(playing ? "dock-home-playing.png" : "dock-home-quiet.png")
        }
        FloatingDockPanel.debugQuickAdd(nil)
        let frames = FloatingDockPanel.debugQuickAddFrame
        check("+ on Home shows a field for a new to-do inside the card",
              FloatingDockPanel.debugQuickAddShown && frames.card.contains(frames.field) && frames.field.width > 150,
              "\(frames)")
        snap("dock-home-quick-add.png")
        FloatingDockPanel.debugQuickAdd("selftest quick to-do")
        let added = store.items.filter { !before.contains($0.id) }
        check("Return adds it to the Home list (no date); the field stays for the next one",
              added.count == 1 && added.first?.title == "selftest quick to-do" && added.first?.due == nil
                && FloatingDockPanel.debugTasks.rows == rowsBefore + 1 && FloatingDockPanel.debugQuickAddShown,
              "added=\(added.map(\.title)) rows \(rowsBefore)→\(FloatingDockPanel.debugTasks.rows)")
        FloatingDockPanel.debugQuickAdd("  ")
        check("Return on an empty field closes it, adding nothing",
              !FloatingDockPanel.debugQuickAddShown && store.items.filter { !before.contains($0.id) }.count == 1)
        FloatingDockPanel.debugQuickAdd(nil)
        FloatingDockPanel.debugQuickAddEscape()
        check("Esc closes the field", !FloatingDockPanel.debugQuickAddShown)
        for item in store.items where !before.contains(item.id) { store.remove(item.id) }
        FloatingDockPanel.closeCard()
    }

    static func run() {
        CalendarSource.allowPrompt = false
        FloatingDockPanel.headless = true
        typealias Page = FloatingDockPanel.Page
        let width = FloatingDockPanel.cardContentWidth

        // ---- order and entry icons
        check("entry order: Home, Activity, Agenda, Terminal, Shelf | Clipboard, Settings",
              Page.allCases == [.home, .activity, .tasks, .terminal, .shelf, .clipboard, .settings])
        _ = FloatingDockPanel.debugCardSize(page: .home, x: 0.5, y: 0)
        var nav = FloatingDockPanel.debugNav
        check("Clipboard and Settings sit at the far end of the entry row (Activity and Agenda are in the main window)",
              nav.leading == ["Home", "Terminal", "Shelf"] && nav.trailing == ["Clipboard", "Settings"],
              "\(nav)")
        Prefs.set("nav.show.terminal", false)
        _ = FloatingDockPanel.debugCardSize(page: .home, x: 0.5, y: 0)
        nav = FloatingDockPanel.debugNav
        check("an entry icon can be hidden in settings", !nav.leading.contains("Terminal"), "\(nav)")
        Prefs.set("nav.show.terminal", nil)

        // ---- widths
        let above = Page.allCases.map { ($0, FloatingDockPanel.debugCardSize(page: $0, x: 0.5, y: 0).width) }
        check("above / below the dock every page has the same width",
              Set(above.map { Int($0.1) }).count == 1, "\(above.map { "\($0.0.rawValue)=\(Int($0.1))" })")
        let beside = Page.allCases.map { ($0, FloatingDockPanel.debugCardSize(page: $0, x: 0, y: 0.5).width) }
        let wide = beside.filter { $0.0 != .home && $0.0 != .activity }.map { Int($0.1) }
        let narrow = beside.filter { $0.0 == .home || $0.0 == .activity }.map { Int($0.1) }
        check("beside the dock: Home and Activity stay narrow, the other pages share the width",
              Set(wide).count == 1 && narrow.allSatisfy { $0 < wide[0] }, "\(beside.map { "\($0.0.rawValue)=\(Int($0.1))" })")
        Prefs.set("dock.cardWidth", 720)
        let custom = FloatingDockPanel.debugCardSize(page: .clipboard, x: 0.5, y: 0).width
        check("card width follows the setting", Int(custom) - Int(above[4].1) == 720 - Int(width), "\(custom)")
        Prefs.set("dock.cardWidth", nil)

        // ---- header click: an open overlay goes first
        _ = FloatingDockPanel.debugCardSize(page: .settings, x: 0.5, y: 0)
        FloatingDockPanel.settings.select(tab: 5)
        snap("dock-settings-dock.png")
        _ = FloatingDockPanel.debugCardSize(page: .clipboard, x: 0, y: 0.5)
        snap("dock-side-clipboard.png")
        _ = FloatingDockPanel.debugCardSize(page: .terminal, x: 0.5, y: 0)
        FloatingDockPanel.terminal.openSettings(tab: 0)
        FloatingDockPanel.debugHeaderClick()
        check("header click with terminal settings open closes only the settings",
              FloatingDockPanel.terminal.debugSettings == nil && FloatingDockPanel.debugPage == .terminal)
        FloatingDockPanel.debugHeaderClick()
        check("header click on a bare page folds the card", FloatingDockPanel.debugPage == nil)

        // ---- a hotkey pins only the page it opened
        FloatingDockPanel.open(.terminal, toggle: false)
        let pinned = FloatingDockPanel.debugHeld
        FloatingDockPanel.debugTapNav(.terminal)
        let samePage = FloatingDockPanel.debugHeld
        FloatingDockPanel.debugTapNav(.home)
        check("a hotkey-opened page stays pinned; clicking another page unpins the card (it folds when it loses focus)",
              pinned && samePage && !FloatingDockPanel.debugHeld && FloatingDockPanel.debugPage == .home,
              "pinned=\(pinned) same page=\(samePage) after Home=\(FloatingDockPanel.debugHeld) page=\(String(describing: FloatingDockPanel.debugPage))")
        FloatingDockPanel.closeCard()
        FloatingDockPanel.terminateShells()

        // ---- a long to-do: rows hold it; a click on Home shows it in full
        let longNote = "第一行说明：" + String(repeating: "这是一段很长的内容说明，用来检查会不会溢出。", count: 4)
            + (1...10).map { "\n(\($0)) 第 \($0) 条意见：内容较长的一行说明" }.joined()
        if let long = TaskStore.shared.add(title: "selftest long " + String(repeating: "标题很长的事项", count: 8),
                                           note: longNote, due: Date().addingTimeInterval(3600)) {
            longTodo(long, note: longNote)
            TaskStore.shared.remove(long.id)
        } else {
            check("a long test to-do can be added", false)
        }
        quickAddTodo()

        // ---- Home to-dos: scrolling, double-click opens the Agenda
        let store = TaskStore.shared
        let before = Set(store.items.map(\.id))
        let added = (1...8).compactMap { store.add(title: "selftest to-do \($0)", note: "note \($0)", due: nil) }
        _ = FloatingDockPanel.debugCardSize(page: .home, x: 0.5, y: 0)
        snap("dock-home-todos.png")
        let tasks = FloatingDockPanel.debugTasks
        let limit = max(1, Prefs.int("dock.taskLimit", 5))
        check("Home lists every to-do and scrolls past \(limit) rows",
              tasks.rows >= 8 && tasks.scrollerShown && tasks.height == CGFloat(limit) * 22 + CGFloat(limit - 1) * 5,
              "\(tasks)")
        let target = added[6]
        FloatingDockPanel.debugOpenTask(target.id)
        let agenda = FloatingDockPanel.agenda
        check("double-clicking a Home to-do opens it in the Agenda for editing",
              FloatingDockPanel.debugPage == .tasks && agenda.editingID == target.id
                && agenda.debugForm.contains("title=selftest to-do 7") && agenda.debugForm.contains("button=Save")
                && agenda.debugForm.contains("highlighted=true"), agenda.debugForm)
        snap("dock-agenda-edit.png")
        check("Tab walks title → note → date → time → Save → Cancel",
              agenda.debugTabOrder == ["New to-do", "Note (optional)", "Date", "date picker", "Save", "Cancel"],
              "\(agenda.debugTabOrder)")
        store.complete(added[0].id)
        store.complete(added[1].id)
        agenda.debugShowDone(true)
        snap("dock-agenda-done.png")
        let doneRows = agenda.debugState
        check("the Agenda shows finished to-dos, newest first",
              doneRows.contains("done: selftest to-do 2") && doneRows.contains("done: selftest to-do 1")
                && (doneRows.range(of: "to-do 2")?.lowerBound ?? doneRows.endIndex) < (doneRows.range(of: "to-do 1")?.lowerBound ?? doneRows.startIndex),
              doneRows)
        agenda.debugShowDone(false)
        for item in store.items where !before.contains(item.id) { store.remove(item.id) }
        check("test to-dos removed again", Set(store.items.map(\.id)) == before)

        // ---- player: play mode / like, and no vanishing on an empty update
        var song = MediaObserver.NowPlaying()
        song.title = "Test Song"; song.artist = "Tester"; song.isPlaying = true
        song.shuffleMode = 3; song.repeatMode = 3; song.liked = true
        MediaObserver.shared.debugInject(song)
        _ = FloatingDockPanel.debugCardSize(page: .home, x: 0.5, y: 0)
        snap("dock-player.png")
        check("player shows play mode and like state", FloatingDockPanel.debugPlayerButtons.contains("mode=Play mode: shuffle")
              && FloatingDockPanel.debugPlayerButtons.contains("like=Unlike"), FloatingDockPanel.debugPlayerButtons)
        check("play mode mapping (order / repeat one / shuffle)",
              { var a = song; a.shuffleMode = 1; a.repeatMode = 3; var b = a; b.repeatMode = 2
                return MediaObserver.playMode(of: a) == .order && MediaObserver.playMode(of: b) == .repeatOne }())
        var opened = 0
        MediaObserver.shared.debugActivateHook = { opened += 1 }
        FloatingDockPanel.debugClickCover()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        MediaObserver.shared.debugActivateHook = nil
        check("a click on the player's cover opens the playing app", opened == 1, "opened \(opened)")
        // Settings › Show dock: off hides the ball at once, on brings it back.
        FloatingDockPanel.show()
        let settings = FloatingDockPanel.settings
        settings.debugSetDockShown(false)
        let hiddenNow = !FloatingDockPanel.debugVisible && Prefs.bool("dock.hidden")
        settings.debugSetDockShown(true)
        let backNow = FloatingDockPanel.debugVisible && !Prefs.bool("dock.hidden")
        settings.debugSetDockShown(false)
        settings.debugSetDockShown(true)
        check("Settings › Show dock: off hides the ball, on shows it again, twice over (\(hiddenNow), \(backNow))",
              hiddenNow && backNow && FloatingDockPanel.debugVisible)
        // Home (in the window) and the menu bar panel share one player: cover and words open the app.
        let homePlayer = NowPlayingTile()
        homePlayer.update()
        let clicks = homePlayer.debugClicks()
        opened = 0
        MediaObserver.shared.debugActivateHook = { opened += 1 }
        homePlayer.debugOpen()
        let panel = MenuBarPanel.debugContent()
        panel.debugOpenPlayer()
        MediaObserver.shared.debugActivateHook = nil
        MenuBarPanel.debugDidHide()
        check("Home's and the menu bar panel's player open the playing app (cover \(clicks.cover), words \(clicks.words))",
              clicks.cover && clicks.words && opened == 2, "opened \(opened)")
        // ---- music starts / stops with the card closed: ball and pill morph
        let morph = FloatingDockPanel.debugPillMorph()
        func between(_ widths: [CGFloat]) -> Int { widths.filter { $0 > morph.ball + 1 && $0 < morph.pill - 1 }.count }
        check("music starting: the ball grows into the pill step by step",
              between(morph.grow) >= 4 && zip(morph.grow, morph.grow.dropFirst()).allSatisfy { $0 <= $1 }
              && morph.grow.last == morph.pill, "\(morph.grow.map { Int($0) })")
        check("the pill's text fades in as it grows", morph.midAlpha > 0 && morph.midAlpha < 1, "\(morph.midAlpha)")
        check("music stopping: the pill draws back into the ball",
              between(morph.shrink) >= 4 && zip(morph.shrink, morph.shrink.dropFirst()).allSatisfy { $0 >= $1 }
              && morph.shrink.last == morph.ball, "\(morph.shrink.map { Int($0) })")
        // ---- the pill's line: the song until the first lyric, then the lyrics, rolling up
        let style = UserDefaults.standard.object(forKey: "dock.mediaStyle")
        Prefs.set("dock.mediaStyle", 1)
        var sung = song
        sung.title = "Ticker Song"; sung.duration = 200; sung.elapsed = 5; sung.anchor = Date()
        LyricsProvider.shared.debugSeed(title: sung.title, artist: sung.artist, duration: 200,
                                        lines: [.init(time: 10, text: "First line"), .init(time: 25, text: "Second line"),
                                                .init(time: 60, text: " ")])
        MediaObserver.shared.debugInject(sung)
        _ = FloatingDockPanel.debugBall(page: nil)
        let start = FloatingDockPanel.debugTicker()
        func at(_ seconds: Double) -> (text: String, rolls: Int) {
            sung.elapsed = seconds; sung.anchor = Date()
            MediaObserver.shared.debugInject(sung)
            return FloatingDockPanel.debugTicker()
        }
        let first = at(12), held = at(20), second = at(40), later = at(120)
        // In place half a second before it is sung: the roll starts that much plus its own length early.
        let early = MarqueeLabel.rollDuration + LyricsProvider.lead
        let notYet = at(25 - early - 0.4), rolling = at(25 - early + 0.05)
        check("pill line: the song before the first lyric, then each lyric held until the next (through a blank line) "
              + "(\(start.text) → \(first.text) → \(held.text) → \(second.text) → \(later.text))",
              start.text == "Ticker Song — Tester" && first.text == "First line" && held.text == "First line"
                && second.text == "Second line" && later.text == "Second line")
        check("pill line: the next lyric starts rolling \(early) s before it is sung (\(notYet.text) → \(rolling.text))",
              notYet.text == "First line" && rolling.text == "Second line")
        check("pill line: each new line rolls in, slowly (\(start.rolls) → \(first.rolls) → \(second.rolls), \(MarqueeLabel.rollDuration) s)",
              first.rolls == start.rolls + 1 && held.rolls == first.rolls && second.rolls == first.rolls + 1
                && later.rolls == second.rolls && MarqueeLabel.rollDuration >= 1)
        FloatingDockPanel.debugHideBall()
        UserDefaults.standard.set(style, forKey: "dock.mediaStyle")

        MediaObserver.shared.debugInject(song)
        let onHome = FloatingDockPanel.debugBall(page: .home)
        let onAgenda = FloatingDockPanel.debugBall(page: .tasks)
        let closed = FloatingDockPanel.debugBall(page: nil)
        check("while music plays the home page folds the pill to a ball; other pages keep the pill",
              onHome.width == morph.ball && !onHome.bars && onAgenda.width == morph.pill && onAgenda.bars
              && closed.width == morph.pill && closed.bars,
              "home=\(onHome) agenda=\(onAgenda) closed=\(closed)")
        _ = FloatingDockPanel.debugCardSize(page: .home, x: 0.5, y: 0)
        let followedItem: MediaObserver.NowPlaying = {
            var item = MediaObserver.NowPlaying(); item.title = "Video"; item.appName = "YouTube"; item.isFollowed = true; return item
        }()
        check("a player shown while another app holds Now Playing takes no commands, and says so",
              MediaObserver.followedReason(followedItem)?.contains("Open YouTube") == true
              && MediaObserver.followedReason(MediaObserver.NowPlaying()) == nil
              && { if case .unavailable = MediaObserver.shared.route(.playMode, for: followedItem) { return true }; return false }())
        check("player menus: play, pause, next, previous by whole title only",
              PlayerMenu.transport(of: "暂停") == .pause && PlayerMenu.transport(of: "播放") == .play
              && PlayerMenu.transport(of: "下一个") == .next && PlayerMenu.transport(of: "上一个") == .previous
              && PlayerMenu.transport(of: "Play/Pause") == .toggle
              && PlayerMenu.transport(of: "播放模式") == nil && PlayerMenu.transport(of: "Play Next") == nil
              && PlayerMenu.transport(of: "随机播放") == nil)
        var followedMusic = followedItem
        followedMusic.appName = "NeteaseMusic"; followedMusic.isMusic = true
        check("a music app shown while a video holds Now Playing still takes commands",
              MediaObserver.followedReason(followedMusic) == nil
              && { if case .unavailable = MediaObserver.shared.route(.playMode, for: followedMusic) { return false }; return true }())

        // ---- progress bar: press, drag and release plays from there
        var track = song
        track.isPlaying = false; track.duration = 200; track.elapsed = 10; track.anchor = Date()
        var sought: [Double] = []
        MediaObserver.shared.debugSeekHook = { sought.append($0) }
        MediaObserver.shared.debugInject(track)
        FloatingDockPanel.debugDragProgress(from: 0.25, to: 0.75)
        check("dragging the progress bar seeks once, where it is let go",
              sought.count == 1 && abs(sought[0] - 150) < 3, "\(sought)")
        sought = []
        var followedTrack = track
        followedTrack.isFollowed = true
        MediaObserver.shared.debugInject(followedTrack)
        FloatingDockPanel.debugDragProgress(from: 0.5, to: 0.5)
        var unsupported = track
        unsupported.commands = [0, 1, 2]
        MediaObserver.shared.debugInject(unsupported)
        FloatingDockPanel.debugDragProgress(from: 0.5, to: 0.5)
        check("no seek for a followed player or one without the seek command", sought.isEmpty, "\(sought)")
        MediaObserver.shared.debugSeekHook = nil
        MediaObserver.shared.debugInject(song)
        playerControls()
        MediaObserver.shared.debugApply(["title": "", "artist": "", "playing": false])
        check("an empty update (play mode switched in the player) keeps the player", MediaObserver.shared.current != nil)
        MediaObserver.shared.debugApply(["title": "Test Song", "artist": "Tester", "playing": true, "shuffle": 3, "repeat": 3])
        check("the same song comes back without the player flickering away", MediaObserver.shared.current?.title == "Test Song")
        MediaObserver.shared.debugApply(["title": "", "artist": "", "playing": false])
        DispatchQueue.main.asyncAfter(deadline: .now() + MediaObserver.emptyGrace + 0.6) {
            check("a player that stays silent is taken away after the grace time", MediaObserver.shared.current == nil)
            heldPlayer { pins() }
        }
    }

    /// Which way play mode / like go: MediaRemote when the player registered
    /// the command, its menu otherwise; and how menu items are picked.
    /// A player that clears what it publishes while still running (NetEase
    /// after switching shuffle) keeps its last song on screen. Steps are
    /// scheduled so the grace timer really runs between them.
    private static func heldPlayer(then done: @escaping () -> Void) {
        let observer = MediaObserver.shared
        let me = Int(getpid())
        let wait = MediaObserver.emptyGrace + 0.6
        let sample: [[String: Any]] = [["AssertionOnBehalfOfPID": NSNumber(value: 4242), "ResourcesUsed": ["audio-out", "x:output"]],
                                       ["AssertPID": NSNumber(value: 4243), "AssertType": "PreventUserIdleSystemSleep"]]
        check("audio output is read from the audio-out assertion coreaudiod holds for the player",
              PlayerActivity.isProducingAudio(4242, in: sample) && !PlayerActivity.isProducingAudio(4243, in: sample))

        observer.debugApply(["title": "Held", "artist": "T", "playing": true, "pid": me, "commands": [0, 1, 2, 4, 5]])
        observer.debugApply(["title": "", "artist": "", "playing": false, "pid": me, "commands": [0, 1, 2, 4, 5]])
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            check("the same running player clearing its info keeps the last song past the grace time",
                  observer.current?.title == "Held" && observer.isHolding, "\(String(describing: observer.current?.title))")
            check("a held song shows paused when the player sends no audio", observer.current?.isPlaying == false)

            observer.debugApply(["title": "Next", "artist": "T", "playing": true, "pid": me, "commands": [0, 1, 2, 4, 5]])
            check("a new report from the player ends the hold", observer.current?.title == "Next" && !observer.isHolding)

            observer.debugApply(["title": "", "artist": "", "playing": false, "commands": [0, 1, 2, 4, 5]])
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                check("an empty report from no known player still clears after the grace", observer.current == nil)
                observer.debugInject(nil)
                done()
            }
        }
    }

    private static func playerControls() {
        let bundle = "com.local.omnihub.selftest-player"
        MediaObserver.remember(.shuffle, for: bundle)
        let remembered = MediaObserver.rememberedMode(for: bundle)
        UserDefaults.standard.removeObject(forKey: "player.mode." + bundle)
        check("a player whose menu shows no state keeps the mode last set from OmniHub",
              remembered == .shuffle && MediaObserver.rememberedMode(for: bundle) == nil)

        let observer = MediaObserver.shared
        observer.debugApply(["title": "Basic", "artist": "T", "playing": true, "commands": [0, 1, 2, 4, 5]])
        let basic = observer.route(.playMode)
        // Never MediaRemote. Without Accessibility the reason asks for it;
        // with it, this fake player (no process, so no menu) has nothing to press.
        let expectedBasic: Bool = {
            switch basic {
            case .remote: return false
            case .menu: return PlayerMenu.isTrusted
            case .unavailable(let reason): return PlayerMenu.isTrusted || reason.contains("Accessibility")
            }
        }()
        check("a player with only play / pause / next / previous gets no MediaRemote mode command", expectedBasic, "\(basic)")
        observer.debugApply(["title": "Full", "artist": "T", "playing": true, "commands": [0, 1, 2, 4, 5, 21, 25, 26]])
        check("a player that registered shuffle / repeat / like is driven through MediaRemote",
              observer.route(.playMode) == .remote && observer.route(.like) == .remote)

        typealias E = PlayerMenu.Entry
        func entry(_ title: String, _ checked: Bool = false, _ path: [String] = ["控制", "播放模式"]) -> E {
            E(title: title, path: path, checked: checked, enabled: true, handle: 0)
        }
        let netease = [entry("顺序播放", true), entry("列表循环"), entry("单曲循环"), entry("随机播放"),
                       entry("喜欢歌曲", false, ["控制"])]
        check("menu: current mode from the check mark, next item picked",
              PlayerMenu.currentMode(netease) == .order
                && PlayerMenu.modeTarget(netease, next: .repeatOne)?.title == "单曲循环"
                && PlayerMenu.modeTarget(netease, next: .shuffle)?.title == "随机播放")
        check("menu: Like item picked; an unchecked single Like means not liked",
              PlayerMenu.likeTarget(netease, liked: false)?.title == "喜欢歌曲" && PlayerMenu.likedState(netease) == false)
        let liked = [entry("取消喜欢", false, ["Controls"]), entry("不喜欢", false, ["Controls"])]
        check("menu: an Unlike item means liked and is pressed to unlike; 不喜欢 is not Like",
              PlayerMenu.likedState(liked) == true && PlayerMenu.likeTarget(liked, liked: true)?.title == "取消喜欢"
                && !PlayerMenu.isLike("不喜欢"))
        check("menu: a player with only a Shuffle toggle cycles order ↔ shuffle",
              MediaObserver.nextMode(after: .order, offered: [.shuffle]) == .shuffle
                && MediaObserver.nextMode(after: .shuffle, offered: [.shuffle]) == .order
                && MediaObserver.nextMode(after: .order, offered: [.repeatOne, .shuffle]) == .repeatOne)
        let toggles = [entry("Shuffle", true, ["Controls"]), entry("Repeat One", false, ["Controls"])]
        check("menu: toggle-style players go back to order by switching the checked toggle off",
              PlayerMenu.currentMode(toggles) == .shuffle && PlayerMenu.modeTarget(toggles, next: .order)?.title == "Shuffle")
        var song = MediaObserver.NowPlaying()
        song.title = "Test Song"; song.artist = "Tester"; song.isPlaying = true
        song.shuffleMode = 3; song.repeatMode = 3; song.liked = true
        observer.debugInject(song)
    }

    private static func pins() {
        let image = NSImage(size: NSSize(width: 120, height: 80), flipped: false) { rect in
            NSColor.systemTeal.setFill(); rect.fill(); return true
        }
        PinnedImageWindow.pin(image, at: CGRect(x: 200, y: 200, width: 120, height: 80))
        PinnedImageWindow.pin(image, at: CGRect(x: 240, y: 230, width: 120, height: 80))
        let pins = PinnedImageWindow.debugPins
        check("pins float above the dock card", pins.allSatisfy { $0.level.rawValue > FloatingDockPanel.level.rawValue },
              "pin \(pins.first?.level.rawValue ?? -1) dock \(FloatingDockPanel.level.rawValue)")
        let newestOnTop = PinnedImageWindow.debugStacking
        pins.first?.debugClick()
        let afterClick = PinnedImageWindow.debugStacking
        // debugStacking lists pins oldest→newest by focus; values are front-to-back indexes.
        check("a new pin is above the older one; clicking the older one brings it up",
              newestOnTop.count == 2 && newestOnTop[1] < newestOnTop[0] && afterClick.count == 2 && afterClick[1] < afterClick[0]
                && PinnedImageWindow.debugPins.last === pins.first,
              "before \(newestOnTop) after \(afterClick)")
        PinnedImageWindow.closeAll()
        shelf()
    }

    /// Shelf: files copied in, listed, expired ones purged; the ball takes drops.
    private static func shelf() {
        let store = ShelfStore.shared
        let before = Set(store.items.map(\.id))
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("omnihub-shelf-test-\(getpid())")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let fileA = temp.appendingPathComponent("report.txt"), fileB = temp.appendingPathComponent("photos")
        try? "hello shelf".write(to: fileA, atomically: true, encoding: .utf8)
        try? FileManager.default.createDirectory(at: fileB, withIntermediateDirectories: true)
        try? Data(count: 2048).write(to: fileB.appendingPathComponent("a.bin"))
        check("the dock ball accepts dropped files", FloatingDockPanel.debugBallAcceptsFiles)
        store.add([fileA, fileB]) { added, failed in
            let mine = store.items.filter { !before.contains($0.id) }
            check("dropped files are copied onto the Shelf", added == 2 && failed.isEmpty && mine.count == 2
                    && mine.allSatisfy { FileManager.default.fileExists(atPath: store.url(of: $0).path) }
                    && FileManager.default.fileExists(atPath: fileA.path),
                  "added=\(added) failed=\(failed)")
            check("a folder keeps its size", mine.first { $0.isDirectory }?.size == 2048, "\(mine.map { "\($0.name)=\($0.size)" })")
            _ = FloatingDockPanel.debugCardSize(page: .shelf, x: 0.5, y: 0)
            snap("dock-shelf.png")
            let rows = FloatingDockPanel.shelf.debugRows
            check("the Shelf page lists them with size and time left",
                  rows.contains { $0.hasPrefix("report.txt |") && $0.contains("· \(ShelfStore.retentionDays)d left") }
                    && rows.contains { $0.hasPrefix("photos | Folder") }, "\(rows)")
            if let old = mine.first(where: { $0.name == "report.txt" }) {
                store.debugBackdate(old.id, days: Double(ShelfStore.retentionDays) + 0.5)
                let gone = store.purgeExpired()
                check("items past their days are cleared automatically",
                      gone == 1 && !store.items.contains { $0.id == old.id }
                        && !FileManager.default.fileExists(atPath: store.url(of: old).path))
            }
            Prefs.set(FloatingDockPanel.shelfKeepOpenKey, nil)
            let kept = FloatingDockPanel.debugShowShelfAfterDrop()
            Prefs.set(FloatingDockPanel.shelfKeepOpenKey, false)
            let folding = FloatingDockPanel.debugShowShelfAfterDrop()
            Prefs.set(FloatingDockPanel.shelfKeepOpenKey, nil)
            check("a drop keeps the Shelf in front by default; switched off it folds away like a hover",
                  kept.page == .shelf && kept.held && folding.page == .shelf && !folding.held,
                  "default=\(kept) off=\(folding)")
            for item in store.items where !before.contains(item.id) { store.remove(item.id) }
            try? FileManager.default.removeItem(at: temp)
            check("test items removed again", Set(store.items.map(\.id)) == before)
            finish()
        }
    }

    private static func finish() {
        print(failures == 0 ? "RESULT: all passed" : "RESULT: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
