import AppKit

/// Checks of Keep Awake, the battery, network speed, top apps, the status
/// icon and the card's opacity (`OmniHub --status-selftest [dir]`). Readings
/// are compared with what macOS's own tools report; with a directory,
/// pictures of the activity page, the Appearance tab and the icon are saved.
enum StatusSelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)\(ok || detail.isEmpty ? "" : "  — \(detail)")")
    }

    private static func wait(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    private static func shell(_ tool: String, _ arguments: [String]) -> String {
        (try? UpdateChecker.run(tool, arguments)) ?? ""
    }

    static func run(pictures: URL?) {
        setlinebuf(stdout)
        CalendarSource.allowPrompt = false
        FloatingDockPanel.headless = true
        let keys = ["dock.posX", "dock.posY", StatusIcon.ballKey, SettingsPane.cardOpacityKey,
                    StatusIcon.Config.ringKey, StatusIcon.Config.centerKey, StatusIcon.Config.dotsKey]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        keepAwake()
        battery()
        network()
        topApps()
        icon(pictures: pictures)
        card(pictures: pictures)
        // Put back before exit (which skips `defer`).
        for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) }
        KeepAwake.shared.turnOff()
        print(failures == 0 ? "RESULT: all passed" : "RESULT: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Keep Awake

    private static func keepAwake() {
        let awake = KeepAwake.shared
        func held() -> Bool { shell("/usr/bin/pmset", ["-g", "assertions"]).contains("OmniHub: Keep Awake") }
        awake.turnOn(seconds: 1.5)
        check("Keep Awake on: macOS lists the assertion", awake.isOn && held())
        wait(3) { !awake.isOn }
        check("it ends by itself when the time is up, and the assertion is gone", !awake.isOn && !held())
        awake.choose(30)
        check("30 minutes: \"\(awake.statusText)\"", awake.statusText == L("%ld min left", 30))
        awake.choose(0)
        check("until turned off: \"\(awake.statusText)\"", awake.isOn && awake.until == .distantFuture)
        awake.choose(nil)
        check("turned off from the menu: assertion released", !awake.isOn && !held())
    }

    // MARK: Battery

    private static func battery() {
        guard let info = BatteryInfo.read() else {
            check("battery: none on this Mac (tile hidden)", true)
            return
        }
        let registry = shell("/usr/sbin/ioreg", ["-rn", "AppleSmartBattery", "-d1"])
        func value(_ key: String) -> Int? {
            guard let range = registry.range(of: #""\#(key)" = (\d+)"#, options: .regularExpression) else { return nil }
            return Int(registry[range].split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "")
        }
        let batt = shell("/usr/bin/pmset", ["-g", "batt"])
        let percent = batt.range(of: #"(\d+)%"#, options: .regularExpression).map { Int(batt[$0].dropLast()) ?? -1 }
        check("battery: \(info.percent)% as pmset says (\(percent ?? -1)%)", percent.map { abs($0 - info.percent) <= 1 } ?? false)
        check("cycles \(info.cycleCount ?? -1) and design \(info.designCapacity ?? -1) mAh as ioreg says",
              info.cycleCount == value("CycleCount") && info.designCapacity == value("DesignCapacity"))
        let health = info.health ?? 0
        check("health \(Int(health * 100))% (raw max / design), temperature \(info.temperature ?? -1) °C",
              health > 0.4 && health < 1.2 && (info.temperature ?? 0) > 5 && (info.temperature ?? 0) < 70)
        check("state: \(info.stateText), adapter \(info.adapterWatts.map { "\($0) W" } ?? "none")",
              info.pluggedIn == batt.contains("AC Power"))
    }

    // MARK: Network

    /// Our counters against `netstat -ib` (the en* link rows).
    private static func network() {
        func netstat() -> (UInt64, UInt64) {
            var input: UInt64 = 0, output: UInt64 = 0
            for line in shell("/usr/sbin/netstat", ["-ib"]).split(separator: "\n") {
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                guard fields.count >= 10, fields[0].hasPrefix("en"), fields[2].hasPrefix("<Link#") else { continue }
                // Name Mtu Network [Address] Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
                let hasAddress = fields.count >= 11
                input += UInt64(fields[hasAddress ? 6 : 5]) ?? 0
                output += UInt64(fields[hasAddress ? 9 : 8]) ?? 0
            }
            return (input, output)
        }
        let ours = SystemStats.networkCounters()
        let theirs = netstat()
        func close(_ a: UInt64, _ b: UInt64) -> Bool {
            let high = Double(max(a, b)), low = Double(min(a, b))
            return high == 0 || (high - low) / high < 0.02 || high - low < 2_000_000
        }
        check("network counters match netstat: in \(ours.input) / \(theirs.0), out \(ours.output) / \(theirs.1)",
              ours.input > 0 && close(ours.input, theirs.0) && close(ours.output, theirs.1))
        SystemStats.shared.loadOnce {}
        wait(2)
        let stats = SystemStats.shared.snapshot
        check("rates read: ↓ \(SystemStats.rate(stats.netIn)) ↑ \(SystemStats.rate(stats.netOut))",
              stats.netIn >= 0 && stats.netOut >= 0)
    }

    // MARK: Top apps

    private static func topApps() {
        let fixture = """
          101  12.5  204800 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
          102  30.0  512000 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)
          103   2.0   10240 /usr/libexec/trustd
          104  40.0  102400 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
        """
        let entries = TopApps.parse(ps: fixture)
        let chrome = entries.first { $0.path == "/Applications/Google Chrome.app" }
        check("helpers add up under their app: Chrome \(chrome?.cpu ?? 0)% in \(chrome?.processes ?? 0) processes",
              chrome?.cpu == 42.5 && chrome?.processes == 2 && chrome?.memory == 716_800 * 1024)
        let byCPU = TopApps.top(entries, by: .cpu, count: 2).map(\.name)
        let byMemory = TopApps.top(entries, by: .memory, count: 1).map(\.name)
        check("ranked by CPU \(byCPU), by memory \(byMemory)",
              byCPU == ["Google Chrome", "Terminal"] && byMemory == ["Google Chrome"])
        check("a bare process is listed by its name", entries.contains { $0.name == "trustd" })

        var live: [TopApps.Entry] = []
        TopApps.sample { live = $0 }
        wait(10) { !live.isEmpty }
        // Started from a relative path here, so matched by name.
        check("live: \(live.count) apps and processes, this OmniHub among them",
              live.count > 20 && live.contains { $0.name == "OmniHub" && $0.path.hasSuffix(".app") })
    }

    // MARK: Status icon

    private static func pixels(_ image: NSImage, size: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Pixels close to `color` (by hue, saturated).
    private static func count(_ rep: NSBitmapImageRep, near color: NSColor) -> Int {
        guard let target = color.usingColorSpace(.deviceRGB) else { return 0 }
        var found = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let pixel = rep.colorAt(x: x, y: y), pixel.alphaComponent > 0.6 else { continue }
                if abs(pixel.redComponent - target.redComponent) < 0.15, abs(pixel.greenComponent - target.greenComponent) < 0.15,
                   abs(pixel.blueComponent - target.blueComponent) < 0.15 { found += 1 }
            }
        }
        return found
    }

    private static func icon(pictures: URL?) {
        var readings = StatusIcon.Readings()
        readings.cpu = 0.4
        readings.memory = 0.7
        readings.disk = 0.5
        readings.volume = 0.6
        readings.wifi = .bars(2)
        readings.netIn = 300_000
        readings.battery = .sample(percent: 64)
        var blank: [String] = []
        for ring in StatusIcon.Ring.allCases {
            for center in StatusIcon.Center.allCases {
                for dots in StatusIcon.Dots.allCases where ring != .none || center != .none || dots != .none {
                    let config = StatusIcon.Config(ring: ring, center: center, dots: dots)
                    let image = StatusIcon.image(size: 18, readings: readings, config: config, foreground: .white)
                    if let rep = pixels(image, size: 36), count(rep, near: .white) + count(rep, near: StatusIcon.Tint.cpu)
                        + count(rep, near: StatusIcon.Tint.memory) + count(rep, near: StatusIcon.Tint.disk) == 0 {
                        blank.append("\(ring)/\(center)/\(dots)")
                    }
                }
            }
        }
        check("every combination of ring, middle and dots draws something", blank.isEmpty, "\(blank)")

        let ringOnly = StatusIcon.Config(ring: .battery, center: .none, dots: .none)
        func batteryPixels(_ battery: BatteryInfo, _ tint: NSColor) -> Int {
            var state = readings
            state.battery = battery
            let image = StatusIcon.image(size: 40, readings: state, config: ringOnly, foreground: .white)
            return pixels(image, size: 80).map { count($0, near: tint) } ?? 0
        }
        check("battery ring: red when low", batteryPixels(.sample(percent: 12), StatusIcon.Tint.low) > 20)
        check("battery ring: green while charging", batteryPixels(.sample(percent: 50, charging: true, pluggedIn: true),
                                                                  StatusIcon.Tint.charging) > 20)
        check("battery ring: neither at 64% on battery",
              batteryPixels(.sample(percent: 64), StatusIcon.Tint.low) == 0
                && batteryPixels(.sample(percent: 64), StatusIcon.Tint.charging) == 0)
        var awake = readings
        awake.keepAwake = true
        let dot = pixels(StatusIcon.image(size: 40, readings: awake, config: ringOnly, foreground: .white), size: 80)
        check("Keep Awake shows an amber dot", dot.map { count($0, near: StatusIcon.Tint.awake) } ?? 0 > 10)

        // The dock ball switches between the logo and the status icon.
        _ = FloatingDockPanel.debugCardSize(page: .home, x: 0.5, y: 0)
        StatusIcon.shared.debugShow(readings)
        Prefs.set(StatusIcon.ballKey, 1)
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
        let onBall = FloatingDockPanel.debugBallShowsStatus
        if let pictures {
            let config = StatusIcon.Config(ring: .battery, center: .wifi, dots: .volume)
            let sheet = StatusIcon.image(size: 128, readings: readings, config: config, foreground: .white, plate: true)
            if let tiff = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: pictures.appendingPathComponent("status-icon.png"))
            }
            _ = FloatingDockPanel.snapshot(to: pictures.appendingPathComponent("ball-status.png"))
        }
        Prefs.set(StatusIcon.ballKey, 0)
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
        check("dock ball: status icon when picked, logo again after",
              onBall && !FloatingDockPanel.debugBallShowsStatus)
    }

    // MARK: Card

    private static func card(pictures: URL?) {
        SystemStats.shared.loadOnce {}
        _ = FloatingDockPanel.debugCardSize(page: .activity, x: 0.5, y: 0)
        wait(3) { FloatingDockPanel.debugActivity.contains { $0.hasPrefix("Top app") } }
        let rows = FloatingDockPanel.debugActivity
        for prefix in ["Keep Awake", "Network", "Battery", "Top app"] {
            let row = rows.first { $0.hasPrefix(prefix) }
            check("activity page: \(row ?? prefix + " missing")",
                  row != nil || (prefix == "Battery" && BatteryInfo.read() == nil))
        }
        if let pictures { _ = FloatingDockPanel.snapshot(to: pictures.appendingPathComponent("activity.png")) }

        Prefs.set(SettingsPane.cardOpacityKey, 55)
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
        let half = FloatingDockPanel.debugCardGlass
        Prefs.set(SettingsPane.cardOpacityKey, 100)
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
        let full = FloatingDockPanel.debugCardGlass
        check("opacity 55%: blur shown, artwork at \(half.artwork); 100%: no blur, artwork \(full.artwork)",
              half.shown && abs(half.artwork - 0.55) < 0.01 && !full.shown && full.artwork == 1)

        if let pictures {
            let settings = FloatingDockPanel.settings
            _ = FloatingDockPanel.debugCardSize(page: .settings, x: 0.5, y: 0)
            settings.select(tab: 6)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            _ = FloatingDockPanel.snapshot(to: pictures.appendingPathComponent("appearance.png"))
            if let bottom = settings.debugScrollToBottom() {
                _ = bottom
                _ = FloatingDockPanel.snapshot(to: pictures.appendingPathComponent("appearance-bottom.png"))
            }
        }
    }
}
