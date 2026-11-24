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
        // This process's assertion only: a running OmniHub may hold its own.
        func held() -> Bool {
            shell("/usr/bin/pmset", ["-g", "assertions"]).split(separator: "\n")
                .contains { $0.contains("pid \(getpid())(") && $0.contains("OmniHub: Keep Awake") }
        }
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
        // Joined to Wi-Fi (an address on it) reads as connected, with or
        // without the signal strength.
        let wifi = StatusIcon.readWiFi()
        let joined = SystemStats.localAddresses().contains { $0.name == "en0" }
        check("Wi-Fi: \(wifi) (en0 has an address: \(joined))", !joined || {
            if case .bars = wifi { return true }
            return wifi == .connected
        }())
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
        check("battery ring: red at 12 %", batteryPixels(.sample(percent: 12), StatusIcon.Tint.low) > 20)
        check("battery ring: green at 92 %, charging or not",
              batteryPixels(.sample(percent: 92), StatusIcon.Tint.charging) > 20
                && batteryPixels(.sample(percent: 92, charging: true, pluggedIn: true), StatusIcon.Tint.charging) > 20)
        check("battery ring: red while charging at 15 %",
              batteryPixels(.sample(percent: 15, charging: true, pluggedIn: true), StatusIcon.Tint.low) > 20)
        check("battery ring: neither red nor green at 50 %",
              batteryPixels(.sample(percent: 50), StatusIcon.Tint.low) == 0
                && batteryPixels(.sample(percent: 50), StatusIcon.Tint.charging) == 0)
        // The charge colour moves steadily from red to green.
        let hues = stride(from: 0, through: 100, by: 5).map { percent -> CGFloat in
            let color = StatusIcon.chargeTint(percent).usingColorSpace(.sRGB) ?? .black
            return color.hueComponent
        }
        check("charge colour: red to 20 %, green from 80 %, hue rising in between",
              StatusIcon.chargeTint(5) == StatusIcon.Tint.low && StatusIcon.chargeTint(20) == StatusIcon.Tint.low
                && StatusIcon.chargeTint(80) == StatusIcon.Tint.charging && StatusIcon.chargeTint(100) == StatusIcon.Tint.charging
                && zip(hues, hues.dropFirst()).allSatisfy { $0.1 >= $0.0 - 0.001 },
              hues.map { String(format: "%.2f", $0) }.joined(separator: " "))
        // Volume 50% lights two of the four dots, at menu bar size too.
        var half = readings
        half.volume = 0.5
        for size in [22, 40] as [CGFloat] {
            let config = StatusIcon.Config(ring: .battery, center: .wifi, dots: .volume)
            let image = StatusIcon.image(size: size, readings: half, config: config, foreground: .white)
            let scale: CGFloat = 4
            guard let rep = pixels(image, size: Int(size * scale)) else { continue }
            let lit = StatusIcon.dotCentres(in: NSRect(x: 0, y: 0, width: size, height: size), head: true).map { point -> Bool in
                let pixel = rep.colorAt(x: Int(point.x * scale), y: Int((size - point.y) * scale))
                return (pixel?.alphaComponent ?? 0) > 0.8
            }
            check("volume 50%: dots lit \(lit.map { $0 ? "●" : "○" }.joined()) at \(Int(size)) pt",
                  lit == [true, true, false, false])
        }

        // The dots sit on the ring's circle: as low as the ring goes, and
        // not cut off at the bottom of the menu bar icon.
        for head in [true, false] {
            let config = StatusIcon.Config(ring: head ? .battery : .cpu, center: .wifi, dots: .volume)
            var state = readings
            state.volume = 1
            state.battery = .sample(percent: 83)
            let rect = NSRect(x: 0, y: 0, width: 22, height: 22)
            let lowest = StatusIcon.dotCentres(in: rect, head: head).map(\.y).min() ?? 99
            let image = StatusIcon.image(size: 22, readings: state, config: config, foreground: .white)
            if let rep = pixels(image, size: 88) {
                let bottomRow = (0..<88).filter { (rep.colorAt(x: $0, y: 87)?.alphaComponent ?? 0) > 0.3 }.count
                let nearBottom = (0..<88).filter { (rep.colorAt(x: $0, y: 84)?.alphaComponent ?? 0) > 0.3 }.count
                check("dots \(head ? "under a head" : "without a head"): lowest at \(String(format: "%.1f", lowest)) pt, "
                        + "touching the bottom \(nearBottom > 0), cut off \(bottomRow > 0)",
                      lowest < 2 && bottomRow == 0)
            }
        }

        // The figure on top stays inside the menu bar icon.
        do {
            let config = StatusIcon.Config(ring: .battery, center: .wifi, dots: .volume)
            var state = readings
            state.battery = .sample(percent: 83)
            let image = StatusIcon.image(size: 22, readings: state, config: config, foreground: .white)
            if let rep = pixels(image, size: 88) {
                let topRow = (0..<88).filter { (rep.colorAt(x: $0, y: 0)?.alphaComponent ?? 0) > 0.3 }.count
                check("the figure on top is not cut off (\(topRow) pixels on the top edge)", topRow == 0)
            }
        }

        // The ring's head for every battery state.
        func head(_ battery: BatteryInfo?) -> String {
            let head = StatusIcon.debugHead(battery)
            return [head.symbol.map { "[\($0)]" }, head.text].compactMap { $0 }.joined(separator: " ")
        }
        let cases: [(String, BatteryInfo?, String)] = [
            ("on battery", .sample(percent: 76), "76"),
            ("low", .sample(percent: 15), "15"),
            ("very low", .sample(percent: 8), "8"),
            ("Low Power Mode", .sample(percent: 55, lowPowerMode: true), "55"),
            ("charging", .sample(percent: 60, charging: true, pluggedIn: true), "[bolt.fill]"),
            ("plugged in, not charging", .sample(percent: 80, pluggedIn: true), "[powerplug.fill]"),
            ("charged", .sample(percent: 100, pluggedIn: true), "[powerplug.fill]"),
            ("no battery", nil, "[powerplug.fill]")
        ]
        let wrong = cases.filter { head($0.1) != $0.2 }.map { "\($0.0): \(head($0.1))" }
        check("head: figure on battery, bolt charging, plug on the adapter or without a battery", wrong.isEmpty, "\(wrong)")
        check("head: the figure turns red at 10 % or less, yellow in Low Power Mode, bolt and plug green",
              StatusIcon.debugHead(.sample(percent: 8)).color == StatusIcon.Tint.low
                && StatusIcon.debugHead(.sample(percent: 15)).color != StatusIcon.Tint.low
                && StatusIcon.debugHead(.sample(percent: 55, lowPowerMode: true)).color == StatusIcon.Tint.lowPower
                && StatusIcon.debugHead(.sample(percent: 60, charging: true, pluggedIn: true)).color == StatusIcon.Tint.charging
                && StatusIcon.debugHead(.sample(percent: 100, pluggedIn: true)).color == StatusIcon.Tint.charging)
        Prefs.set(StatusIcon.figureWhilePluggedKey, true)
        let plugged = (head(.sample(percent: 80, pluggedIn: true)), head(.sample(percent: 60, charging: true, pluggedIn: true)))
        Prefs.set(StatusIcon.figureWhilePluggedKey, nil)
        check("figure while plugged in: \(plugged.0) / \(plugged.1)", plugged == ("80", "[bolt.fill] 60"))

        if let pictures {
            // A sheet of every battery state, on the Dock plate.
            let sheet = NSImage(size: NSSize(width: 128 * 4, height: 128 * 2), flipped: false) { _ in
                for (index, item) in cases.enumerated() {
                    var state = readings
                    state.battery = item.1
                    let config = StatusIcon.Config(ring: .battery, center: .wifi, dots: .volume)
                    StatusIcon.image(size: 128, readings: state, config: config, foreground: .white, plate: .square)
                        .draw(in: NSRect(x: CGFloat(index % 4) * 128, y: CGFloat(1 - index / 4) * 128, width: 128, height: 128))
                }
                return true
            }
            if let tiff = sheet.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: pictures.appendingPathComponent("battery-states.png"))
            }
        }
        var awake = readings
        awake.keepAwake = true
        // Keep Awake: an amber cup beside the figure on the ring's top (the
        // figure stays whole, nothing cut off at the top), or in the corner
        // when there is no ring.
        do {
            let withRing = StatusIcon.Config(ring: .battery, center: .wifi, dots: .volume)
            let noRing = StatusIcon.Config(ring: .none, center: .wifi, dots: .volume)
            func amber(_ config: StatusIcon.Config, _ percent: Int, size: CGFloat) -> (count: Int, top: Int, highest: Int) {
                var state = awake
                state.battery = .sample(percent: percent)
                let scale: CGFloat = 4
                let image = StatusIcon.image(size: size, readings: state, config: config, foreground: .white)
                guard let rep = pixels(image, size: Int(size * scale)) else { return (0, 0, 0) }
                let side = Int(size * scale)
                var count = 0, highest = side
                for y in 0..<side { for x in 0..<side {
                    guard let pixel = rep.colorAt(x: x, y: y), pixel.alphaComponent > 0.5,
                          (pixel.usingColorSpace(.sRGB).map { abs($0.redComponent - 1) < 0.08 && abs($0.greenComponent - 0.70) < 0.12
                            && $0.blueComponent < 0.45 } ?? false) else { continue }
                    count += 1
                    highest = min(highest, y)
                } }
                let top = (0..<side).filter { (rep.colorAt(x: $0, y: 0)?.alphaComponent ?? 0) > 0.3 }.count
                return (count, top, highest)
            }
            let beside = amber(withRing, 77, size: 40)
            let full = amber(withRing, 100, size: 22)
            let corner = amber(noRing, 77, size: 40)
            check("Keep Awake: a cup beside the figure (\(beside.count) amber pixels, top third), "
                    + "at 100 % in the menu bar too (\(full.count), \(full.top) pixels on the top edge), in the corner with no ring (\(corner.count))",
                  beside.count > 60 && beside.highest < 160 / 3 && full.count > 10 && full.top == 0 && corner.count > 60)
            if let pictures {
                // Menu bar size (light and dark bars, at 4×) at 77 % and 100 %, and on the Dock plate.
                let sheet = NSImage(size: NSSize(width: 88 * 3 + 128, height: 128), flipped: false) { _ in
                    for (index, item) in [(NSColor(white: 0.93, alpha: 1), 77), (NSColor(white: 0.16, alpha: 1), 77),
                                          (NSColor(white: 0.16, alpha: 1), 100)].enumerated() {
                        var state = awake
                        state.battery = .sample(percent: item.1)
                        state.volume = 0.5
                        let box = NSRect(x: CGFloat(index) * 88, y: 20, width: 88, height: 88)
                        item.0.setFill()
                        box.fill()
                        StatusIcon.image(size: 22, readings: state, config: withRing,
                                         foreground: index == 0 ? .black : .white).draw(in: box)
                    }
                    var state = awake
                    state.battery = .sample(percent: 77)
                    state.volume = 0.5
                    StatusIcon.image(size: 128, readings: state, config: withRing, foreground: .white, plate: .square)
                        .draw(in: NSRect(x: 264, y: 0, width: 128, height: 128))
                    return true
                }
                if let tiff = sheet.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: pictures.appendingPathComponent("keep-awake.png"))
                }
            }
        }

        // The dock ball switches between the logo and the status icon.
        _ = FloatingDockPanel.debugCardSize(page: .home, x: 0.5, y: 0)
        StatusIcon.shared.debugShow(readings)
        Prefs.set(StatusIcon.ballKey, 1)
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
        let onBall = FloatingDockPanel.debugBallShowsStatus
        if let pictures {
            let config = StatusIcon.Config(ring: .battery, center: .wifi, dots: .volume)
            let sheet = StatusIcon.image(size: 128, readings: readings, config: config, foreground: .white, plate: .square)
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
