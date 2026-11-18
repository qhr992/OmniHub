import AppKit

/// End-to-end check of the long screenshot on real screen frames.
///
/// Opens a window with a tall, uniquely-patterned document, runs the real
/// `ScrollCaptureController` over it, scrolls the document the way a person
/// would (slow drag, or fast flicks), and compares the stitched height with
/// the document height. Needs Screen Recording permission, nothing else.
enum ScrollSelfTest {
    private static var window: NSWindow?
    private static var controller: ScrollCaptureController?
    private static var timer: Timer?

    /// mode: "slow" (steady 30pt steps), "flick" (bursts with pauses),
    /// "jump" (one leap bigger than the viewport — unmatched on purpose).
    static func run(mode: String) {
        guard window == nil, let screen = NSScreen.screens.first else { return }
        let viewport = NSSize(width: 520, height: 420)
        let documentHeight: CGFloat = 3000

        let frame = NSRect(x: screen.frame.minX + 160, y: screen.frame.maxY - viewport.height - 160,
                           width: viewport.width, height: viewport.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.hasShadow = false
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: viewport))
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = true
        let document = PatternView(frame: NSRect(x: 0, y: 0, width: viewport.width, height: documentHeight))
        scroll.documentView = document
        panel.contentView = scroll
        panel.orderFrontRegardless()
        window = panel
        document.scroll(.zero)

        // The viewport in CG global coordinates (top-left origin).
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let region = CGRect(x: frame.minX, y: primaryHeight - frame.maxY,
                            width: frame.width, height: frame.height)

        let capture = ScrollCaptureController(region: region)
        capture.onResult = { image, scale, gaps in
            report(mode: mode, image: image, scale: scale, gaps: gaps,
                   expected: documentHeight, viewport: viewport)
        }
        controller = capture
        capture.start()

        let maxOffset = documentHeight - viewport.height
        var offset: CGFloat = 0
        var step = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let driver = Timer(timeInterval: 0.016, repeats: true) { timer in
                step += 1
                switch mode {
                case "flick":
                    // 12 frames of fast motion (~70pt/frame), then a pause.
                    if step % 40 < 12 { offset += 70 }
                case "jump":
                    if step == 30 { offset += 900 } else if step > 90 { offset += 30 }
                default:
                    offset += 8
                }
                offset = min(offset, maxOffset)
                document.scroll(NSPoint(x: 0, y: offset))
                if offset >= maxOffset {
                    timer.invalidate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { controller?.finish() }
                }
            }
            RunLoop.main.add(driver, forMode: .common)
            timer = driver
        }
    }

    private static func report(mode: String, image: CGImage?, scale: CGFloat, gaps: Int,
                               expected: CGFloat, viewport: NSSize) {
        window?.orderOut(nil)
        window = nil
        controller = nil
        var lines = ["mode = \(mode)"]
        if let image {
            let points = CGFloat(image.height) / scale
            lines.append("stitched = \(image.width)x\(image.height) px = \(Int(points)) pt (scale \(scale))")
            lines.append("expected = \(Int(expected)) pt")
            lines.append("gaps = \(gaps)")
            let ok = abs(points - expected) <= 2 && gaps == 0
            lines.append(ok ? "RESULT = PASS" : "RESULT = FAIL")
            let dir = Store.directory.appendingPathComponent("snapshots", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("scroll-\(mode).png"))
            }
        } else {
            lines.append("RESULT = FAIL (no image)")
        }
        try? (lines.joined(separator: "\n") + "\n")
            .write(to: Store.url("scroll-selftest-\(mode).txt"), atomically: true, encoding: .utf8)
    }

    /// Every row is distinct: a ruler label every 50pt plus pseudo-random bars.
    private final class PatternView: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.setFill()
            dirtyRect.fill()
            let first = max(0, Int(dirtyRect.minY / 50) - 1)
            let last = Int(dirtyRect.maxY / 50) + 1
            for index in first...last {
                let y = CGFloat(index) * 50
                var seed = UInt32(truncatingIfNeeded: index &* 2_654_435_761)
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let hue = CGFloat(seed % 360) / 360
                NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1).setFill()
                NSRect(x: 16, y: y + 30, width: 60 + CGFloat(seed % 380), height: 12).fill()
                let text = "Row \(index)  ·  y = \(Int(y))" as NSString
                text.draw(at: NSPoint(x: 16, y: y + 6),
                          withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
                                           .foregroundColor: NSColor.black])
            }
        }
    }
}
