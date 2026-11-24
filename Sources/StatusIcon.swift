import AppKit
import CoreAudio
import AudioToolbox
import CoreWLAN

extension Notification.Name {
    static let statusIconChanged = Notification.Name("omnihub.statusIconChanged")
}

/// The status icon: a live, round icon in three parts, each showing what
/// is picked in Settings › Appearance — a ring around the edge (a level),
/// a glyph or number in the middle, and a row of five dots at the bottom
/// (another level). It can stand in for the runner in the menu bar, for
/// the logo on the dock ball, and be shown in the Dock.
final class StatusIcon {
    static let shared = StatusIcon()

    enum Ring: Int, CaseIterable { case none, battery, cpu, memory, disk }
    enum Center: Int, CaseIterable { case none, wifi, batteryPercent, cpuPercent, memoryPercent, network }
    enum Dots: Int, CaseIterable { case none, volume, cpu, memory, battery }

    struct Config: Equatable {
        var ring: Ring
        var center: Center
        var dots: Dots

        static let ringKey = "statusIcon.ring", centerKey = "statusIcon.center", dotsKey = "statusIcon.dots"

        /// Battery around the edge on a laptop, CPU on a desktop.
        static var current: Config {
            let ringFallback = BatteryInfo.read() == nil ? Ring.cpu : .battery
            return Config(ring: Ring(rawValue: Prefs.int(ringKey, ringFallback.rawValue)) ?? ringFallback,
                          center: Center(rawValue: Prefs.int(centerKey, Center.wifi.rawValue)) ?? .wifi,
                          dots: Dots(rawValue: Prefs.int(dotsKey, Dots.volume.rawValue)) ?? .volume)
        }
    }

    enum WiFi: Equatable { case off, disconnected, wired, bars(Int) }

    /// What the icon shows; read together so all parts agree.
    struct Readings: Equatable {
        var battery: BatteryInfo?
        var cpu: Double?
        var memory: Double?
        var disk: Double?
        var wifi: WiFi = .disconnected
        var volume: Float?
        var muted = false
        var netIn: Double = 0
        var netOut: Double = 0
        var keepAwake = false
    }

    /// Where the icon is used (Settings).
    static let menuBarKey = "status.style"          // 0 runner, 1 status icon
    static let ballKey = "dock.ballStyle"           // 0 logo, 1 status icon
    static let dockTileKey = "status.dockTile"

    static var inMenuBar: Bool { Prefs.int(menuBarKey, 0) == 1 }
    static var onBall: Bool { Prefs.int(ballKey, 0) == 1 }
    static var inDock: Bool { Prefs.bool(dockTileKey, false) }
    static var isUsed: Bool { inMenuBar || onBall || inDock }

    private(set) var readings = Readings()
    private let queue = DispatchQueue(label: "omnihub.statusicon", qos: .utility)
    private var reading = false

