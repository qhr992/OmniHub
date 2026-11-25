import AppKit

/// Menu-bar icon: a tiny winged buddy. The busier the machine
/// (memory or CPU, chosen in settings), the faster she flaps. Optionally the
/// network speed sits to its right: upload above, download below.
final class StatusRunner {
    /// Settings › Appearance / the menu: the network speed beside the icon.
    static let netSpeedKey = "status.netSpeed"
    /// The buddy's speed: 0 follows memory, 1 follows CPU, 2 stays still.
    static let speedKey = "status.buddySpeed"
    static var showsNetSpeed: Bool { Prefs.bool(netSpeedKey, false) }

    /// The speed choice, from the older "animated" / "metric" pair when unset.
    static var speed: Int {
        if UserDefaults.standard.object(forKey: speedKey) != nil { return Prefs.int(speedKey, 0) }
        return Prefs.bool("status.animated", true) ? Prefs.int("status.metric", 0) : 2
    }

    private weak var button: NSStatusBarButton?
    private let frames = StatusRunner.makeFrames()
    private var index = 0
    private var timer: Timer?
    private var interval: TimeInterval = 0.2
    private(set) var load: Double = 0

    init(button: NSStatusBarButton) {
        self.button = button
        button.image = frames[0]
        SystemStats.shared.retain()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(statsChanged), name: .activityChanged, object: nil)
        center.addObserver(self, selector: #selector(statsChanged), name: .settingsChanged, object: nil)
        center.addObserver(self, selector: #selector(statsChanged), name: .statusIconChanged, object: nil)
        reschedule()
    }

    /// Settings › Appearance: the status icon stands in for the runner.
    private var showsStatusIcon: Bool { StatusIcon.inMenuBar }

    /// 0 = memory, 1 = CPU.
    private var metric: Int { Self.speed == 1 ? 1 : 0 }
    private var animated: Bool { Self.speed != 2 }
    /// The rates last read, as shown ("12 KB/s").
    private var rates = (up: "", down: "")

    var debugState: String {
        "metric=\(metric == 1 ? "cpu" : "memory") load=\(String(format: "%.0f%%", load * 100)) "
            + "frameInterval=\(String(format: "%.3f", interval))s frames=\(frames.count) animated=\(animated) "
            + "netSpeed=\(Self.showsNetSpeed) up=\(rates.up) down=\(rates.down) width=\(button?.image?.size.width ?? 0)"
    }

    @objc private func statsChanged() {
        let stats = SystemStats.shared.snapshot
        rates = (SystemStats.rate(stats.netOut), SystemStats.rate(stats.netIn))
        if showsStatusIcon {
            if timer != nil || interval != 0 {
                interval = 0
                reschedule()
            }
            button?.image = withSpeed(StatusIcon.shared.image(size: 22, foreground: .labelColor))
            button?.toolTip = StatusIcon.shared.summary
            return
        }
        if button?.image?.isTemplate == false {
            // Back from the status icon.
            interval = -1
        }
        let value: Double
        if metric == 1 {
            value = stats.cpu ?? 0
        } else {
            value = stats.memoryTotal > 0 ? Double(stats.memoryUsed) / Double(stats.memoryTotal) : 0
        }
        load = min(max(value, 0), 1)
        button?.toolTip = "OmniHub · \(metric == 1 ? "CPU" : L("Memory")) \(Int((load * 100).rounded()))%"
        // 0% → a lazy glide (0.22 s per frame), 100% → frantic (0.035 s).
        let next = animated ? 0.22 - (0.22 - 0.035) * load : 0
        if abs(next - interval) > 0.012 || (next == 0) != (interval == 0) {
            interval = next
            reschedule()
        } else if timer == nil {
            button?.image = withSpeed(frames[index])
        }
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard !showsStatusIcon else { return }
        guard animated, interval > 0 else {
            index = 0
            button?.image = withSpeed(frames[0])
            return
        }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.advance() }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func advance() {
        index = (index + 1) % frames.count
        button?.image = withSpeed(frames[index])
    }

    // MARK: Network speed

    private static let speedFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    /// Wide enough for "888.8 MB/s", so the menu bar does not shift as figures change.
    private static let speedWidth: CGFloat = {
        let text = ("888.8 MB/s" as NSString).size(withAttributes: [.font: speedFont]).width
        return ceil(text) + 9
    }()

    /// `icon` with the network speed to its right, when that is on.
    private func withSpeed(_ icon: NSImage) -> NSImage {
        guard Self.showsNetSpeed else { return icon }
        return Self.compose(icon, up: rates.up, down: rates.down)
    }

    /// The icon, a gap, then the two rates in a column of fixed width.
    static func compose(_ icon: NSImage, up: String, down: String) -> NSImage {
        let rates = (up: up, down: down)
        let gap: CGFloat = 4
        let height = max(icon.size.height, 22)
        let size = NSSize(width: icon.size.width + gap + speedWidth, height: height)
        // A template icon stays one: everything in black, tinted by the menu bar.
        let template = icon.isTemplate
        let image = NSImage(size: size, flipped: false) { _ in
            icon.draw(in: NSRect(x: 0, y: (height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
            let colour: NSColor = template ? .black : .labelColor
            let x = icon.size.width + gap
            drawRate("arrow.up", rates.up, at: NSPoint(x: x, y: height / 2 + 0.5), colour: colour)
            drawRate("arrow.down", rates.down, at: NSPoint(x: x, y: 1), colour: colour)
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = "OmniHub ↑\(rates.up) ↓\(rates.down)"
        return image
    }

    /// An arrow and a rate on one line, its bottom-left at `origin`.
    private static func drawRate(_ symbol: String, _ text: String, at origin: NSPoint, colour: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: 7, weight: .heavy)
            .applying(NSImage.SymbolConfiguration(paletteColors: [colour]))
        if let arrow = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            arrow.draw(in: NSRect(x: origin.x, y: origin.y + 1.5, width: arrow.size.width, height: arrow.size.height))
        }
        (text as NSString).draw(at: NSPoint(x: origin.x + 8, y: origin.y - 0.5),
                                withAttributes: [.font: speedFont, .foregroundColor: colour])
    }

    // MARK: Artwork

    static let frameCount = 8
    static let size = NSSize(width: 27, height: 18)

    /// One flap cycle, drawn in code as template images so they follow the
    /// light / dark menu bar.
    static func makeFrames() -> [NSImage] {
        (0..<frameCount).map { frame in
            let phase = Double(frame) / Double(frameCount) * 2 * .pi
            let image = NSImage(size: size, flipped: false) { _ in
                draw(phase: phase)
                return true
            }
            image.isTemplate = true
            image.accessibilityDescription = "OmniHub"
            return image
        }
    }

    private static func draw(phase: Double) {
        let flap = CGFloat(sin(phase))                 // +1 wings up, -1 down
        let bob = -flap * 0.7                          // body sinks as wings rise
        let sway = CGFloat(sin(phase - 0.9))
        NSColor.black.set()
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y + bob) }

        // Tail: a tapering S-curve ending in a little spade.
        let tail = NSBezierPath()
        tail.move(to: p(11.5, 6.2))
        tail.curve(to: p(3.2, 5.6 + sway * 1.6), controlPoint1: p(8.5, 3.6 - sway), controlPoint2: p(6, 7.2 + sway * 1.5))
        tail.lineWidth = 1.7
        tail.lineCapStyle = .round
        tail.stroke()
        let spade = NSBezierPath()
        spade.move(to: p(0.6, 5.8 + sway * 1.9))
        spade.line(to: p(3.6, 7.4 + sway * 1.6))
        spade.line(to: p(3.4, 4.0 + sway * 1.6))
        spade.close()
        spade.fill()

        // Legs trailing behind.
        let legs = NSBezierPath()
        legs.move(to: p(12.2, 5.6)); legs.line(to: p(9.2, 3.0 + sway * 0.8))
        legs.move(to: p(13.4, 5.2)); legs.line(to: p(11.2, 2.2 - sway * 0.8))
        legs.lineWidth = 1.5
        legs.lineCapStyle = .round
        legs.stroke()

        // Torso (a short dress shape) and the arm reaching forward.
        let torso = NSBezierPath()
        torso.move(to: p(16.4, 9.2))
        torso.curve(to: p(11.0, 7.6), controlPoint1: p(14.6, 10.2), controlPoint2: p(12.2, 9.6))
        torso.line(to: p(11.6, 4.6))
        torso.curve(to: p(16.6, 7.0), controlPoint1: p(13.4, 4.4), controlPoint2: p(15.6, 5.4))
        torso.close()
        torso.fill()
        let arm = NSBezierPath()
        arm.move(to: p(15.6, 7.6)); arm.line(to: p(19.4, 5.8 + flap * 0.4))
        arm.lineWidth = 1.4
        arm.lineCapStyle = .round
        arm.stroke()

        // Wing: three scalloped fingers swinging about the shoulder.
        // The down-stroke stops level with the back so it never hides
        // behind the body.
        let lift = 3.6 + flap * 4.4                    // -0.8 … 8
        let wing = NSBezierPath()
        wing.move(to: p(14.4, 9.0))
        wing.curve(to: p(5.6 + lift * 0.25, 9.4 + lift), controlPoint1: p(13.0, 10.2 + lift * 0.6), controlPoint2: p(9.0, 10.4 + lift * 1.05))
        wing.curve(to: p(8.4, 8.8 + lift * 0.45), controlPoint1: p(7.2, 9.0 + lift * 0.7), controlPoint2: p(7.8, 9.4 + lift * 0.55))
        wing.curve(to: p(10.6, 8.2 + lift * 0.2), controlPoint1: p(9.2, 9.0 + lift * 0.4), controlPoint2: p(9.9, 8.8 + lift * 0.3))
        wing.curve(to: p(12.4, 7.6), controlPoint1: p(11.2, 8.4 + lift * 0.15), controlPoint2: p(11.9, 8.0))
        wing.close()
        wing.fill()

        // Twin tail of hair streaming back from the head.
        let hair = NSBezierPath()
        hair.move(to: p(17.0, 12.6))
        hair.curve(to: p(12.4, 11.0 + sway * 0.9), controlPoint1: p(15.4, 13.4), controlPoint2: p(13.8, 11.8 + sway))
        hair.curve(to: p(16.2, 9.6), controlPoint1: p(13.8, 10.6 + sway * 0.5), controlPoint2: p(15.0, 10.4))
        hair.close()
        hair.fill()

        // Head with two horns; the eye is punched out.
        NSBezierPath(ovalIn: NSRect(x: 15.4, y: 7.6 + bob, width: 8.2, height: 8.0)).fill()
        for (a, b, c) in [(p(17.0, 14.4), p(15.8, 17.6), p(18.8, 15.4)),
                          (p(20.4, 15.2), p(22.6, 17.8), p(22.4, 14.2))] {
            let horn = NSBezierPath()
            horn.move(to: a); horn.line(to: b); horn.line(to: c)
            horn.close()
            horn.fill()
        }
        if let context = NSGraphicsContext.current?.cgContext {
            context.setBlendMode(.clear)
            context.fillEllipse(in: CGRect(x: 20.4, y: 10.6 + bob, width: 1.7, height: 2.1))
            context.setBlendMode(.normal)
        }
    }

    /// All frames side by side, enlarged (design review / headless render).
    static func contactSheet(scale: CGFloat = 6) -> NSImage {
        let frames = makeFrames()
        let cell = NSSize(width: size.width * scale, height: size.height * scale)
        return NSImage(size: NSSize(width: cell.width * CGFloat(frames.count), height: cell.height), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            for (index, frame) in frames.enumerated() {
                frame.draw(in: NSRect(x: CGFloat(index) * cell.width, y: 0, width: cell.width, height: cell.height))
            }
            return true
        }
    }
}
