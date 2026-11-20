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
    /// "jump" (one leap bigger than the viewport — unmatched on purpose),
    /// "sticky" (slow steps with rests; a bar appears at the top once the
    /// page has scrolled, as many web pages do), "keys" (the ↓ key: three
    /// presses, then held until the end — real scroll events, no pointer).
    /// Only "keys" moves the page through events; the others set the offset.
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
        // "sticky": a dark bar over the top of the viewport, shown after 200pt.
        // A sibling of the scroll view (a scroll view re-tiles its own subviews).
        let container = NSView(frame: NSRect(origin: .zero, size: viewport))
        container.addSubview(scroll)
        let bar = NSView(frame: NSRect(x: 0, y: viewport.height - 44, width: viewport.width, height: 44))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(calibratedWhite: 0.15, alpha: 1).cgColor
        bar.isHidden = true
        container.addSubview(bar)
        panel.contentView = container
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
        if mode == "keys" {
            driveWithKeys(capture, document: document, maxOffset: documentHeight - viewport.height)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let driver = Timer(timeInterval: 0.016, repeats: true) { timer in
                step += 1
                switch mode {
                case "flick":
                    // 12 frames of fast motion (~70pt/frame), then a pause.
                    if step % 40 < 12 { offset += 70 }
                case "jump":
                    if step == 30 { offset += 900 } else if step > 90 { offset += 30 }
                case "sticky":
                    // 6pt steps for half a second, then rest for half a second.
                    if step % 60 < 30 { offset += 6 }
                    bar.isHidden = offset <= 200
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

    /// Presses ↓ three times, then holds it until the page stops moving.
    private static func driveWithKeys(_ capture: ScrollCaptureController, document: NSView, maxOffset: CGFloat) {
        var presses = 0
        func pressAgain() {
            guard let keys = capture.keyScroller else { return }
            if presses < 3 {
                presses += 1
                keys.press(1)
                keys.release(1)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { pressAgain() }
                return
            }
            keys.press(1)                        // held from here on
            var last: CGFloat = -1
            let watch = Timer(timeInterval: 0.5, repeats: true) { timer in
                let offset = document.visibleRect.minY
                guard offset == last else { last = offset; return }
                timer.invalidate()                   // reached the bottom (or stuck)
                keys.release(1)
                lines.append("keys: \(presses) presses + hold, \(keys.stepsSent) scroll events, stopped at \(Int(offset)) of \(Int(maxOffset)) pt")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { controller?.finish() }
            }
            RunLoop.main.add(watch, forMode: .common)
            timer = watch
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { pressAgain() }
    }

    /// `omnihub://debug/scroll-keys-region?x=&y=&w=&h=` (CG global points):
    /// a scrolling screenshot of any region (a window of another app) driven
    /// only by the down key: three presses, then held until nothing new arrives.
    /// Writes scroll-selftest-region.txt and snapshots/scroll-region.png.
    static func runKeys(region: CGRect) {
        guard controller == nil else { return }
        let capture = ScrollCaptureController(region: region)
        capture.onResult = { image, scale, gaps in
            controller = nil
            var out = ["mode = region"] + lines
            lines = []
            if let image {
                out.append("stitched = \(image.width)x\(image.height) px = \(Int(CGFloat(image.height) / scale)) pt (scale \(scale))")
                out.append("region = \(Int(region.height)) pt tall")
                out.append("gaps = \(gaps)")
                let dir = Store.directory.appendingPathComponent("snapshots", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent("scroll-region.png"))
                }
            } else {
                out.append("no image")
            }
            try? (out.joined(separator: "\n") + "\n").write(to: Store.url("scroll-selftest-region.txt"),
                                                             atomically: true, encoding: .utf8)
        }
        controller = capture
        capture.start()
        var presses = 0
        func step() {
            guard let keys = capture.keyScroller else { return }
            if presses < 3 {
                presses += 1
                keys.press(1)
                keys.release(1)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { step() }
                return
            }
            keys.press(1)
            var last = -1
            var still = 0
            let watch = Timer(timeInterval: 0.5, repeats: true) { timer in
                let height = capture.debugStitchedHeight
                still = height == last ? still + 1 : 0
                last = height
                guard still >= 3 else { return }        // 1.5 s without new rows: the end
                timer.invalidate()
                keys.release(1)
                lines.append("keys: \(presses) presses + hold, \(keys.stepsSent) scroll events")
                capture.finish()
            }
            RunLoop.main.add(watch, forMode: .common)
            self.timer = watch
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { step() }
    }

    /// Extra lines for the report (the key mode notes how far it got).
    private static var lines: [String] = []

    private static func report(mode: String, image: CGImage?, scale: CGFloat, gaps: Int,
                               expected: CGFloat, viewport: NSSize) {
        window?.orderOut(nil)
        window = nil
        controller = nil
        var lines = ["mode = \(mode)"] + Self.lines
        Self.lines = []
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