    private init() {
        let center = NotificationCenter.default
        for name in [Notification.Name.activityChanged, .keepAwakeChanged, .settingsChanged] {
            center.addObserver(self, selector: #selector(update), name: name, object: nil)
        }
    }

    /// Starts following the readings (they come with each activity sample).
    func start() { update() }

    /// Settings shows a preview: keep reading even when not used elsewhere.
    var previewShown = false {
        didSet { if previewShown { update() } }
    }

    @objc private func update() {
        guard Self.isUsed || previewShown, !reading else { return }
        reading = true
        let stats = SystemStats.shared.snapshot
        var next = Readings()
        next.cpu = stats.cpu
        next.memory = stats.memoryTotal > 0 ? Double(stats.memoryUsed) / Double(stats.memoryTotal) : nil
        next.disk = stats.diskTotal > 0 ? Double(stats.diskUsed) / Double(stats.diskTotal) : nil
        next.netIn = stats.netIn
        next.netOut = stats.netOut
        next.keepAwake = KeepAwake.shared.isOn
        let known = stats.battery
        // Wi-Fi and audio are asked off the main thread: CoreWLAN can stall.
        queue.async {
            next.battery = known ?? BatteryInfo.read()
            next.wifi = Self.readWiFi()
            (next.volume, next.muted) = Self.readVolume()
            DispatchQueue.main.async {
                self.reading = false
                guard next != self.readings else { return }
                self.readings = next
                NotificationCenter.default.post(name: .statusIconChanged, object: nil)
            }
        }
    }

    /// Test hook: show these readings.
    func debugShow(_ readings: Readings) {
        self.readings = readings
        NotificationCenter.default.post(name: .statusIconChanged, object: nil)
    }

    // MARK: Readers

    static func readWiFi() -> WiFi {
        guard let interface = CWWiFiClient.shared().interface() else { return wiredUp(except: nil) ? .wired : .off }
        let wired = wiredUp(except: interface.interfaceName)
        guard interface.powerOn() else { return wired ? .wired : .off }
        let rssi = interface.rssiValue()
        guard rssi != 0 else { return wired ? .wired : .disconnected }
        return .bars(rssi >= -60 ? 3 : rssi >= -70 ? 2 : 1)
    }

    /// An Ethernet port (`en*`, not the Wi-Fi one) has an address.
    private static func wiredUp(except wifi: String?) -> Bool {
        SystemStats.localAddresses().contains { $0.name.hasPrefix("en") && $0.name != wifi }
    }

    /// Volume (0…1) and mute of the default output device.
    static func readVolume() -> (Float?, Bool) {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return (nil, false) }
        var volume = Float32(0)
        size = UInt32(MemoryLayout<Float32>.size)
        address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                             mScope: kAudioDevicePropertyScopeOutput,
                                             mElement: kAudioObjectPropertyElementMain)
        let hasVolume = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr
        var mute = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyMute
        let hasMute = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &mute) == noErr
        return (hasVolume ? volume : nil, hasMute && mute != 0)
    }

    // MARK: Drawing

    /// Semantic colours, shared with the activity page.
    enum Tint {
        static let cpu = NSColor(srgbRed: 0.45, green: 0.85, blue: 1.0, alpha: 1)
        static let memory = NSColor(srgbRed: 0.45, green: 0.92, blue: 0.62, alpha: 1)
        static let disk = NSColor(srgbRed: 1.0, green: 0.72, blue: 0.40, alpha: 1)
        static let charging = NSColor(srgbRed: 0.30, green: 0.85, blue: 0.40, alpha: 1)
        static let low = NSColor(srgbRed: 1.0, green: 0.33, blue: 0.30, alpha: 1)
        static let lowPower = NSColor(srgbRed: 1.0, green: 0.80, blue: 0.20, alpha: 1)
        static let awake = NSColor(srgbRed: 1.0, green: 0.70, blue: 0.25, alpha: 1)
    }

    /// The icon at `size` points. `foreground` draws the neutral parts
    /// (a dynamic colour follows the menu bar's appearance, since the image
    /// draws when shown); `plate` fills a rounded square behind it (Dock);
    /// `inset` keeps it clear of a round mask (the dock ball).
    static func image(size: CGFloat, readings: Readings, config: Config,
                      foreground: NSColor, plate: Bool = false, inset: CGFloat = 0) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            var bounds = rect.insetBy(dx: inset, dy: inset)
            if plate {
                let square = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.06, dy: size * 0.06),
                                          xRadius: size * 0.2, yRadius: size * 0.2)
                NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.17, blue: 0.24, alpha: 1),
                           ending: NSColor(srgbRed: 0.05, green: 0.05, blue: 0.09, alpha: 1))?.draw(in: square, angle: -90)
                bounds = rect.insetBy(dx: size * 0.17, dy: size * 0.17)
            }
            draw(in: bounds, readings: readings, config: config, foreground: foreground)
            return true
        }
    }

    private static func draw(in rect: NSRect, readings: Readings, config: Config, foreground: NSColor) {
        let side = min(rect.width, rect.height)
        let line = max(1.4, side * 0.095)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = side / 2 - line / 2

        // Ring: a dim track, the level clockwise from the top.
        if let (level, tint) = ringLevel(config.ring, readings, foreground: foreground) {
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = line
            foreground.withAlphaComponent(0.22).setStroke()
            track.stroke()
            if level > 0.005 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                              endAngle: 90 - 360 * CGFloat(min(level, 1)), clockwise: true)
                arc.lineWidth = line
                arc.lineCapStyle = .round
                tint.setStroke()
                arc.stroke()
            }
        }

        // Dots: five, filled up to the level, near the bottom.
        let hasDots = config.dots != .none
        if hasDots, let (level, tint) = dotsLevel(config.dots, readings, foreground: foreground) {
            let dot = max(1.3, side * 0.085)
            let gap = dot * 0.55
            let width = dot * 5 + gap * 4
            let y = rect.minY + side * 0.2
            let lit = Int((level * 5).rounded(.up))
            for index in 0..<5 {
                let x = center.x - width / 2 + CGFloat(index) * (dot + gap)
                (index < lit ? tint : foreground.withAlphaComponent(0.25)).setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: dot, height: dot)).fill()
            }
        }

        // Middle: a glyph or a number, raised a little when dots sit below.
        let middle = NSRect(x: center.x - side * 0.3, y: center.y - side * 0.3 + (hasDots ? side * 0.08 : 0),
                            width: side * 0.6, height: side * 0.6)
        drawCenter(config.center, readings, in: middle, foreground: foreground)

        // Keep Awake: a small amber dot at the top right.
        if readings.keepAwake {
            let dot = max(2.5, side * 0.17)
            Tint.awake.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - dot, y: rect.maxY - dot, width: dot, height: dot)).fill()
        }
    }

    static func batteryTint(_ battery: BatteryInfo, foreground: NSColor) -> NSColor {
        if battery.charging || battery.isFull { return Tint.charging }
        if battery.percent <= 20 { return Tint.low }
        if battery.lowPowerMode { return Tint.lowPower }
        return foreground
    }

    private static func ringLevel(_ ring: Ring, _ r: Readings, foreground: NSColor) -> (Double, NSColor)? {
        switch ring {
        case .none: return nil
        case .battery:
            guard let battery = r.battery else { return nil }
            return (Double(battery.percent) / 100, batteryTint(battery, foreground: foreground))
        case .cpu: return (r.cpu ?? 0, Tint.cpu)
        case .memory: return (r.memory ?? 0, Tint.memory)
        case .disk: return (r.disk ?? 0, Tint.disk)
        }
    }

    private static func dotsLevel(_ dots: Dots, _ r: Readings, foreground: NSColor) -> (Double, NSColor)? {
        switch dots {
        case .none: return nil
        case .volume: return (r.muted ? 0 : Double(r.volume ?? 0), foreground)
        case .cpu: return (r.cpu ?? 0, Tint.cpu)
        case .memory: return (r.memory ?? 0, Tint.memory)
        case .battery:
            guard let battery = r.battery else { return nil }
            return (Double(battery.percent) / 100, batteryTint(battery, foreground: foreground))
        }
    }

    private static func drawCenter(_ kind: Center, _ r: Readings, in box: NSRect, foreground: NSColor) {
        func number(_ fraction: Double?) {
            let text = fraction.map { "\(Int(($0 * 100).rounded()))" } ?? "–"
            drawText(text, in: box, foreground: foreground)
        }
        switch kind {
        case .none: return
        case .wifi:
            let (name, value): (String, Double?) = {
                switch r.wifi {
                case .off: return ("wifi.slash", nil)
                case .disconnected: return ("wifi.exclamationmark", nil)
                case .wired: return ("cable.connector.horizontal", nil)
                case .bars(let bars): return ("wifi", Double(bars) / 3)
                }
            }()
            drawSymbol(name, value: value, in: box, foreground: foreground)
        case .batteryPercent: number(r.battery.map { Double($0.percent) / 100 })
        case .cpuPercent: number(r.cpu)
        case .memoryPercent: number(r.memory)
        case .network:
            // The busier direction, as an arrow; brighter the more it moves.
            let down = r.netIn >= r.netOut
            let busy = min(1, log10(max(1, max(r.netIn, r.netOut)) / 1024 + 1) / 4)
            drawSymbol(down ? "arrow.down" : "arrow.up", value: nil, in: box,
                       foreground: foreground.withAlphaComponent(0.45 + 0.55 * busy))
        }
    }

    private static func drawSymbol(_ name: String, value: Double?, in box: NSRect, foreground: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: box.height * 0.82, weight: .bold)
        let base = value.flatMap { NSImage(systemSymbolName: name, variableValue: $0, accessibilityDescription: nil) }
            ?? NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "network", accessibilityDescription: nil)
        guard let symbol = base?.withSymbolConfiguration(config) else { return }
        // Tint: draw the symbol as a mask filled with the colour.
        let size = symbol.size
        let scale = min(box.width / size.width, box.height / size.height, 1)
        let target = NSRect(x: box.midX - size.width * scale / 2, y: box.midY - size.height * scale / 2,
                            width: size.width * scale, height: size.height * scale)
        let tinted = NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: rect)
            foreground.set()
            rect.fill(using: .sourceIn)
            return true
        }
        tinted.draw(in: target)
    }

    private static func drawText(_ text: String, in box: NSRect, foreground: NSColor) {
        let size = box.height * (text.count >= 3 ? 0.62 : 0.78)
        let font = NSFont.systemFont(ofSize: size, weight: .heavy)
        let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? font
        let attributes: [NSAttributedString.Key: Any] = [.font: rounded, .foregroundColor: foreground]
        let measured = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: box.midX - measured.width / 2, y: box.midY - measured.height / 2),
                                withAttributes: attributes)
    }

    /// The icon as the current settings and readings make it.
    func image(size: CGFloat, foreground: NSColor, plate: Bool = false, inset: CGFloat = 0) -> NSImage {
        Self.image(size: size, readings: readings, config: .current, foreground: foreground, plate: plate, inset: inset)
    }

    // MARK: Text

    static func title(_ ring: Ring) -> String {
        switch ring {
        case .none: return L("Nothing")
        case .battery: return L("Battery")
        case .cpu: return "CPU"
        case .memory: return L("Memory")
        case .disk: return L("Disk")
        }
    }

    static func title(_ center: Center) -> String {
        switch center {
        case .none: return L("Nothing")
        case .wifi: return L("Wi-Fi / Ethernet")
        case .batteryPercent: return L("Battery %")
        case .cpuPercent: return L("CPU %")
        case .memoryPercent: return L("Memory %")
        case .network: return L("Network activity")
        }
    }

    static func title(_ dots: Dots) -> String {
        switch dots {
        case .none: return L("Nothing")
        case .volume: return L("Volume")
        case .cpu: return "CPU"
        case .memory: return L("Memory")
        case .battery: return L("Battery")
        }
    }

    /// One line for tool tips and diagnostics.
    var summary: String {
        var parts: [String] = []
        if let battery = readings.battery { parts.append("\(L("Battery")) \(battery.percent)% · \(battery.stateText)") }
        if let cpu = readings.cpu { parts.append("CPU \(Int((cpu * 100).rounded()))%") }
        if let memory = readings.memory { parts.append("\(L("Memory")) \(Int((memory * 100).rounded()))%") }
        if let volume = readings.volume {
            parts.append(readings.muted ? L("Muted") : "\(L("Volume")) \(Int((volume * 100).rounded()))%")
        }
        if readings.keepAwake { parts.append(L("Keep Awake")) }
        return "OmniHub · " + parts.joined(separator: " · ")
    }
}
