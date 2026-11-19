import AppKit

/// `--snip-selftest`: drives the real overlay view with synthetic mouse
/// events (no screen capture, no permissions) and checks that a finished
/// selection can still be resized from its edges and corners before it is
/// confirmed, while a drag inside the frame keeps drawing annotations.
enum SnipSelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print((ok ? "PASS  " : "FAIL  ") + name + (ok || detail.isEmpty ? "" : "  — \(detail)"))
    }

    private static func blankImage(_ size: CGSize) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }

    /// One press-drag-release at view points (top-left origin).
    private static func drag(_ view: NSView, _ points: [CGPoint]) {
        guard let window = view.window, let first = points.first, let last = points.last else { return }
        let height = view.bounds.height
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: p.x, y: height - p.y),
                               modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let e = event(.leftMouseDown, first) { view.mouseDown(with: e) }
        for p in points.dropFirst() { if let e = event(.leftMouseDragged, p) { view.mouseDragged(with: e) } }
        if let e = event(.leftMouseUp, last) { view.mouseUp(with: e) }
    }

    /// Front-to-back order of our own on-screen windows, by window number.
    private static func onScreenOrder() -> [Int] {
        let pid = Int(getpid())
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }
                   .compactMap { $0[kCGWindowNumber as String] as? Int }
    }

    /// After the toolbar is up, pressing on the overlay (which brings the
    /// overlay window to the front) must not cover the toolbar.
    private static func checkToolbarStaysOnTop() {
        func panel(_ level: NSWindow.Level, _ frame: NSRect) -> NSPanel {
            let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = level
            p.backgroundColor = NSColor.black.withAlphaComponent(0.01)
            return p
        }
        func toolbarAbove(toolbarLevel: NSWindow.Level) -> Bool? {
            let overlay = panel(OverlayController.overlayLevel, NSRect(x: 100, y: 100, width: 400, height: 300))
            let toolbar = panel(toolbarLevel, NSRect(x: 200, y: 150, width: 200, height: 40))
            overlay.orderFrontRegardless()
            toolbar.orderFrontRegardless()      // toolbar shown after the selection
            overlay.orderFrontRegardless()      // the press on the overlay to draw a box
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let order = onScreenOrder()
            defer { overlay.orderOut(nil); toolbar.orderOut(nil) }
            guard let t = order.firstIndex(of: toolbar.windowNumber),
                  let o = order.firstIndex(of: overlay.windowNumber) else { return nil }
            return t < o
        }
        guard let fixed = toolbarAbove(toolbarLevel: OverlayController.toolbarLevel) else {
            print("SKIP  toolbar order: no window server in this session")
            return
        }
        check("the toolbar stays above the overlay after a press on the overlay", fixed)
        let sameLevel = toolbarAbove(toolbarLevel: OverlayController.overlayLevel)
        print("INFO  with the old same-level toolbar it would be " + (sameLevel == false ? "covered (the reported bug)" : "visible"))
    }

    /// The chosen tool is marked in the toolbar and shown by the pointer.
    private static func checkToolFeedback(capture: DisplayCapture) {
        let sel = CGRect(x: 100, y: 100, width: 200, height: 100)
        check("inside the frame with no tool chosen the pointer is a hand (a drag moves the frame)",
              SelectionEdit.pointer(at: CGPoint(x: 200, y: 150), selection: sel, tool: nil) == .move)
        check("inside the frame the pointer shows the chosen tool",
              SelectionEdit.pointer(at: CGPoint(x: 200, y: 150), selection: sel, tool: .ellipse) == .tool(.ellipse))
        check("on the frame the pointer resizes, outside it is a plain arrow",
              SelectionEdit.pointer(at: CGPoint(x: 300, y: 150), selection: sel, tool: .ellipse) == .resize(.right)
              && SelectionEdit.pointer(at: CGPoint(x: 360, y: 260), selection: sel, tool: .ellipse) == .arrow)
        check("the text tool uses the text cursor, shape tools a crosshair with their icon",
              SnipCursor.cursor(for: .text) === NSCursor.iBeam
              && SnipCursor.cursor(for: .rectangle) !== NSCursor.iBeam
              && SnipCursor.cursor(for: .rectangle).image.size == NSSize(width: 32, height: 32)
              && SnipCursor.cursor(for: .rectangle) !== SnipCursor.cursor(for: .pen))

        let controller = OverlayController(captures: [capture])
        let session = SnipSession(captures: [capture])
        let saved = [SnipSession.frameShapeKey, SnipSession.mosaicSizeKey].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) } }
        session.frameShape = .rectangle
        session.mosaicSize = Mosaic.defaultBrushSize
        let toolbar = ToolbarPanel(session: session, controller: controller)
        let renderDir = ProcessInfo.processInfo.environment["OMNIHUB_RENDER_DIR"]
        func render(_ name: String) {   // OMNIHUB_RENDER_DIR=<dir>: save the toolbar and its options as PNGs
            guard let dir = renderDir else { return }
            for (panel, suffix) in [(toolbar as NSPanel, ""), (toolbar.debugOptionsPanel, "-options")] {
                guard let view = panel.contentView,
                      suffix.isEmpty || (panel as? ToolOptionsPanel)?.hasContent == true else { continue }
                view.appearance = NSAppearance(named: .darkAqua)
                if panel === toolbar { panel.setContentSize(view.fittingSize) }   // the options size themselves
                view.layoutSubtreeIfNeeded()
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + suffix + ".png"))
            }
        }

        check("the toolbar has one frame button for both shapes, then arrow, pen, text and mosaic",
              toolbar.debugToolNames == ["Frame", "Arrow", "Pen", "Text", "Mosaic"], "\(toolbar.debugToolNames)")
        check("with no tool chosen no options are offered",
              toolbar.debugChoices == "tools= shapes=hidden colors=hidden sizes=hidden" && session.tool == nil,
              toolbar.debugChoices)
        render("toolbar")

        toolbar.debugChoose(tool: .text)
        toolbar.debugChoose(color: 2)
        check("choosing Text offers the colours only, and blue moves the colour mark",
              toolbar.debugChoices == "tools=Text shapes=hidden colors=2 sizes=hidden" && session.tool == .text,
              toolbar.debugChoices)
        toolbar.debugChoose(tool: .text)
        check("choosing the chosen tool again goes back to moving the frame, with no options",
              toolbar.debugChoices == "tools= shapes=hidden colors=hidden sizes=hidden" && session.tool == nil,
              toolbar.debugChoices)

        toolbar.debugChoose(tool: .rectangle)
        check("choosing Frame draws rectangles and offers both shapes and the colours",
              toolbar.debugChoices == "tools=Frame shapes=Rectangle colors=2 sizes=hidden" && session.tool == .rectangle,
              toolbar.debugChoices)
        toolbar.debugChoose(shape: .ellipse)
        check("picking the circle switches the frame to ellipses",
              toolbar.debugChoices == "tools=Frame shapes=Ellipse colors=2 sizes=hidden" && session.tool == .ellipse,
              toolbar.debugChoices)
        render("toolbar-frame")
        toolbar.debugChoose(tool: .rectangle)
        let off = session.tool == nil
        toolbar.debugChoose(tool: .rectangle)
        check("Frame again turns it off; chosen once more it keeps the last shape (also for the next screenshot)",
              off && session.tool == .ellipse && SnipSession(captures: []).frameShape == .ellipse,
              "\(String(describing: session.tool))")

        toolbar.debugChoose(tool: .mosaic)
        check("Mosaic offers brush sizes, no colours",
              toolbar.debugChoices == "tools=Mosaic shapes=hidden colors=hidden sizes=1" && session.tool == .mosaic,
              toolbar.debugChoices)
        toolbar.debugChoose(size: 2)
        check("picking the large brush widens the mosaic brush and is kept",
              toolbar.debugChoices.hasSuffix("sizes=2") && session.mosaicSize == Mosaic.brushSizes[2]
              && SnipSession(captures: []).mosaicSize == Mosaic.brushSizes[2], toolbar.debugChoices)
        toolbar.debugChoose(tool: .rectangle)
        let frameStrip = toolbar.debugOptionsPanel.frame.height
        toolbar.debugChoose(tool: .text)
        let colorStrip = toolbar.debugOptionsPanel.frame.height
        toolbar.debugChoose(tool: .mosaic)
        check("each options strip fits its buttons whatever was shown before (frame 34, colours 28, sizes 34 pt)",
              frameStrip == 34 && colorStrip == 28 && toolbar.debugOptionsPanel.frame.height == 34,
              "frame \(frameStrip) colours \(colorStrip) sizes \(toolbar.debugOptionsPanel.frame.height)")
        check("the mosaic pointer is a ring as wide as the brush",
              SnipCursor.cursor(for: .mosaic, brushSize: 44).image.size.width == 48
              && SnipCursor.cursor(for: .mosaic, brushSize: 16).image.size.width == 20)
        render("toolbar-mosaic")

        checkOptionsPlacement(toolbar, session)

        if let dir = renderDir {   // the pointers too
            for tool in AnnotationTool.allCases {
                let image = SnipCursor.cursor(for: tool).image
                try? image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
                    .representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("cursor-\(tool.title).png"))
            }
        }
        toolbar.close()
    }

    /// The options open under the toolbar at the chosen tool, or over the
    /// toolbar when it sits at the bottom of the screen.
    private static func checkOptionsPlacement(_ toolbar: ToolbarPanel, _ session: SnipSession) {
        guard NSScreen.main != nil else { print("SKIP  options placement: no screen in this session"); return }
        let screen = CGDisplayBounds(CGMainDisplayID())
        let options = toolbar.debugOptionsPanel
        defer { toolbar.orderOut(nil) }

        session.selection = CGRect(x: screen.minX + 200, y: screen.minY + 200, width: 500, height: 200)
        toolbar.show(near: session.selection!)
        toolbar.debugChoose(tool: .pen)
        let tool = toolbar.debugChosenToolFrame ?? .zero
        check("the options open under the toolbar, starting at the chosen tool",
              options.isVisible && options.frame.maxY <= toolbar.frame.minY
              && abs(options.frame.minX - (tool.minX - 8)) < 1,
              "options \(options.frame) toolbar \(toolbar.frame) tool \(tool)")

        session.selection = CGRect(x: screen.minX + 200, y: screen.maxY - 40, width: 500, height: 30)
        toolbar.show(near: session.selection!)
        check("with no room below, they open over the toolbar",
              options.isVisible && options.frame.minY >= toolbar.frame.maxY,
              "options \(options.frame) toolbar \(toolbar.frame)")

        toolbar.debugChoose(tool: .pen)
        check("with no tool chosen the options close", !options.isVisible)
    }

    /// Columns alternating black and white, so a pixelated area turns grey.
    private static func stripedImage(_ size: CGSize) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setFillColor(gray: 1, alpha: 1)
        for x in stride(from: 1, to: Int(size.width), by: 2) {
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: Int(size.height)))
        }
        return ctx.makeImage()
    }

    /// Red channel of every pixel, rows from the top.
    private static func redChannel(_ image: CGImage) -> [[UInt8]] {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (0..<h).map { y in (0..<w).map { x in bytes[(y * w + x) * 4] } }
    }

    /// The mosaic is a brush: a stroke turns the screen under it into even
    /// grey blocks in the copied image and leaves the rest untouched.
    private static func checkMosaic() {
        let size = CGSize(width: 400, height: 300)
        guard let image = stripedImage(size) else { check("mosaic test image", false); return }
        let capture = DisplayCapture(displayID: 0, bounds: CGRect(origin: .zero, size: size), image: image)
        let session = SnipSession(captures: [capture])
        let saved = UserDefaults.standard.object(forKey: SnipSession.mosaicSizeKey)
        defer { UserDefaults.standard.set(saved, forKey: SnipSession.mosaicSizeKey) }
        session.mosaicSize = 28
        let view = OverlayView(capture: capture, session: session)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = view
        session.stage = .annotating
        session.selection = CGRect(x: 100, y: 100, width: 200, height: 100)
        session.tool = .mosaic

        // A horizontal stroke along y = 150 from x = 120 to 220, 28 pt wide.
        drag(view, [CGPoint(x: 120, y: 150), CGPoint(x: 170, y: 150), CGPoint(x: 220, y: 150)])
        var stroke = false
        if case .mosaic(let points, let pixels, _)? = session.annotations.first?.shape {
            stroke = points.count == 3 && pixels != nil && session.annotations.first?.lineWidth == 28
        }
        check("a mosaic drag adds one brush stroke of the chosen width", session.annotations.count == 1 && stroke,
              "annotations \(session.annotations.count)")

        guard let rendered = session.renderFinalImage()?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { check("mosaic render", false); return }
        let red = redChannel(rendered)
        guard red.count == 100, red[0].count == 200 else { check("mosaic render size", false, "\(red.count)"); return }
        // Selection-local (50,50) is screen (150,150); its block spans screen 144–152, local 44–52.
        let block = red[50][50]
        check("under the stroke the stripes become even grey blocks",
              (60...195).contains(block) && red[44...51].allSatisfy { $0[44...51].allSatisfy { $0 == block } },
              "block \(block) row \(Array(red[50][44...51]))")
        check("away from the stroke the screenshot is untouched",
              Set(red[10][50...53]) == [0, 255] && Set(red[50][150...153]) == [0, 255],
              "\(Array(red[10][50...53])) \(Array(red[50][150...153]))")

        drag(view, [CGPoint(x: 260, y: 120)])
        check("a click paints one dab", session.annotations.count == 2,
              "annotations \(session.annotations.count)")
        session.undo(); session.undo()
        check("undo removes the strokes", session.annotations.isEmpty)

        // Upright: the top half of the screen black, the bottom half white.
        let w = 400, h = 300
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h / 2 * 4) where i % 4 != 3 { bytes[i] = 0 }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let halves = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                     space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        else { check("mosaic orientation image", false); return }
        let split = SnipSession(captures: [DisplayCapture(displayID: 0, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                                                          image: halves)])
        split.selection = CGRect(x: 100, y: 100, width: 200, height: 100)
        // A vertical stroke at x = 140 across the middle (y 130–170).
        split.annotations = [Annotation(shape: .mosaic([CGPoint(x: 140, y: 130), CGPoint(x: 140, y: 170)],
                                                       pixels: split.mosaicPixels, area: split.screensBounds),
                                        color: .systemRed, lineWidth: 28)]
        let flipped = split.renderFinalImage()?.cgImage(forProposedRect: nil, context: nil, hints: nil).map(redChannel)
        let top = flipped?[33][40] ?? 128, bottom = flipped?[65][40] ?? 128
        check("the mosaic keeps the screen the right way up (dark above, light below)", top < 60 && bottom > 195,
              "top \(top) bottom \(bottom)")
    }

    /// Esc leaves the screenshot in one press, from every stage.
    private static func checkEscapeLeaves(capture: DisplayCapture) {
        func controller(_ setup: (SnipSession) -> Void) -> OverlayController {
            let c = OverlayController(captures: [capture])
            setup(c.debugSession)
            return c
        }
        let selecting = controller { $0.stage = .selecting }
        selecting.handleEscape()
        let selected = controller { $0.stage = .annotating; $0.selection = CGRect(x: 100, y: 100, width: 200, height: 100) }
        selected.handleEscape()
        let annotated = controller {
            $0.stage = .annotating; $0.selection = CGRect(x: 100, y: 100, width: 200, height: 100)
            $0.annotations = [Annotation(shape: .rectangle(CGRect(x: 120, y: 120, width: 20, height: 20)), color: .systemRed, lineWidth: 3)]
        }
        annotated.handleEscape()
        check("one Esc leaves the screenshot while selecting, after selecting and after annotating",
              selecting.isClosed && selected.isClosed && annotated.isClosed)

        // Esc while typing a text annotation.
        let typing = controller { $0.stage = .annotating; $0.selection = CGRect(x: 100, y: 100, width: 200, height: 100); $0.tool = .text }
        let view = OverlayView(capture: capture, session: typing.debugSession)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: capture.bounds.size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        drag(view, [CGPoint(x: 150, y: 130)])
        let field = view.subviews.compactMap { $0 as? NSTextField }.first
        if let field { _ = view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))) }
        check("Esc while typing text leaves the screenshot too", field != nil && typing.isClosed)
    }

    static func run() {
        let size = CGSize(width: 400, height: 300)
        guard let image = blankImage(size) else { print("FAIL  could not make a test image"); exit(1) }
        let capture = DisplayCapture(displayID: 0, bounds: CGRect(origin: .zero, size: size), image: image)
        let session = SnipSession(captures: [capture])
        let view = OverlayView(capture: capture, session: session)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = view

        let start = CGRect(x: 100, y: 100, width: 200, height: 100)
        func reset() {
            session.stage = .annotating
            session.selection = start
            session.annotations = []
            session.tool = nil
        }

        // 1. Pick a region by dragging, as a person would.
        session.stage = .selecting
        drag(view, [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 150), CGPoint(x: 300, y: 200)])
        check("a drag selects a region and waits for confirmation, with no tool chosen",
              session.stage == .annotating && session.selection == start && session.tool == nil,
              "\(String(describing: session.selection)) tool \(String(describing: session.tool))")

        // 2. Right after selecting, a drag inside the frame moves it.
        drag(view, [CGPoint(x: 150, y: 130), CGPoint(x: 180, y: 150), CGPoint(x: 200, y: 170)])
        check("after selecting, a drag inside the frame moves it and draws nothing",
              session.selection == start.offsetBy(dx: 50, dy: 40) && session.annotations.isEmpty,
              "\(String(describing: session.selection)), annotations \(session.annotations.count)")

        reset()
        drag(view, [CGPoint(x: 150, y: 130), CGPoint(x: -400, y: -400)])
        check("moving stops at the edge of the screen",
              session.selection == CGRect(x: 0, y: 0, width: 200, height: 100), "\(String(describing: session.selection))")

        reset()
        drag(view, [CGPoint(x: 150, y: 130), CGPoint(x: 900, y: 900)])
        check("… on every side", session.selection == CGRect(x: 200, y: 200, width: 200, height: 100),
              "\(String(describing: session.selection))")

        reset()
        drag(view, [CGPoint(x: 300, y: 150), CGPoint(x: 320, y: 150), CGPoint(x: 340, y: 150)])
        check("dragging the right edge widens the frame",
              session.selection == CGRect(x: 100, y: 100, width: 240, height: 100) && session.annotations.isEmpty,
              "\(String(describing: session.selection)), annotations \(session.annotations.count)")

        reset()
        drag(view, [CGPoint(x: 150, y: 100), CGPoint(x: 150, y: 130)])
        check("dragging the top edge down shrinks the frame",
              session.selection == CGRect(x: 100, y: 130, width: 200, height: 70), "\(String(describing: session.selection))")

        reset()
        drag(view, [CGPoint(x: 302, y: 203), CGPoint(x: 330, y: 240)])
        check("dragging the bottom-right corner (within the grab margin) resizes both sides",
              session.selection == CGRect(x: 100, y: 100, width: 230, height: 140), "\(String(describing: session.selection))")

        reset()
        drag(view, [CGPoint(x: 100, y: 150), CGPoint(x: 360, y: 150)])
        check("dragging the left edge past the right edge flips instead of inverting",
              session.selection == CGRect(x: 300, y: 100, width: 60, height: 100), "\(String(describing: session.selection))")

        reset()
        drag(view, [CGPoint(x: 300, y: 150), CGPoint(x: 101, y: 150)])
        check("a resize that collapses the frame is undone",
              session.selection == start, "\(String(describing: session.selection))")

        reset()
        session.tool = .rectangle
        drag(view, [CGPoint(x: 150, y: 130), CGPoint(x: 200, y: 170)])
        check("with a tool chosen, a drag inside the frame draws an annotation and leaves the frame alone",
              session.annotations.count == 1 && session.selection == start,
              "\(String(describing: session.selection)), annotations \(session.annotations.count)")

        reset()
        session.annotations = [Annotation(shape: .rectangle(CGRect(x: 120, y: 120, width: 20, height: 20)),
                                          color: .systemRed, lineWidth: 3)]
        drag(view, [CGPoint(x: 300, y: 200), CGPoint(x: 350, y: 250)])
        check("the frame can still be resized after annotating, keeping the annotations",
              session.selection == CGRect(x: 100, y: 100, width: 250, height: 150) && session.annotations.count == 1,
              "\(String(describing: session.selection)), annotations \(session.annotations.count)")

        check("a press deep inside the frame grabs no edge",
              SelectionEdit.handle(at: CGPoint(x: 200, y: 150), in: start) == nil)
        check("a press just outside a corner grabs that corner",
              SelectionEdit.handle(at: CGPoint(x: 96, y: 96), in: start) == [.left, .top])

        checkToolbarStaysOnTop()
        checkToolFeedback(capture: capture)
        checkEscapeLeaves(capture: capture)
        checkMosaic()

        print(failures == 0 ? "snip selftest: all passed" : "snip selftest: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
