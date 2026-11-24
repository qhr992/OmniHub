import AppKit
import Carbon.HIToolbox

// MARK: - Screen geometry helpers

enum ScreenGeometry {
    static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return CGDirectDisplayID(number?.uint32Value ?? 0)
    }

    /// CG global point (origin top-left) -> AppKit global point (origin bottom-left).
    static func appKitPoint(fromCG point: CGPoint, on screen: NSScreen) -> CGPoint {
        let bounds = CGDisplayBounds(displayID(for: screen))
        return CGPoint(x: point.x, y: screen.frame.maxY - (point.y - bounds.minY))
    }

    static func screen(containing cgPoint: CGPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            CGDisplayBounds(displayID(for: screen)).contains(cgPoint)
        } ?? NSScreen.main
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    /// The menu bar icon's menu, shown on a right (or Control-) click.
    private var statusMenu: NSMenu!
    private var statusRunner: StatusRunner?
    private var lastDebug = ""
    private var controller: OverlayController?
    private var isSnipActive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        let args = CommandLine.arguments
        let isToolRun = args.contains { $0.hasPrefix("--") }

        // A second copy would register every hotkey twice.
        if !isToolRun, let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if !others.isEmpty { exit(0) }
        }

        NSApp.setActivationPolicy(.accessory)
        migrateLegacyPreferences()

        // `--render <dir>`: draw the UI into PNG files without showing a
        // single window, then exit. Nothing else is started.
        if let index = args.firstIndex(of: "--render"), index + 1 < args.count {
            runRender(into: URL(fileURLWithPath: args[index + 1], isDirectory: true))
            return
        }

        // `--parse-tunnels <file>`: what the Port Forwarding list makes of a
        // saved server probe (ServerTunnels.probeScript output).
        if let index = args.firstIndex(of: "--parse-tunnels"), index + 1 < args.count {
            let text = (try? String(contentsOfFile: args[index + 1], encoding: .utf8)) ?? ""
            ServerTunnels.parse(text).forEach { print("\($0.summary) | \($0.state)") }
            exit(0)
        }

        // `--askpass-selftest`: a vault password must only reach an ssh that
        // OmniHub itself started, never a process that just sets the env var.
        if args.contains("--vault-selftest") {
            VaultSelfTest.run()
        }

        if args.contains("--askpass-selftest") {
            // A Keychain service of its own: the real vault is not touched.
            let service = "com.local.omnihub.vault.askpass-selftest"
            Vault.service = service
            let id = "askpass-selftest-\(getpid())"
            _ = Vault.set("leak-check-42", for: id)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: RemoteTarget.executable)
            process.arguments = ["Password:"]
            process.environment = ["OMNIHUB_ASKPASS_SECRET": id, "OMNIHUB_VAULT_SERVICE": service]
            let pipe = Pipe()
            process.standardOutput = pipe
            try? process.run()
            process.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            Vault.debugDeleteAll()
            let leaked = output.contains("leak-check-42")
            print(leaked ? "FAIL  a process that is not OmniHub's ssh got the vault password (exit \(process.terminationStatus))"
                         : "PASS  askpass refuses a caller that is not an ssh started by OmniHub (exit \(process.terminationStatus))")
            exit(leaked ? 1 : 0)
        }

        if args.contains("--snip-selftest") {
            SnipSelfTest.run()
            return
        }

        if args.contains("--dock-selftest") {
            DockSelfTest.run()
            return
        }

        if let index = args.firstIndex(of: "--l10n-selftest") {
            let folder = index + 1 < args.count ? URL(fileURLWithPath: args[index + 1], isDirectory: true) : nil
            L10nSelfTest.run(pictures: folder)
            return
        }
        if let index = args.firstIndex(of: "--status-selftest") {
            let folder = index + 1 < args.count ? URL(fileURLWithPath: args[index + 1], isDirectory: true) : nil
            StatusSelfTest.run(pictures: folder)
            return
        }
        if let index = args.firstIndex(of: "--main-selftest") {
            let folder = index + 1 < args.count ? URL(fileURLWithPath: args[index + 1], isDirectory: true) : nil
            MainSelfTest.run(pictures: folder)
            return
        }
        if args.contains("--tab-selftest") {
            TabSelfTest.run()
            return
        }

        // `--zoom-render <dir>`: frames of the card's zoom transitions.
        if let index = args.firstIndex(of: "--zoom-render"), index + 1 < args.count {
            let directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            CalendarSource.allowPrompt = false
            FloatingDockPanel.headless = true
            typealias P = FloatingDockPanel.Page
            var runs: [(String, P, P)] = [("open", .home, .home), ("switch", .home, .settings),
                                          ("switch", .settings, .home), ("switch", .tasks, .clipboard),
                                          ("close", .terminal, .home)]
            // OMNIHUB_ZOOM_PLAYING=1: with music playing (the pill folds on
            // the home page and comes back on the others).
            if ProcessInfo.processInfo.environment["OMNIHUB_ZOOM_PLAYING"] == "1" {
                var song = MediaObserver.NowPlaying()
                song.title = "Zoom Song"; song.artist = "Tester"; song.isPlaying = true
                MediaObserver.shared.debugInject(song)
                runs.append(("close", .home, .home))
            }
            for (kind, from, to) in runs {
                FloatingDockPanel.debugZoom(kind: kind, from: from, to: to, x: 0.5, y: 0, into: directory).forEach { print($0) }
            }
            exit(0)
        }

        // `--remote-selftest <dir>`: drive the terminal's remote features
        // against a test server described by OMNIHUB_TEST_* (see test-remote.sh).
        if args.contains("--update-selftest") {
            UpdateSelfTest.run()
            return
        }
        if let index = args.firstIndex(of: "--remote-selftest"), index + 1 < args.count {
            RemoteSelfTest.run(into: URL(fileURLWithPath: args[index + 1], isDirectory: true))
            return
        }

        setupMainMenu()
        setupStatusItem()
        registerHotKeys()
        installEscapeMonitor()
        NSAppleEventManager.shared().setEventHandler(self,
                                                     andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))

        ClipboardStore.shared.start()
        MediaObserver.shared.start()
        StatusIcon.shared.start()
        if !isToolRun {
            applyDockTile()
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(applyDockTile), name: .settingsChanged, object: nil)
            center.addObserver(self, selector: #selector(refreshDockTile), name: .statusIconChanged, object: nil)
            center.addObserver(self, selector: #selector(applyActivationPolicy), name: .mainWindowChanged, object: nil)
            ShelfStore.shared.startPurging()
            UpdateChecker.shared.start()
        }

        if !ScreenCapture.isTrusted(), !isToolRun {
            ScreenCapture.requestAccess()
        }

        // The floating dock is part of the product, so it comes up on launch
        // (unless it was hidden with its hotkey last time).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if isToolRun { FloatingDockPanel.show() } else { FloatingDockPanel.showAtLaunch() }
        }
        if !isToolRun {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { BootAnimation.playIfEnabled() }
        }

        wireDiagnostics()

        if args.contains("--snip") || args.contains("--demo") {
            let demo = args.contains("--demo")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.startSnip(autoScroll: false)
                if demo {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        self?.controller?.runDemo()
                    }
                }
            }
        }
    }

    // MARK: Dock tile

    private var dockTileView: NSImageView?

    /// Settings › Appearance › Show in the Dock: the status icon as a live
    /// Dock tile. OmniHub is a menu-bar app otherwise, with no Dock icon.
    @objc private func applyDockTile() {
        let wanted = StatusIcon.inDock
        guard wanted != (dockTileView != nil) else { return }
        if wanted {
            applyActivationPolicy()
            let view = NSImageView(frame: NSRect(origin: .zero, size: NSApp.dockTile.size))
            view.imageScaling = .scaleProportionallyUpOrDown
            NSApp.dockTile.contentView = view
            dockTileView = view
            refreshDockTile()
        } else {
            NSApp.dockTile.contentView = nil
            dockTileView = nil
            applyActivationPolicy()
        }
    }

    /// A Dock icon while the main window is open or the status icon is
    /// wanted there; a menu-bar app otherwise.
    @objc private func applyActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = StatusIcon.inDock || MainWindow.isOpen ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    @objc private func refreshDockTile() {
        guard let view = dockTileView else { return }
        view.image = StatusIcon.shared.image(size: 256, foreground: .white, plate: .square)
        NSApp.dockTile.display()
    }

    /// A click on the Dock icon opens the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !MainWindow.isOpen || !(NSApp.keyWindow is MainWindow) { MainWindow.toggle() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MediaObserver.shared.stop()
        FloatingDockPanel.terminateShells()
    }

    /// The app used to be called SnaCut (com.local.snacut): carry the
    /// settings over the first time the renamed app starts.
    private func migrateLegacyPreferences() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromSnaCut") else { return }
        defaults.set(true, forKey: "migratedFromSnaCut")
        guard let legacy = defaults.persistentDomain(forName: "com.local.snacut") else { return }
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    // MARK: Headless rendering

    private func runRender(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        CalendarSource.allowPrompt = false
        FloatingDockPanel.headless = true
        // Rendering must not touch the user's real settings.
        let keys = ["dock.posX", "dock.posY", "dock.mediaStyle", "dock.pillWidth", "dock.hidden"]
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        var report: [String] = []
        func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
        func finish() -> Never {
            for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) }
            try? report.joined(separator: "\n").write(to: file("report.txt"), atomically: true, encoding: .utf8)
            print(report.joined(separator: "\n"))
            FloatingDockPanel.terminateShells()
            exit(0)
        }
        func after(_ seconds: Double, _ block: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: block)
        }
        func write(_ image: NSImage, _ name: String) {
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: file(name))
            }
        }

        var fake = MediaObserver.NowPlaying()
        fake.title = "回到最爱的那天"
        fake.artist = "洪卓立"
        fake.appName = "网易云音乐"
        fake.isPlaying = true
        fake.duration = 259
        fake.elapsed = 42
        fake.artwork = Artwork.avatar

        write(StatusRunner.contactSheet(), "status-runner-frames.png")
        report.append("holiday  \(Holidays.countdownText())")

        // A few samples so the charts have something to draw.
        var samples = 0
        func sampleStats(_ done: @escaping () -> Void) {
            SystemStats.shared.loadOnce {
                samples += 1
                if samples < 6 { after(0.25) { sampleStats(done) } } else { done() }
            }
        }
        sampleStats {
            let stats = SystemStats.shared.snapshot
            report.append("stats cpu=\(stats.cpu.map { String(format: "%.1f%%", $0 * 100) } ?? "-") "
                + "gpu=\(stats.gpu.map { String(format: "%.1f%%", $0 * 100) } ?? "-") "
                + "mem=\(SystemStats.bytes(Int64(stats.memoryUsed)))/\(SystemStats.bytes(Int64(stats.memoryTotal))) "
                + "disk=\(SystemStats.bytes(stats.diskUsed))/\(SystemStats.bytes(stats.diskTotal)) "
                + "io=\(SystemStats.rate(stats.diskRead))/\(SystemStats.rate(stats.diskWrite)) "
                + "ips=\(stats.localIPs.map { "\($0.name)=\($0.address)" })")

            func dock(_ name: String, _ x: Double, _ y: Double, _ expanded: Bool, _ page: String) {
                report.append("\(name): " + FloatingDockPanel.debugRender(to: file("dock-\(name).png"), x: x, y: y,
                                                                         expanded: expanded, page: page))
            }
            dock("idle", 1, 0.5, false, "home")
            MediaObserver.shared.debugInject(fake)
            Prefs.set("dock.mediaStyle", 0)
            Prefs.set("dock.pillWidth", 300)
            dock("pill-300", 0.5, 1, false, "home")
            Prefs.set("dock.pillWidth", 84)
            dock("pill-84", 0.5, 1, false, "home")
            Prefs.set("dock.pillWidth", 300)
            // The card opens on the side of the ball facing the screen.
            dock("top-home", 0.5, 1, true, "home")
            dock("bottom-home", 0.5, 0, true, "home")
            dock("left-home", 0, 0.5, true, "home")
            dock("right-home", 1, 0.5, true, "home")
            dock("top-activity", 0.5, 1, true, "activity")
            dock("left-activity", 0, 0.5, true, "activity")
            dock("top-clipboard", 0.5, 1, true, "clipboard")
            dock("top-tasks", 0.5, 1, true, "tasks")
            report.append("activity \(FloatingDockPanel.debugActivity)")
            report.append("agenda   \(FloatingDockPanel.agenda.debugState)")
            for tab in [0, 1, 3, 5, 7] {
                FloatingDockPanel.open(.settings, toggle: false, settingsTab: tab)
                report.append("settings-\(tab): " + FloatingDockPanel.debugRender(to: file("dock-settings-\(tab).png"),
                                                                              x: 0.5, y: 1, expanded: true, page: "settings"))
            }
            dock("right-settings", 1, 0.5, true, "settings")

            // Terminal: two tabs, a command in each; then the overlays.
            dock("top-terminal", 0.5, 1, true, "terminal")
            let terminal = FloatingDockPanel.terminal
            terminal.debugWrite("echo first-tab-ok\n")
            after(1.5) {
                let first = terminal.debugText
                terminal.debugPerform(.newTab)
                after(1.5) {
                    terminal.debugWrite("echo second-tab-ok\n")
                    after(1.2) {
                        report.append("terminal \(terminal.debugTabs)")
                        report.append("tab1 has output: \(first.contains("first-tab-ok"))")
                        report.append("tab2 has output: \(terminal.debugText.contains("second-tab-ok")) "
                            + "and not tab1 text: \(!terminal.debugText.contains("first-tab-ok"))")
                        FloatingDockPanel.snapshot(to: file("terminal-2tabs.png"))
                        terminal.debugPerform(.nextTab)
                        report.append("after next: \(terminal.debugTabs)")
                        terminal.debugPerform(.tab2)
                        report.append("after ⌘2: \(terminal.debugTabs)")
                        terminal.debugPerform(.biggerText)
                        report.append("font after ⌘+: \(TerminalSession.fontSize)")
                        terminal.debugPerform(.defaultText)
                        terminal.debugToggle("connections")
                        FloatingDockPanel.snapshot(to: file("terminal-connections.png"))
                        terminal.debugToggle("transfers")
                        FloatingDockPanel.snapshot(to: file("terminal-transfers.png"))
                        terminal.debugToggle("transfers")
                        for tab in 0..<3 {
                            terminal.openSettings(tab: tab)
                            FloatingDockPanel.snapshot(to: file("terminal-settings-\(tab).png"))
                        }
                        terminal.debugToggle("settings")
                        terminal.debugPerform(.closeTab)
                        report.append("after close: \(terminal.debugTabs)")
                        report.append("keymap file: \(TerminalKeymap.fileURL.path) newTab=\(TerminalKeymap.shared.combos(for: .newTab).map(\.text))")
                        finish()
                    }
                }
            }
        }
    }

    // MARK: Esc closes every summoned panel

    private func installEscapeMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53,
                  let panel = event.window as? EscDismissable else { return event }
            // Typing in a shell: Esc belongs to the program running there.
            if event.window?.firstResponder is TerminalTextView { return event }
            // A shortcut being recorded takes Esc as "cancel recording".
            if let recorder = event.window?.firstResponder as? ShortcutRecorder, recorder.isRecording {
                return event
            }
            if let recorder = event.window?.firstResponder as? LocalKeyRecorder, recorder.isRecording {
                return event
            }
            // Esc during IME composition cancels the composition, not the panel.
            if let textView = event.window?.firstResponder as? NSTextView, textView.hasMarkedText() {
                return event
            }
            panel.dismissByEscape()
            return nil
        }
    }

    // MARK: Remote control (omnihub://…)

    /// `open omnihub://open/tasks`, `omnihub://diagnose`, … Lets scripts (and
    /// the verification runs) drive the already running instance.
    static func isDebugRoute(_ command: String) -> Bool {
        command.hasPrefix("debug/")
            || ["terminal-demo", "expand-dock", "collapse-dock", "escape", "snapshot"].contains(command)
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string), url.scheme == "omnihub" else { return }
        let command = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).joined(separator: "/")
        // Any web page or app can open an omnihub:// link. Test and
        // automation routes (typing into a shell, dumping the clipboard,
        // skipping permission checks…) only work after
        // `defaults write com.local.omnihub debug.urls -bool true`.
        guard !Self.isDebugRoute(command) || Prefs.bool("debug.urls") else { return }
        switch command {
        case "snip": startSnip(autoScroll: false)
        case "longsnip": startSnip(autoScroll: true)
        case "open/clipboard": FloatingDockPanel.open(.clipboard)
        case "open/tasks": FloatingDockPanel.open(.tasks)
        case "open/activity": FloatingDockPanel.open(.activity)
        case "open/shelf": FloatingDockPanel.open(.shelf)
        case "boot": BootAnimation.playIfEnabled(force: true)
        case "debug/page/home": FloatingDockPanel.open(.home, toggle: false)
        case "debug/terminal/new": FloatingDockPanel.terminal.addTab()
        case "debug/terminal/close": FloatingDockPanel.terminal.closeActiveTab()
        case "debug/terminal/next": FloatingDockPanel.terminal.cycle(by: 1)
        case "debug/pill/84", "debug/pill/300", "debug/pill/200", "debug/pill/560":
            Prefs.set("dock.pillWidth", Int(command.split(separator: "/").last ?? "300") ?? 300)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        case "open/terminal": FloatingDockPanel.open(.terminal)
        case "open/settings": FloatingDockPanel.open(.settings)
        case "open/settings/0", "open/settings/1", "open/settings/2", "open/settings/3",
             "open/settings/4", "open/settings/5", "open/settings/6", "open/settings/7", "open/settings/8":
            FloatingDockPanel.open(.settings, toggle: false, settingsTab: Int(command.suffix(1)))
        case "debug/terminal/connections", "debug/terminal/transfers", "debug/terminal/forwards",
             "debug/terminal/sftp", "debug/terminal/settings":
            FloatingDockPanel.terminal.debugToggle(String(command.split(separator: "/").last ?? ""))
        case "debug/hotkey-record":
            // Records ⌃⌥D for "show / hide dock" through the real event path.
            FloatingDockPanel.open(.settings, toggle: false, settingsTab: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.lastDebug = "recorder clicked=\(FloatingDockPanel.settings.debugRecord(.dock))"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard let window = NSApp.keyWindow,
                          let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option],
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil,
                                                     characters: "d", charactersIgnoringModifiers: "d",
                                                     isARepeat: false, keyCode: 2) else {
                        self?.lastDebug += " no key window"
                        return
                    }
                    self?.lastDebug += " keyWindow=\(type(of: window)) responder=\(type(of: window.firstResponder as Any))"
                    NSApp.postEvent(key, atStart: false)
                }
            }
        case "debug/clip-activate": FloatingDockPanel.clipboard.debugActivate(row: 0)
        case "debug/pin-zoom/in": lastDebug = PinnedImageWindow.debugZoomFirst(1)
        case "debug/pin-zoom/out": lastDebug = PinnedImageWindow.debugZoomFirst(-1)
        case "debug/pin-zoom/noop": _ = PinnedImageWindow.debugZoomFirst(1)
        case "open/clipfav": FloatingDockPanel.open(.clipboard, toggle: false); FloatingDockPanel.clipboard.showFavourites()
        case "open/dock": FloatingDockPanel.show()
        case "open/main": MainWindow.toggle()
        case "toggle/dock": FloatingDockPanel.toggle()
        case "expand-dock": FloatingDockPanel.show(); FloatingDockPanel.expandForDemo()
        case "collapse-dock": FloatingDockPanel.closeCard()
        case "terminal-demo": FloatingDockPanel.terminal.debugWrite("printf 'OmniHub terminal ok\\n'; pwd\n")
        case "playpause": MediaObserver.shared.togglePlayPause()
        case "debug/media/mode": MediaObserver.shared.cyclePlayMode()
        case "debug/media/like": MediaObserver.shared.toggleLike()
        case "escape":
            // Queues a genuine Esc key-down for the key window, so it runs
            // through the same event monitor as a physical key press.
            if let window = NSApp.keyWindow,
               let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                                          isARepeat: false, keyCode: 53) {
                NSApp.postEvent(key, atStart: false)
            }
        case "check-updates":
            DispatchQueue.main.async { UpdateChecker.shared.updateNow() }
        case "diagnose":
            try? diagnosticsText().write(to: Store.url("diagnostics.txt"), atomically: true, encoding: .utf8)
        case "snapshot":
            snapshotWindows()
        case "debug/status-icon":
            // What the menu bar icon is drawn from, and the icon at 10×.
            let icon = StatusIcon.shared
            try? "\(icon.readings)\n\(StatusIcon.Config.current)\n".write(to: Store.url("status-icon.txt"), atomically: true, encoding: .utf8)
            let image = icon.image(size: 200, foreground: .white)
            if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: Store.url("status-icon.png"))
            }
        case "debug/screen":
            // The whole screen as OmniHub sees it (menu bar icon, ball and
            // all), for checks run where screencapture lacks the permission.
            ScreenCapture.captureAllDisplays { captures in
                for (index, capture) in captures.enumerated() {
                    let rep = NSBitmapImageRep(cgImage: capture.image)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: Store.url("screen-\(index).png"))
                }
            }
        // debug/…: exercise the capture flows without a human at the mouse.
        // `force` skips the permission gate (frames then show only the
        // wallpaper), which is enough to prove the plumbing.
        case "debug/snip-demo", "debug/longsnip-demo":
            startSnip(autoScroll: command == "debug/longsnip-demo", force: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.controller?.runDemo()
            }
        case "debug/scroll-selftest/slow": ScrollSelfTest.run(mode: "slow")
        case "debug/scroll-selftest/flick": ScrollSelfTest.run(mode: "flick")
        case "debug/scroll-selftest/jump": ScrollSelfTest.run(mode: "jump")
        case "debug/scroll-selftest/sticky": ScrollSelfTest.run(mode: "sticky")
        case "debug/scroll-selftest/keys": ScrollSelfTest.run(mode: "keys")
        case "debug/scroll-keys-region":
            let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems ?? []).map { ($0.name, Double($0.value ?? "") ?? 0) })
            ScrollSelfTest.runKeys(region: CGRect(x: query["x"] ?? 0, y: query["y"] ?? 0,
                                                  width: query["w"] ?? 0, height: query["h"] ?? 0))
        case "debug/dock/top": FloatingDockPanel.debugMove(x: 0.5, y: 1)
        case "debug/dock/bottom": FloatingDockPanel.debugMove(x: 0.3, y: 0)
        case "debug/dock/left": FloatingDockPanel.debugMove(x: 0, y: 0.5)
        case "debug/dock/right": FloatingDockPanel.debugMove(x: 1, y: 0.6)
        case "debug/dock/middle": FloatingDockPanel.debugMove(x: 0.6, y: 0.45)
        case "debug/media-style/0", "debug/media-style/1", "debug/media-style/2":
            Prefs.set("dock.mediaStyle", Int(command.suffix(1)) ?? 0)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        case "debug/force-live/1", "debug/force-live/0":
            FloatingDockPanel.debugForceLive = command.hasSuffix("1")
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        case "debug/dump-clipboard":
            let dir = Store.directory.appendingPathComponent("snapshots", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let png = NSPasteboard.general.data(forType: .png) {
                try? png.write(to: dir.appendingPathComponent("clipboard.png"))
            }
        case "debug/snip-finish": controller?.finish()
        case "debug/snip-pin": controller?.pin()
        case "pin": PinnedImageWindow.pinClipboard()
        case "unpin": PinnedImageWindow.closeAll()
        case "debug/snip-escape": controller?.handleEscape()
        case "debug/longsnip-finish": controller?.finishScrollCapture()
        default: break
        }
    }

    /// Renders each of our visible windows into a PNG under
    /// Application Support/OmniHub/snapshots. The views draw themselves, so
    /// this needs no screen-recording permission.
    private func snapshotWindows() {
        let dir = Store.directory.appendingPathComponent("snapshots", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for window in NSApp.windows where window.isVisible {
            let name = String(describing: type(of: window))
            guard !name.hasPrefix("NSStatusBar"), let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            if window is FloatingDockPanel, let icon = statusItem.button?.image,
               let tiff = icon.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("StatusIcon.png"))
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("\(name).png"))
            }
        }
    }

    // MARK: Diagnostics

    /// `--diagnose` prints module state and exits; `--open <module>` opens one
    /// panel for headless verification.
    private func wireDiagnostics() {
        let args = CommandLine.arguments
        if args.contains("--seed") {
            if TaskStore.shared.active.isEmpty {
                TaskStore.shared.add(title: "审查 OmniHub 截图管线", note: "多显示器、缩放比例各试一遍", due: nil)
                TaskStore.shared.add(title: "补齐长截图异常处理",
                                     note: "滚动到底部自动结束",
                                     due: Date().addingTimeInterval(3600))
            }
        }
        if let index = args.firstIndex(of: "--open"), index + 1 < args.count {
            let module = args[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                switch module {
                case "clipboard": FloatingDockPanel.open(.clipboard)
                case "clipfav":
                    FloatingDockPanel.open(.clipboard, toggle: false)
                    FloatingDockPanel.clipboard.showFavourites()
                case "tasks":     FloatingDockPanel.open(.tasks)
                case "terminal":  FloatingDockPanel.open(.terminal)
                case "dock":      FloatingDockPanel.show()
                default: break
                }
            }
        }
        if args.contains("--expand-dock") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                FloatingDockPanel.expandForDemo()
            }
        }
        if args.contains("--demo-data") {
            seedDemoData()
        }
        if args.contains("--ocr-selftest") {
            // Draws a line of text into an image and reads it back.
            let image = NSImage(size: NSSize(width: 520, height: 120), flipped: false) { rect in
                NSColor.white.setFill()
                rect.fill()
                ("OmniHub OCR 20261113 文字识别" as NSString).draw(at: NSPoint(x: 20, y: 40), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black])
                return true
            }
            OCR.recognize(image) { text in
                let ok = (text ?? "").contains("20261113") && (text ?? "").contains("文字识别")
                print("\(ok ? "PASS" : "FAIL")  ocr read: \(text ?? "(nothing)")")
                exit(ok ? 0 : 1)
            }
            return
        }
        if args.contains("--clip-selftest") {
            runClipboardSelfTest()
            return
        }
        if args.contains("--terminal-selftest") {
            runTerminalSelfTest()
            return
        }
        // Scheduled last so the --open / --expand-dock blocks above still run.
        if args.contains("--diagnose") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                print(self?.diagnosticsText() ?? "")
                exit(0)
            }
        }
    }

    private func seedDemoData() {
        let store = ClipboardStore.shared
        store.debugClearPins()
        store.clearRecent()
        for text in [
            "https://developer.apple.com/documentation/screencapturekit",
            "SCScreenshotManager.captureImage(contentFilter:configuration:)",
            "func renderFinalImage() -> NSImage?",
            "npm run build:web && pnpm -r test",
            "截图前先确认色彩空间与缩放比例"
        ] { store.debugInsert(text: text) }
        let pins = ["周报：周五 18:00 前提交",
                    "发布前检查：codesign --verify --deep"]
        for text in pins {
            store.debugInsert(text: text)
            if let item = store.recentItems.first(where: { $0.text == text }) {
                store.togglePin(item.id)
            }
        }
    }

    /// Verifies favourites: pin, ordering, move, de-duplication and
    /// persistence round-trip. Runs on a throwaway copy of the user's data.
    private func runClipboardSelfTest() {
        let store = ClipboardStore.shared
        let backups = ["clips.json", "pins.json"].map { ($0, try? Data(contentsOf: Store.url($0))) }
        func restoreAndExit(_ code: Int32) -> Never {
            for (name, data) in backups {
                if let data { try? data.write(to: Store.url(name)) }
                else { try? FileManager.default.removeItem(at: Store.url(name)) }
            }
            exit(code)
        }

        store.debugClearPins()
        store.clearRecent()
        for text in ["alpha", "beta", "gamma", "beta"] { store.debugInsert(text: text) }
        var failures: [String] = []
        let afterInsert = store.recentItems.compactMap { $0.text }
        if afterInsert != ["beta", "gamma", "alpha"] { failures.append("dedupe = \(afterInsert)") }

        guard let alpha = store.recentItems.first(where: { $0.text == "alpha" }),
              let gamma = store.recentItems.first(where: { $0.text == "gamma" }) else {
            print("FAIL: could not record items"); restoreAndExit(1)
        }

        store.togglePin(alpha.id)
        store.togglePin(gamma.id)
        let afterPin = store.pinnedItems.compactMap { $0.text }
        if afterPin != ["gamma", "alpha"] { failures.append("pin order = \(afterPin)") }

        store.movePinned(from: 0, to: 2)          // move gamma to the end
        let afterMove = store.pinnedItems.compactMap { $0.text }
        if afterMove != ["alpha", "gamma"] { failures.append("after move = \(afterMove)") }

        store.shiftPinned(alpha.id, by: 1)        // keyboard reorder
        let afterShift = store.pinnedItems.compactMap { $0.text }
        if afterShift != ["gamma", "alpha"] { failures.append("after shift = \(afterShift)") }

        // Persistence round-trip through a fresh decode of pins.json.
        let saved = Store.load([PinDTOProbe].self, from: "pins.json")?.compactMap { $0.text }
        if saved != afterShift { failures.append("persisted = \(String(describing: saved))") }

        print("-- clipboard self-test --")
        print("recent = \(store.recentItems.compactMap { $0.text })")
        print("pinned = \(store.pinnedItems.compactMap { $0.text })")
        if failures.isEmpty {
            print("PASS: dedupe / pin / reorder / persist all correct")
            restoreAndExit(0)
        }
        print("FAIL: " + failures.joined(separator: " | "))
        restoreAndExit(1)
    }

    /// Feeds recorded shell byte sequences through the terminal model and
    /// checks the resulting screen text.
    private func runTerminalSelfTest() {
        func screen(_ input: String, columns: Int = 40) -> [String] {
            let buffer = TerminalBuffer()
            buffer.columns = columns
            buffer.visibleRows = 10
            buffer.feed(Array(input.utf8))
            return (0..<buffer.lines.count).map { buffer.text(ofLine: $0) }
        }
        let e = "\u{1B}"
        let cases: [(String, String, [String])] = [
            ("crlf", "one\r\ntwo\r\n", ["one", "two", ""]),
            ("backspace erase", "% lsx\u{08} \u{08}\r\n", ["% ls", ""]),
            ("erase line (CSI K)", "abcdef\r\(e)[Kxy", ["xy"]),
            ("zsh prompt marker", "%" + String(repeating: " ", count: 39) + "\r \r\(e)[0m\(e)[Kuser@mac ~ % ", ["user@mac ~ %"]),
            ("colours stripped", "\(e)[1;32mgreen\(e)[0m plain", ["green plain"]),
            ("title sequence", "\(e)]0;window title\u{07}ok", ["ok"]),
            ("cursor left + insert", "helo\(e)[D\(e)[@l", ["hello"]),
            ("delete chars (CSI P)", "abcXXdef\r\(e)[3C\(e)[2P", ["abcdef"]),
            ("cursor up rewrite", "progress 10%\r\nline2\(e)[A\rprogress 99%", ["progress 99%", "line2"]),
            ("wide glyphs", "中文ab\u{08}\u{08}\u{08}\u{08}国", ["中国ab"]),
            ("clear screen", "junk\r\nmore\(e)[H\(e)[2Jfresh", ["fresh"]),
            ("auto wrap", String(repeating: "x", count: 45), [String(repeating: "x", count: 40), "xxxxx"])
        ]
        var failed = 0
        print("-- terminal self-test --")
        for (name, input, expected) in cases {
            let want = expected
            let got = screen(input)
            if got == want {
                print("PASS  \(name)")
            } else {
                failed += 1
                print("FAIL  \(name): got \(got) want \(want)")
            }
        }
        // UTF-8 split across two reads must not produce replacement characters.
        let buffer = TerminalBuffer()
        let bytes = Array("你好".utf8)
        buffer.feed(Array(bytes[0..<2]))
        buffer.feed(Array(bytes[2...]))
        if buffer.text(ofLine: 0) == "你好" { print("PASS  split utf-8") }
        else { failed += 1; print("FAIL  split utf-8: \(buffer.text(ofLine: 0))") }

        func expect(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failed += 1 }
            print("\(ok ? "PASS" : "FAIL")  \(name)\(ok || detail.isEmpty ? "" : ": \(detail)")")
        }

        // Global shortcuts step aside while a shell has the keyboard.
        let hotkeys = HotKeyCenter.shared
        let combo = { (action: HotKeyAction) in hotkeys.combo(for: action) }
        hotkeys.setTerminalTyping(true)
        let typingState = HotKeyAction.allCases.map { "\($0.rawValue)=\(hotkeys.isActive($0))" }.joined(separator: " ")
        let ctrlOnlyOff = HotKeyAction.allCases.allSatisfy { action in
            guard let c = combo(action), ![.terminal, .snip, .longSnip].contains(action),
                  c.modifiers & UInt32(cmdKey) == 0 else { return true }
            return !hotkeys.isActive(action)
        }
        expect("typing in a shell: control-key shortcuts are let through", ctrlOnlyOff, typingState)
        expect("typing in a shell: the terminal toggle still works",
               combo(.terminal) == nil || hotkeys.isActive(.terminal), typingState)
        expect("typing in a shell: the screenshot shortcut always stays (highest priority)",
               combo(.snip) == nil || hotkeys.isActive(.snip), typingState)
        expect("typing in a shell: other ⌘ shortcuts the terminal does not use stay, its own ones yield",
               HotKeyAction.allCases.allSatisfy { action in
                   guard ![.snip, .longSnip].contains(action),
                         let c = combo(action), c.modifiers & UInt32(cmdKey) != 0 else { return true }
                   let terminalKey = TerminalKeymap.shared.isBound(keyCode: c.keyCode, carbonModifiers: c.modifiers)
                   return hotkeys.isActive(action) != terminalKey || action == .terminal
               }, typingState)
        hotkeys.setTerminalTyping(false)
        expect("leaving the shell restores every shortcut",
               HotKeyAction.allCases.allSatisfy { combo($0) == nil || hotkeys.isActive($0) },
               HotKeyAction.allCases.map { "\($0.rawValue)=\(hotkeys.isActive($0))" }.joined(separator: " "))

        // Forwards that already exist on a server.
        let probe = """
        @@PS
          812 dillon   /usr/bin/ssh -fN -L 8080:10.0.0.5:80 -R0.0.0.0:2222:localhost:22 -o ServerAliveInterval=30 jump@bastion
          813 root     autossh -M 0 -D 1080 -i /root/.ssh/id proxy@vps
          900 dillon   ssh dillon@other-host
          901 root     /usr/sbin/sshd -D
          902 dillon   ssh -o LocalForward=9000 db:5432 relay
        @@LISTEN
        LISTEN 0 128 127.0.0.1:18080 0.0.0.0:* users:(("sshd",pid=4410,fd=9))
        LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))
        LISTEN 0 128 0.0.0.0:3306 0.0.0.0:* users:(("mysqld",pid=77,fd=3))
        sshd    4411 dillon    9u  IPv4 0x1      0t0  TCP 127.0.0.1:18081 (LISTEN)
        @@CONFIG
        Host web
          LocalForward 8443 127.0.0.1:443
        Host *
          DynamicForward=1081
        @@END
        """
        let tunnels = ServerTunnels.parse(probe, sshPort: 22)
        let lines = tunnels.map { "\($0.summary) | \($0.state)" }
        expect("server tunnels: ssh -L / bundled -R / autossh -D / -o LocalForward are found",
               lines.contains("ssh -L 8080:10.0.0.5:80 | Running · pid 812, dillon → jump@bastion")
               && lines.contains("ssh -R 0.0.0.0:2222:localhost:22 | Running · pid 812, dillon → jump@bastion")
               && lines.contains("ssh -D 1080 | Running · pid 813, root → proxy@vps")
               && lines.contains("ssh -L 9000 db:5432 | Running · pid 902, dillon → relay"), "\(lines)")
        expect("server tunnels: plain logins and sshd itself are not tunnels",
               !lines.contains { $0.contains("other-host") || $0.contains("pid 901") }, "\(lines)")
        expect("server tunnels: sshd listeners (ss and lsof), not the ssh port, not other daemons",
               lines.contains("sshd listening 127.0.0.1:18080 | Remote forward · sshd pid 4410")
               && lines.contains("sshd listening 127.0.0.1:18081 | Remote forward · sshd pid 4411")
               && !lines.contains { $0.hasPrefix("sshd listening 0.0.0.0:22 ") || $0.contains("3306") }, "\(lines)")
        expect("server tunnels: forwards written in ~/.ssh/config",
               lines.contains("LocalForward 8443 127.0.0.1:443 | Configured · Host web")
               && lines.contains("DynamicForward 1081 | Configured · Host *"), "\(lines)")
        expect("server tunnels: listening ports are read from specs",
               tunnels.first { $0.spec == "8080:10.0.0.5:80" }?.listenPort == 8080
               && tunnels.first { $0.spec == "0.0.0.0:2222:localhost:22" }?.listenPort == 2222
               && tunnels.first { $0.spec == "127.0.0.1:18080" }?.listenPort == 18080)
        exit(failed == 0 ? 0 : 1)
    }

    private func diagnosticsText() -> String {
        var out: [String] = []
        out.append("== OmniHub diagnostics ==")
        out.append("version = \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") pid = \(ProcessInfo.processInfo.processIdentifier)")
        out.append("screenRecordingTrusted = \(ScreenCapture.isTrusted())")
        out.append("displays = \(ScreenCapture.activeDisplayIDs())")
        out.append("accessibilityTrusted = \(AXIsProcessTrusted())")
        out.append("-- clipboard --")
        out.append("items = \(ClipboardStore.shared.items.count) (pinned \(ClipboardStore.shared.pinnedItems.count))")
        // Contents only in debug mode: the file sits in a known place.
        if Prefs.bool("debug.urls") {
            for item in ClipboardStore.shared.items.prefix(3) {
                out.append("  - \(item.preview.prefix(60).replacingOccurrences(of: "\n", with: " "))")
            }
        }
        out.append("-- tasks --")
        out.append("active = \(TaskStore.shared.active.count), completed = \(TaskStore.shared.completedCount)")
        if Prefs.bool("debug.urls") {
            for task in TaskStore.shared.active.prefix(3) {
                out.append("  - \(task.title) | \(task.note) | \(task.due.map { "\($0)" } ?? "-")")
            }
        }
        out.append("-- media --")
        out.append("source = \(MediaObserver.shared.source)")
        if let playing = MediaObserver.shared.current {
            out.append("nowPlaying = \(playing.title) / \(playing.artist) / app=\(playing.appName) (\(playing.bundleID ?? "-")) / playing=\(playing.isPlaying) / artwork=\(playing.artwork != nil)")
            out.append(contentsOf: MediaObserver.shared.controlReport)
        } else {
            out.append("nowPlaying = (none)")
        }
        out.append("-- dock --")
        out.append(FloatingDockPanel.debugState)
        out.append(Vault.debugSummary)
        if let session = FloatingDockPanel.terminalIfCreated?.activeSession {
            out.append("terminal \(session.debugCursorState)")
        }
        for screen in NSScreen.screens {
            out.append("screen frame=\(screen.frame) visible=\(screen.visibleFrame) main=\(screen == NSScreen.main)")
        }
        out.append("-- windows --")
        for window in NSApp.windows where window.isVisible {
            out.append("  \(type(of: window)) frame=\(window.frame) key=\(window.isKeyWindow)")
        }
        out.append("-- boot --")
        out.append("bootAnimation = \(BootAnimation.lastOutcome) video=\(Artwork.bootVideo != nil) avatar=\(Artwork.avatar != nil) background=\(Artwork.background != nil)")
        out.append("-- activity --")
        let stats = SystemStats.shared.snapshot
        out.append("cpu=\(stats.cpu.map { String(format: "%.1f%%", $0 * 100) } ?? "-") gpu=\(stats.gpu.map { String(format: "%.1f%%", $0 * 100) } ?? "-") "
            + "mem=\(SystemStats.bytes(Int64(stats.memoryUsed)))/\(SystemStats.bytes(Int64(stats.memoryTotal))) "
            + "disk=\(SystemStats.bytes(stats.diskUsed))/\(SystemStats.bytes(stats.diskTotal)) "
            + "ips=\(stats.localIPs.map { "\($0.name)=\($0.address)" })")
        out.append(MainWindow.debugState)
        out.append("-- pages --")
        out.append(FloatingDockPanel.clipboard.debugState)
        out.append("pins = \(PinnedImageWindow.count) lastDebug = \(lastDebug)")
        out.append("appActive = \(NSApp.isActive) keyWindow = \(NSApp.keyWindow.map { "\(type(of: $0))" } ?? "nil")")
        out.append("-- status icon --")
        out.append(statusRunner?.debugState ?? "(no status item)")
        out.append("statusIcon menuBar=\(StatusIcon.inMenuBar) ball=\(StatusIcon.onBall) dock=\(StatusIcon.inDock) \(StatusIcon.shared.summary)")
        out.append("keepAwake = \(KeepAwake.shared.statusText)")
        out.append("-- holiday --")
        out.append(Holidays.countdownText())
        out.append("-- terminal --")
        out.append(FloatingDockPanel.terminalIfCreated?.debugTabs ?? "tabs = 0")
        out.append((FloatingDockPanel.terminalIfCreated?.debugText ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(12).joined(separator: "\n"))
        out.append("-- snip --")
        out.append("snipActive = \(isSnipActive)")
        let pasteboard = NSPasteboard.general
        var summary = "pasteboard = " + (pasteboard.types?.prefix(4).map(\.rawValue).joined(separator: ", ") ?? "-")
        if let data = pasteboard.data(forType: .png), let rep = NSBitmapImageRep(data: data) {
            summary += " | png \(rep.pixelsWide)x\(rep.pixelsHigh) px"
        }
        out.append(summary)
        out.append("-- update --")
        out.append("update = \(UpdateChecker.shared.statusText)")
        out.append("-- hotkeys --")
        for (name, state) in HotKeyCenter.shared.report {
            out.append("  \(name): \(state)")
        }
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: Menus

    /// The menu bar shows while the main window is in front; text fields
    /// rely on the Edit menu's key equivalents for ⌘X / ⌘C / ⌘V / ⌘A / ⌘Z
    /// even when it does not.
    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu(title: "OmniHub")
        app.addItem(withTitle: L("Settings…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: L("Hide OmniHub"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: L("Quit OmniHub"), action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = app
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        let windowItem = NSMenuItem()
        let windows = NSMenu(title: L("Window"))
        windows.addItem(withTitle: L("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windows.addItem(withTitle: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windows
        main.addItem(windowItem)
        NSApp.windowsMenu = windows
        NSApp.mainMenu = main
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // The little runner; it flaps faster as memory / CPU fills up.
            statusRunner = StatusRunner(button: button)
        }
        let menu = NSMenu()
        menu.delegate = self
        populate(menu)
        statusMenu = menu
        // A left click opens the main window; a right click shows the menu.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        guard wantsMenu else {
            MainWindow.toggle()
            return
        }
        // Attached only for this click, so the next left click is ours again.
        statusItem.menu = statusMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Rebuilt every time the menu opens so the shortcut labels follow the
    /// current settings.
    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        func key(_ action: HotKeyAction) -> String { HotKeyCenter.shared.display(for: action) }

        addItem(menu, "Screenshot", key(.snip), #selector(snipNormal))
        addItem(menu, "Scrolling Screenshot", key(.longSnip), #selector(snipLong))
        addItem(menu, "Pin Clipboard Image", key(.pinClipboard), #selector(pinClipboard))
        addItem(menu, "Close All Pins", "", #selector(closePins))
        menu.addItem(.separator())
        addItem(menu, "Clipboard", key(.clipboard), #selector(showClipboard))
        addItem(menu, "Terminal", key(.terminal), #selector(showTerminal))
        addItem(menu, "Agenda", key(.tasks), #selector(showTasks))
        addItem(menu, "Activity", key(.activity), #selector(showActivity))
        menu.addItem(.separator())
        addItem(menu, "Show / Hide Dock", key(.dock), #selector(toggleDock))
        let awake = addItem(menu, "Keep Awake", "", #selector(noop))
        awake.submenu = KeepAwake.shared.menu(target: self, action: #selector(keepAwakePicked(_:)))
        awake.state = KeepAwake.shared.isOn ? .on : .off
        addItem(menu, "Play / Pause", key(.playPause), #selector(togglePlayback))
        menu.addItem(.separator())
        // Only while a newer version is out; checking needs no click.
        if let update = UpdateChecker.shared.actionTitle {
            // No action while downloading: the menu then greys it out.
            let item = NSMenuItem(title: update, action: UpdateChecker.shared.canAct ? #selector(updateNow) : nil,
                                  keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(item)
        }
        addItem(menu, "Settings…", "", #selector(showSettings))
        addItem(menu, "Quit OmniHub", "", #selector(quit))
    }

    @discardableResult
    private func addItem(_ menu: NSMenu, _ title: String, _ shortcut: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: shortcut.isEmpty ? L(title) : "\(L(title))   \(shortcut)",
                              action: action,
                              keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    // MARK: Hotkeys

    private func registerHotKeys() {
        let center = HotKeyCenter.shared
        center.setHandler(.snip) { [weak self] in self?.startSnip(autoScroll: false) }
        center.setHandler(.longSnip) { [weak self] in self?.startSnip(autoScroll: true) }
        center.setHandler(.pinClipboard) { PinnedImageWindow.pinClipboard() }
        center.setHandler(.clipboard) { FloatingDockPanel.open(.clipboard) }
        center.setHandler(.terminal) { FloatingDockPanel.open(.terminal) }
        center.setHandler(.tasks) { FloatingDockPanel.open(.tasks) }
        center.setHandler(.dock) { FloatingDockPanel.toggle() }
        center.setHandler(.playPause) { MediaObserver.shared.togglePlayPause() }
        center.setHandler(.activity) { FloatingDockPanel.open(.activity) }
        center.registerAll()
    }

    // MARK: Actions

    @objc private func snipNormal() { startSnip(autoScroll: false) }
    @objc private func snipLong() { startSnip(autoScroll: true) }
    @objc private func pinClipboard() { PinnedImageWindow.pinClipboard() }
    @objc private func closePins() { PinnedImageWindow.closeAll() }
    @objc private func showClipboard() { FloatingDockPanel.open(.clipboard, toggle: false, pinned: false) }
    @objc private func showTerminal() { FloatingDockPanel.open(.terminal, toggle: false, pinned: false) }
    @objc private func showTasks() { FloatingDockPanel.open(.tasks, toggle: false, pinned: false) }
    @objc private func toggleDock() { FloatingDockPanel.toggle() }
    @objc private func togglePlayback() { MediaObserver.shared.togglePlayPause() }
    @objc private func showSettings() { FloatingDockPanel.open(.settings, toggle: false, pinned: false) }
    @objc private func showActivity() { FloatingDockPanel.open(.activity, toggle: false, pinned: false) }

    func startSnip(autoScroll: Bool, force: Bool = false) {
        guard !isSnipActive else { return }
        guard force || ScreenCapture.isTrusted() else {
            ScreenCapture.requestAccess()
            let alert = NSAlert()
            alert.messageText = L("Screen Recording permission needed")
            alert.informativeText = L("System Settings → Privacy & Security → Screen Recording: enable OmniHub, then restart it.\n\nIf it is already enabled, the app was updated: remove it from the list (−) and add it again.")
            alert.addButton(withTitle: L("Open System Settings"))
            alert.addButton(withTitle: L("Cancel"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                ScreenCapture.openPrivacySettings()
            }
            return
        }

        // Busy from the key press on: the capture arrives asynchronously and
        // a second press meanwhile must not start another one.
        isSnipActive = true
        statusItem.button?.appearsDisabled = true
        ScreenCapture.captureAllDisplays { [weak self] captures in
            guard let self else { return }
            guard !captures.isEmpty else {
                self.isSnipActive = false
                self.statusItem?.button?.appearsDisabled = false
                Toast.show(L("Screenshot failed: nothing captured"), duration: 2)
                return
            }
            let controller = OverlayController(captures: captures, autoScroll: autoScroll)
            self.controller = controller
            controller.present()
        }
    }

    func snipDidEnd() {
        isSnipActive = false
        statusItem?.button?.appearsDisabled = false
        // The controller may be the caller; release it after this call unwinds.
        let finished = controller
        controller = nil
        DispatchQueue.main.async { _ = finished }
    }

    @objc private func updateNow() { UpdateChecker.shared.updateNow() }
    @objc private func noop() {}
    @objc private func keepAwakePicked(_ sender: NSMenuItem) {
        KeepAwake.shared.choose(sender.tag < 0 ? nil : sender.tag)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }
}

private struct PinDTOProbe: Codable {
    let id: String
    let date: String
    let text: String
    let imageFile: String
}

// MARK: - Entry point

// Helper modes (ssh proxy, Telnet, askpass) run without starting the app.
NetHelpers.runIfRequested()
AppLanguage.start(arguments: CommandLine.arguments)

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
