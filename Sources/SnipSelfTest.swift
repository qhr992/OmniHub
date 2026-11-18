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
        let toolbar = ToolbarPanel(session: session, controller: controller)
        check("the toolbar starts with no tool chosen, only the starting colour",
              toolbar.debugChoices == "tools= colors=0" && session.tool == nil, toolbar.debugChoices)
        toolbar.debugChoose(tool: .text)
        toolbar.debugChoose(color: 2)
        check("choosing Text and blue moves the marks (one tool, one colour)",
              toolbar.debugChoices == "tools=Text colors=2" && session.tool == .text, toolbar.debugChoices)
        toolbar.debugChoose(tool: .text)
        check("choosing the chosen tool again goes back to moving the frame",
              toolbar.debugChoices == "tools= colors=2" && session.tool == nil, toolbar.debugChoices)
        // OMNIHUB_RENDER_DIR=<dir>: also save the toolbar and the pointers as PNGs to look at.
        if let dir = ProcessInfo.processInfo.environment["OMNIHUB_RENDER_DIR"], let view = toolbar.contentView {
            func save(_ rep: NSBitmapImageRep?, _ name: String) {
                try? rep?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
            view.appearance = NSAppearance(named: .darkAqua)
            view.layoutSubtreeIfNeeded()
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            if let rep { view.cacheDisplay(in: view.bounds, to: rep) }
            save(rep, "toolbar.png")
            for tool in AnnotationTool.allCases {
                let image = SnipCursor.cursor(for: tool).image
                save(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)), "cursor-\(tool.title).png")
            }
        }
        toolbar.close()
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

        print(failures == 0 ? "snip selftest: all passed" : "snip selftest: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
