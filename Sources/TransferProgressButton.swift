import AppKit

/// The terminal's Downloads button. Idle it is an arrow in a circle; while
/// something transfers the circle fills with the overall progress and the
/// arrow bobs down (a short spinning arc when the size is not known yet);
/// when the last one finishes it shows a tick for a moment.
final class TransferProgressButton: NSButton {
    enum Phase: Equatable {
        case idle
        case running(Double?)   // 0…1, nil when unknown
        case done
    }

    private(set) var phase = Phase.idle
    /// How long the tick stays after the last transfer ends.
    var doneDuration: TimeInterval = 1.6

    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let glyph = CALayer()
    private var glyphName = ""
    private var doneGeneration = 0

    private static let idleColour = NSColor(white: 1, alpha: 0.78)
    private static let runningColour = NSColor.systemBlue
    private static let doneColour = NSColor.systemGreen
    private static let diameter: CGFloat = 15
    private static let lineWidth: CGFloat = 1.6

    init(target: AnyObject?, action: Selector?, label: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
        self.target = target
        self.action = action
        title = ""
        image = nil
        isBordered = false
        toolTip = label
        setAccessibilityLabel(label)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        for shape in [track, arc] {
            shape.fillColor = nil
            shape.lineWidth = Self.lineWidth
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        arc.strokeEnd = 0
        glyph.contentsGravity = .resizeAspect
        layer?.addSublayer(glyph)
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {}

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let box = NSRect(x: (bounds.width - Self.diameter) / 2, y: (bounds.height - Self.diameter) / 2,
                         width: Self.diameter, height: Self.diameter)
        for shape in [track, arc] {
            shape.frame = bounds
            // From 12 o'clock, clockwise (y points up here).
            let path = CGMutablePath()
            path.addArc(center: CGPoint(x: box.midX, y: box.midY), radius: Self.diameter / 2,
                        startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
            shape.path = path
        }
        // Rotation (the spinner) turns about the circle's centre.
        arc.anchorPoint = CGPoint(x: box.midX / max(bounds.width, 1), y: box.midY / max(bounds.height, 1))
        arc.position = CGPoint(x: box.midX, y: box.midY)
        glyph.frame = box.insetBy(dx: 3.6, dy: 3.6)
        let scale = window?.backingScaleFactor ?? 2
        glyph.contentsScale = scale
        track.contentsScale = scale
        arc.contentsScale = scale
        CATransaction.commit()
    }

    /// Follows TransferCenter: what runs, how far, and when it is all done.
    func update(running: Bool, fraction: Double?) {
        if running {
            set(.running(fraction))
        } else if case .running = phase {
            set(.done)
            doneGeneration += 1
            let generation = doneGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + doneDuration) { [weak self] in
                guard let self, self.doneGeneration == generation, self.phase == .done else { return }
                self.set(.idle)
            }
        }
    }

    private func set(_ next: Phase) {
        guard next != phase else { return }
        phase = next
        apply()
    }

    private func apply() {
        let reduce = MainWindowMotion.reduceMotion
        switch phase {
        case .idle:
            track.strokeColor = Self.idleColour.cgColor
            arc.strokeEnd = 0
            setGlyph("arrow.down", Self.idleColour)
            stopMotion()
            setAccessibilityValue(nil)
        case .running(let fraction):
            track.strokeColor = Self.runningColour.withAlphaComponent(0.25).cgColor
            arc.strokeColor = Self.runningColour.cgColor
            setGlyph("arrow.down", Self.runningColour)
            if let fraction {
                arc.removeAnimation(forKey: "spin")
                arc.transform = CATransform3DIdentity
                // Never empty while running: a sliver shows it has started.
                arc.strokeEnd = CGFloat(max(0.04, min(1, fraction)))
                setAccessibilityValue("\(Int((fraction * 100).rounded())) %")
            } else {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                arc.strokeEnd = 0.28
                CATransaction.commit()
                if !reduce, arc.animation(forKey: "spin") == nil {
                    let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                    spin.fromValue = 0
                    spin.toValue = -2 * Double.pi
                    spin.duration = 0.9
                    spin.repeatCount = .infinity
                    arc.add(spin, forKey: "spin")
                }
                setAccessibilityValue(nil)
            }
            if !reduce, glyph.animation(forKey: "bob") == nil {
                let bob = CAKeyframeAnimation(keyPath: "transform.translation.y")
                bob.values = [1.2, -1.4, 1.2]
                bob.keyTimes = [0, 0.5, 1]
                bob.duration = 1.1
                bob.repeatCount = .infinity
                bob.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
                glyph.add(bob, forKey: "bob")
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [1, 0.55, 1]
                fade.duration = 1.1
                fade.repeatCount = .infinity
                glyph.add(fade, forKey: "fade")
            }
        case .done:
            stopMotion()
            track.strokeColor = Self.doneColour.withAlphaComponent(0.3).cgColor
            arc.strokeColor = Self.doneColour.cgColor
            arc.strokeEnd = 1
            setGlyph("checkmark", Self.doneColour)
            if !reduce {
                let pop = CAKeyframeAnimation(keyPath: "transform.scale")
                pop.values = [0.6, 1.15, 1]
                pop.duration = 0.35
                glyph.add(pop, forKey: "pop")
            }
            setAccessibilityValue(L("Done"))
        }
    }

    private func stopMotion() {
        arc.removeAnimation(forKey: "spin")
        arc.transform = CATransform3DIdentity
        glyph.removeAnimation(forKey: "bob")
        glyph.removeAnimation(forKey: "fade")
    }

    private func setGlyph(_ symbol: String, _ colour: NSColor) {
        let key = "\(symbol) \(colour)"
        guard key != glyphName else { return }
        glyphName = key
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [colour]))
        glyph.contents = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    /// Test hook: the phase and how much of the circle is filled.
    var debugState: String {
        let motion = [arc.animation(forKey: "spin") != nil ? "spin" : nil,
                      glyph.animation(forKey: "bob") != nil ? "bob" : nil].compactMap { $0 }
        return "\(phase) fill=\(String(format: "%.2f", arc.strokeEnd)) motion=\(motion.joined(separator: "+"))"
    }
}

extension TransferCenter {
    /// Whether anything is transferring, and how far all of it is (nil
    /// while a size is still unknown, uploads included).
    var progress: (running: Bool, fraction: Double?) {
        let running = items.filter { $0.state == .running }
        guard !running.isEmpty else { return (false, nil) }
        var total: Int64 = 0, done: Int64 = 0
        for item in running {
            guard !item.isUpload, let size = item.total, size > 0 else { return (true, nil) }
            total += size
            done += min(item.transferred, size)
        }
        return (true, Double(done) / Double(total))
    }
}
