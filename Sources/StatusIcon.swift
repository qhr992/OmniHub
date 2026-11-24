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

    /// `connected`: joined, strength unknown — macOS gives the signal
    /// strength only to apps with Location access.
    enum WiFi: Equatable { case off, disconnected, wired, connected, bars(Int) }

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
        if rssi != 0 { return .bars(rssi >= -60 ? 3 : rssi >= -70 ? 2 : 1) }
        // No strength without Location access: an address on the Wi-Fi
        // port still means it is joined.
        let name = interface.interfaceName
        if SystemStats.localAddresses().contains(where: { $0.name == name }) { return .connected }
        return wired ? .wired : .disconnected
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

    /// What the icon sits on: nothing (menu bar), a rounded square (Dock)
    /// or a disc (the dock ball). On a plate the palette's background and
    /// middle colours apply; without one the neutral parts follow the menu
    /// bar's own colour.
    enum Plate { case none, square, circle }

    /// The icon at `size` points. `foreground` draws the neutral parts
    /// (a dynamic colour follows the menu bar's appearance, since the image
    /// draws when shown); `inset` keeps it clear of a round mask.
    static func image(size: CGFloat, readings: Readings, config: Config, foreground: NSColor,
                      plate: Plate = .none, inset: CGFloat = 0, palette: Palette = .current) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            var bounds = rect.insetBy(dx: inset, dy: inset)
            let base = palette.plate ?? Palette.defaultPlate
            let top = base.blended(withFraction: 0.18, of: .white) ?? base
            let bottom = base.blended(withFraction: 0.35, of: .black) ?? base
            switch plate {
            case .none:
                break
            case .square:
                let square = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.06, dy: size * 0.06),
                                          xRadius: size * 0.2, yRadius: size * 0.2)
                NSGradient(starting: top, ending: bottom)?.draw(in: square, angle: -90)
                bounds = rect.insetBy(dx: size * 0.17, dy: size * 0.17)
            case .circle:
                NSGradient(starting: top, ending: bottom)?.draw(in: NSBezierPath(ovalIn: rect), angle: -90)
            }
            let colors = Colors(palette: palette, foreground: foreground, onPlate: plate != .none)
            draw(in: bounds, readings: readings, config: config, colors: colors)
            return true
        }
    }

    /// The colours one drawing uses.
    private struct Colors {
        let neutral: NSColor        // tracks, unlit dots
        let center: NSColor
        let ring: NSColor?          // nil: by what the ring shows
        let dots: NSColor?
        let semantic: Bool

        init(palette: Palette, foreground: NSColor, onPlate: Bool) {
            center = onPlate ? (palette.center ?? foreground) : foreground
            neutral = onPlate ? center : foreground
            ring = palette.ring
            dots = palette.dots
            semantic = palette.semantic
        }
    }

    // The layout follows the iPhone "Duo" status icon, by way of Status Trio
    // (github.com/lingyired/status-trio, Apache-2.0), drawn here in our own
    // code: an open ring whose top gap holds a head (a figure or a sign),
    // a glyph in the middle, and dots (or a short arc) in the bottom gap.

    /// The ring runs clockwise from bottom left (225°) over the top to
    /// bottom right (−45°); the bottom 90° are left open for the dots.
    private static let ringStart: CGFloat = 225
    private static let ringSweep: CGFloat = 270

    /// Bottom style: dots (0) or a short arc (1).
    static let bottomStyleKey = "statusIcon.bottomStyle"
    /// Show the figure, not the plug / bolt, while on the adapter.
    static let figureWhilePluggedKey = "statusIcon.figureWhilePlugged"

    /// Where the ring sits in `rect`. With a head, the ring is a little
    /// smaller and lower, so the figure on its top stays inside.
    private struct Geometry {
        let side: CGFloat, line: CGFloat, center: NSPoint, radius: CGFloat

        init(_ rect: NSRect, head: Bool) {
            side = min(rect.width, rect.height)
            line = max(1.4, side * 0.1)
            if head {
                radius = side / 2 - line / 2 - side * 0.05
                center = NSPoint(x: rect.midX, y: rect.maxY - radius - side * 0.14)
            } else {
                radius = side / 2 - line / 2
                center = NSPoint(x: rect.midX, y: rect.midY)
            }
        }
    }

    /// Centres of the four bottom dots (test hook).
    static func dotCentres(in rect: NSRect, head: Bool) -> [NSPoint] {
        dotCentres(Geometry(rect, head: head))
    }

    /// The dots sit on the ring's own circle, evenly spaced across the open
    /// bottom (243°, 261°, 279°, 297°), and are as thick as the ring, so
    /// ring and dots read as one round outline.
    private static func dotCentres(_ geometry: Geometry) -> [NSPoint] {
        let (center, radius) = (geometry.center, geometry.radius)
        let step = (360 - ringSweep) / 5
        return (1...4).map { (index: Int) in
            let angle = (ringStart + step * CGFloat(index)) * .pi / 180
            return NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }
    }

    /// The bottom arc's span: the open bottom less room for the ring's
    /// round ends and a gap the width of the line.
    private static func bottomArc(_ geometry: Geometry) -> (start: CGFloat, sweep: CGFloat) {
        let margin = geometry.line * 1.6 / geometry.radius * 180 / .pi
        let gap = 360 - ringSweep
        return (ringStart + margin, max(10, gap - 2 * margin))
    }

    private static func draw(in rect: NSRect, readings: Readings, config: Config, colors: Colors) {
        // Head and ring.
        let head = ringHead(config.ring, readings, colors: colors)
        let geometry = Geometry(rect, head: head != nil)
        let (side, line, center, radius) = (geometry.side, geometry.line, geometry.center, geometry.radius)
        if let (level, tint) = ringLevel(config.ring, readings, colors: colors) {
            // The gap at the top fits the head, with a little air.
            let headWidth = head.map { headSize($0, side: side).width } ?? 0
            let gap = head == nil ? 0 : min(70, (headWidth / 2 + line * 0.9) / radius * 180 / .pi)
            let usable = ringSweep - 2 * gap
            let filled = usable * CGFloat(min(max(level, 0), 1))
            let track = (colors.ring ?? colors.neutral).withAlphaComponent(0.25)
            // Left part: 225° → 90°+gap; right part: 90°−gap → −45°.
            let left = ringStart - 90 - gap
            func arc(from: CGFloat, sweep: CGFloat, _ color: NSColor) {
                guard sweep > 0.1 else { return }
                let path = NSBezierPath()
                path.appendArc(withCenter: center, radius: radius, startAngle: from, endAngle: from - sweep, clockwise: true)
                path.lineWidth = line
                path.lineCapStyle = .round
                color.setStroke()
                path.stroke()
            }
            arc(from: ringStart, sweep: left, track)
            arc(from: 90 - gap, sweep: left, track)
            arc(from: ringStart, sweep: min(filled, left), tint)
            if filled > left { arc(from: 90 - gap, sweep: filled - left, tint) }
            if let head { drawHead(head, at: NSPoint(x: center.x, y: center.y + radius), side: side) }
        }

        // Bottom: four dots along the open part of the ring, or an arc.
        let hasBottom = config.dots != .none
        if hasBottom, let (level, tint) = dotsLevel(config.dots, readings, colors: colors) {
            let unlit = (colors.dots ?? colors.neutral).withAlphaComponent(0.25)
            if Prefs.int(bottomStyleKey, 0) == 1 {
                let span = bottomArc(geometry)
                let path = { (sweep: CGFloat) -> NSBezierPath in
                    let path = NSBezierPath()
                    path.appendArc(withCenter: center, radius: radius, startAngle: span.start, endAngle: span.start + sweep)
                    path.lineWidth = line
                    path.lineCapStyle = .round
                    return path
                }
                unlit.setStroke()
                path(span.sweep).stroke()
                if level > 0.01 {
                    tint.setStroke()
                    path(span.sweep * CGFloat(min(level, 1))).stroke()
                }
            } else {
                let dot = line
                let lit = level <= 0 ? 0 : Int((level * 4).rounded(.up))
                for (index, point) in dotCentres(geometry).enumerated() {
                    (index < lit ? tint : unlit).setFill()
                    NSBezierPath(ovalIn: NSRect(x: point.x - dot / 2, y: point.y - dot / 2, width: dot, height: dot)).fill()
                }
            }
        }

        // Middle.
        let box = side * 0.5
        let middle = NSRect(x: center.x - box / 2, y: center.y - box / 2 - side * 0.03, width: box, height: box)
        drawCenter(config.center, readings, in: middle, foreground: colors.center)

        // Keep Awake: a small amber dot in the top right corner.
        if readings.keepAwake {
            let dot = max(2.5, side * 0.15)
            Tint.awake.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - dot, y: rect.maxY - dot, width: dot, height: dot)).fill()
        }
    }

    /// What sits in the ring's top gap.
    private struct Head {
        var text: String?
        var symbol: String?
        var color: NSColor
    }

    private static func ringHead(_ ring: Ring, _ r: Readings, colors: Colors) -> Head? {
        func figure(_ value: Double?) -> Head {
            Head(text: value.map { "\(Int(($0 * 100).rounded()))" } ?? "–", symbol: nil, color: colors.center)
        }
        switch ring {
        case .none: return nil
        case .cpu: return figure(r.cpu)
        case .memory: return figure(r.memory)
        case .disk: return figure(r.disk)
        case .battery:
            // No battery (a desktop Mac): always on the adapter.
            guard let battery = r.battery else { return Head(text: nil, symbol: "powerplug.fill", color: colors.center) }
            let text = "\(battery.percent)"
            let figure = Prefs.bool(figureWhilePluggedKey, false)
            // The sign takes the state's colour; the figure stays neutral
            // unless it is a warning (red when very low, yellow in Low
            // Power Mode).
            func tinted(_ color: NSColor) -> NSColor { colors.semantic ? color : colors.center }
            switch battery.state {
            case .charging:
                return Head(text: figure ? text : nil, symbol: "bolt.fill", color: tinted(Tint.charging))
            case .full, .held:
                return figure ? Head(text: text, symbol: nil, color: colors.center)
                    : Head(text: nil, symbol: "powerplug.fill", color: tinted(Tint.charging))
            case .critical: return Head(text: text, symbol: nil, color: tinted(Tint.low))
            case .lowPower: return Head(text: text, symbol: nil, color: tinted(Tint.lowPower))
            case .low, .normal: return Head(text: text, symbol: nil, color: colors.center)
            }
        }
    }

    /// Test hook: the head for a battery (text, sign, colour).
    static func debugHead(_ battery: BatteryInfo?, palette: Palette = Palette()) -> (text: String?, symbol: String?, color: NSColor) {
        var readings = Readings()
        readings.battery = battery
        let head = ringHead(.battery, readings, colors: Colors(palette: palette, foreground: .white, onPlate: true))
        return (head?.text, head?.symbol, head?.color ?? .clear)
    }

    private static func headFont(side: CGFloat) -> NSFont {
        let size = side * 0.3
        let font = NSFont.systemFont(ofSize: size, weight: .heavy)
        return font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? font
    }

    private static func headSize(_ head: Head, side: CGFloat) -> NSSize {
        let font = headFont(side: side)
        var width: CGFloat = 0
        if let text = head.text { width += (text as NSString).size(withAttributes: [.font: font]).width }
        if head.symbol != nil { width += side * (head.text == nil ? 0.3 : 0.2) + (head.text == nil ? 0 : side * 0.02) }
        return NSSize(width: width, height: side * 0.3)
    }

    private static func drawHead(_ head: Head, at point: NSPoint, side: CGFloat) {
        let size = headSize(head, side: side)
        var x = point.x - size.width / 2
        if let symbol = head.symbol {
            let width = side * (head.text == nil ? 0.3 : 0.2)
            drawSymbol(symbol, value: nil, in: NSRect(x: x, y: point.y - side * 0.18, width: width, height: side * 0.36),
                       foreground: head.color)
            x += width + (head.text == nil ? 0 : side * 0.02)
        }
        if let text = head.text {
            let attributes: [NSAttributedString.Key: Any] = [.font: headFont(side: side), .foregroundColor: head.color]
            let measured = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: NSPoint(x: x, y: point.y - measured.height / 2), withAttributes: attributes)
        }
    }

    /// Colour stops of the charge: red up to 20 %, through orange and
    /// yellow, green from 80 %.
    static let chargeStops: [(percent: Double, color: NSColor)] = [
        (20, Tint.low),
        (40, NSColor(srgbRed: 1.0, green: 0.58, blue: 0.20, alpha: 1)),
        (60, NSColor(srgbRed: 1.0, green: 0.82, blue: 0.22, alpha: 1)),
        (80, Tint.charging)
    ]

    /// The colour of a charge, blended between the stops, so it shifts as
    /// the battery fills or drains.
    static func chargeTint(_ percent: Int) -> NSColor {
        let value = Double(percent)
        guard let first = chargeStops.first, let last = chargeStops.last else { return Tint.charging }
        if value <= first.percent { return first.color }
        if value >= last.percent { return last.color }
        for (lower, upper) in zip(chargeStops, chargeStops.dropFirst()) where value <= upper.percent {
            let fraction = (value - lower.percent) / (upper.percent - lower.percent)
            let from = lower.color.usingColorSpace(.sRGB) ?? lower.color
            return from.blended(withFraction: CGFloat(fraction), of: upper.color) ?? from
        }
        return last.color
    }

    /// The battery's colour: by charge, whatever the state (the head shows
    /// charging, the adapter and Low Power Mode).
    static func batteryTint(_ battery: BatteryInfo) -> NSColor { chargeTint(battery.percent) }

    /// The battery's colour: by charge when that is on, else the part's own.
    private static func battery(_ battery: BatteryInfo, own: NSColor?, colors: Colors) -> NSColor {
        colors.semantic ? batteryTint(battery) : own ?? colors.neutral
    }

    private static func ringLevel(_ ring: Ring, _ r: Readings, colors: Colors) -> (Double, NSColor)? {
        switch ring {
        case .none: return nil
        case .battery:
            // No battery: an empty track under the plug.
            guard let info = r.battery else { return (0, colors.neutral) }
            return (Double(info.percent) / 100, battery(info, own: colors.ring, colors: colors))
        case .cpu: return (r.cpu ?? 0, colors.ring ?? Tint.cpu)
        case .memory: return (r.memory ?? 0, colors.ring ?? Tint.memory)
        case .disk: return (r.disk ?? 0, colors.ring ?? Tint.disk)
        }
    }

    private static func dotsLevel(_ dots: Dots, _ r: Readings, colors: Colors) -> (Double, NSColor)? {
        switch dots {
        case .none: return nil
        case .volume: return (r.muted ? 0 : Double(r.volume ?? 0), colors.dots ?? colors.neutral)
        case .cpu: return (r.cpu ?? 0, colors.dots ?? Tint.cpu)
        case .memory: return (r.memory ?? 0, colors.dots ?? Tint.memory)
        case .battery:
            guard let info = r.battery else { return nil }
            return (Double(info.percent) / 100, battery(info, own: colors.dots, colors: colors))
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
                case .connected: return ("wifi", nil)
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
    func image(size: CGFloat, foreground: NSColor, plate: Plate = .none, inset: CGFloat = 0) -> NSImage {
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
