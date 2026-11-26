import AppKit
import CoreGraphics

// MARK: - Session

final class SnipSession {
    enum Stage { case selecting, annotating }

    let captures: [DisplayCapture]
    var stage: Stage = .selecting

    /// Selection in the CG global space (points, origin top-left, y down).
    var selection: CGRect?
    /// Fixed drag origin (never overwritten mid-drag).
    var anchor: CGPoint?
    /// Latest cursor position in the CG global space, for the magnifier.
    var cursor: CGPoint?
    var hoveredWindow: WindowCandidate?

    /// nil until a tool is picked in the toolbar: a drag inside the frame
    /// then moves it instead of drawing.
    var tool: AnnotationTool?
    /// The frame shape the frame button picks; the last one chosen is kept.
    var frameShape: AnnotationTool {
        get { AnnotationTool(rawValue: Prefs.int(Self.frameShapeKey, AnnotationTool.rectangle.rawValue))
                .flatMap { $0.isFrame ? $0 : nil } ?? .rectangle }
        set { if newValue.isFrame { UserDefaults.standard.set(newValue.rawValue, forKey: Self.frameShapeKey) } }
    }
    static let frameShapeKey = "snip.frameShape"
    /// Frames painted solid, covering what is inside; the last choice is kept.
    var frameFilled: Bool {
        get { Prefs.bool(Self.frameFilledKey, false) }
        set { UserDefaults.standard.set(newValue, forKey: Self.frameFilledKey) }
    }
    static let frameFilledKey = "snip.frameFilled"
    /// Width of the mosaic brush; the last one chosen is kept.
    var mosaicSize: CGFloat {
        get {
            let stored = CGFloat(Prefs.int(Self.mosaicSizeKey, Int(Mosaic.defaultBrushSize)))
            return Mosaic.brushSizes.contains(stored) ? stored : Mosaic.defaultBrushSize
        }
        set { if Mosaic.brushSizes.contains(newValue) { UserDefaults.standard.set(Int(newValue), forKey: Self.mosaicSizeKey) } }
    }
    static let mosaicSizeKey = "snip.mosaicSize"
    /// All screens pixelated once, on the first mosaic stroke of a screenshot,
    /// so every stroke shares one grid of blocks.
    lazy var mosaicPixels: CGImage? = Mosaic.image(of: screensBounds, captures: captures)
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 3

    var annotations: [Annotation] = []
    var redoStack: [Annotation] = []
    var draft: Annotation?

    var windows: [WindowCandidate] = []
    var enabledWindowDetection: Bool { Prefs.bool("snip.detectWindows", true) }

    weak var controller: OverlayController?

    init(captures: [DisplayCapture]) {
        self.captures = captures
    }

    /// All captured screens together; a moved frame stays inside it.
    var screensBounds: CGRect {
        captures.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
    }

    func capture(containing point: CGPoint) -> DisplayCapture? {
        captures.first { $0.bounds.contains(point) } ?? captures.first
    }

    func undo() {
        guard let last = annotations.popLast() else { return }
        redoStack.append(last)
        controller?.refreshAll()
    }

    func redo() {
        guard let last = redoStack.popLast() else { return }
        annotations.append(last)
        controller?.refreshAll()
    }

    // MARK: Output

    /// Composites the selection across every intersecting display, then draws
    /// annotations on top.
    func renderFinalImage() -> NSImage? {
        guard let sel = selection, sel.width >= 1, sel.height >= 1 else { return nil }

        let baseScale = captures.map(\.scale).max() ?? 2
        let pxWidth = Int((sel.width * baseScale).rounded())
        let pxHeight = Int((sel.height * baseScale).rounded())
        guard pxWidth > 0, pxHeight > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil,
                                  width: pxWidth,
                                  height: pxHeight,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }

        // Flip to a top-left origin, y-down pixel space so every coordinate
        // matches the CG global space used by the selection and annotations.
        ctx.translateBy(x: 0, y: CGFloat(pxHeight))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high

        let pxScale = CGFloat(pxWidth) / sel.width

        for capture in captures {
            let inter = sel.intersection(capture.bounds)
            guard !inter.isNull, inter.width >= 1, inter.height >= 1 else { continue }
            let local = CGRect(x: inter.minX - capture.bounds.minX,
                               y: inter.minY - capture.bounds.minY,
                               width: inter.width,
                               height: inter.height)
            guard let piece = ScreenCapture.crop(capture, localRect: local) else { continue }
            let dst = CGRect(x: (inter.minX - sel.minX) * pxScale,
                             y: (inter.minY - sel.minY) * pxScale,
                             width: inter.width * pxScale,
                             height: inter.height * pxScale)
            // The context is flipped (y down) to match the selection space,
            // but CGContext.draw always paints an image bottom-up — so each
            // piece is un-flipped locally, otherwise it lands upside down.
            ctx.saveGState()
            ctx.translateBy(x: dst.minX, y: dst.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(piece, in: CGRect(origin: .zero, size: dst.size))
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.scaleBy(x: pxScale, y: pxScale)
        ctx.translateBy(x: -sel.minX, y: -sel.minY)
        for annotation in annotations {
            annotation.draw(in: ctx, textColor: annotation.color)
        }
        ctx.restoreGState()

        guard let cgImage = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: sel.width, height: sel.height))
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    @discardableResult
    func copyToPasteboard() -> Bool {
        guard let image = renderFinalImage() else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        if let png = Self.pngData(image) {
            pasteboard.setData(png, forType: .png)
        }
        return true
    }

    /// Asks where to save an already rendered image. Must run *after* the
    /// overlay is gone: the overlay sits at screen-saver level and would
    /// cover the save panel.
    static func save(_ image: NSImage) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = timestampName()
        panel.directoryURL = SaveFolder.current
        guard panel.runModal() == .OK, let url = panel.url, let png = pngData(image) else { return }
        do {
            try png.write(to: url)
            SaveFolder.remember(url)
            Toast.show(L("Saved: %@", url.lastPathComponent))
        } catch {
            Toast.show(L("Save failed: %@", error.localizedDescription), duration: 2.5)
        }
    }

    /// The folder the save panel opens in: where the last screenshot was saved,
    /// or the Desktop when that folder is gone.
    enum SaveFolder {
        static let key = "snip.saveFolder"

        static var current: URL? {
            if let path = UserDefaults.standard.string(forKey: key) {
                var isFolder: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue {
                    return URL(fileURLWithPath: path, isDirectory: true)
                }
            }
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        }

        /// `file`: the screenshot just saved.
        static func remember(_ file: URL) {
            UserDefaults.standard.set(file.deletingLastPathComponent().path, forKey: key)
        }
    }

    static func timestampName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "OmniHub-\(formatter.string(from: Date())).png"
    }
}

// MARK: - Overlay view

final class OverlayView: NSView {
    let capture: DisplayCapture
    private let session: SnipSession

    init(capture: DisplayCapture, session: SnipSession) {
        self.capture = capture
        self.session = session
        super.init(frame: CGRect(origin: .zero, size: capture.bounds.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// Only the overlay on the pointer's display is key when a screenshot
    /// starts; a press on another display's overlay must still select,
    /// not just make that window key (it took a second click).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var textField: NSTextField?
    private var textOrigin: CGPoint = .zero
    /// Edge(s) being dragged to adjust a finished selection, and the frame
    /// as it was when the drag began.
    private var resizing: (handle: SelectionHandle, original: CGRect)?
    /// A drag inside the frame with no tool chosen: where it started.
    private var moving: (start: CGPoint, original: CGRect)?

    /// Mouse-moved events only reach the key window by default; a tracking
    /// area makes window detection and the magnifier work on every display.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    // MARK: Inline text entry

    /// Text is typed straight onto the screenshot. (A modal alert cannot be
    /// used here: it would open underneath the screen-saver-level overlay.)
    private func beginTextEntry(at point: CGPoint) {
        commitTextEntry()
        let local = toLocal(point)
        let field = NSTextField(frame: NSRect(x: local.x, y: local.y, width: 260, height: 26))
        field.font = .systemFont(ofSize: 16, weight: .semibold)
        field.textColor = session.color
        field.backgroundColor = NSColor.black.withAlphaComponent(0.35)
        field.drawsBackground = true
        field.isBordered = false
        field.focusRingType = .none
        field.placeholderString = L("Type, Return to confirm")
        field.cell?.sendsActionOnEndEditing = true
        field.target = self
        field.action = #selector(textEntryDone)
        field.delegate = self
        addSubview(field)
        textField = field
        textOrigin = point
        window?.makeKey()
        window?.makeFirstResponder(field)
    }

    @objc private func textEntryDone() { commitTextEntry() }

    private func commitTextEntry() {
        guard let field = textField else { return }
        textField = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        if !text.isEmpty {
            // The field draws its text 2pt in from its frame.
            let origin = CGPoint(x: textOrigin.x + 2, y: textOrigin.y + 2)
            session.annotations.append(Annotation(shape: .text(text, origin),
                                                  color: session.color,
                                                  lineWidth: session.lineWidth))
            session.redoStack.removeAll()
        }
        window?.makeFirstResponder(self)
        session.controller?.refreshAll()
    }

    private func cancelTextEntry() {
        guard let field = textField else { return }
        textField = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
    }

    /// View point (top-left origin, matches the display) -> CG global point.
    private func globalPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: capture.bounds.minX + p.x, y: capture.bounds.minY + p.y)
    }

    private var localBounds: CGRect { CGRect(origin: .zero, size: capture.bounds.size) }

    private func toLocal(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -capture.bounds.minX, dy: -capture.bounds.minY)
    }

    private func toLocal(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - capture.bounds.minX, y: point.y - capture.bounds.minY)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        drawBaseImage(ctx)

        // Dim everything, then punch the selection back to full brightness.
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.fill(localBounds)

        if let sel = session.selection {
            let local = toLocal(sel).intersection(localBounds)
            if !local.isNull, local.width >= 1, local.height >= 1 {
                ctx.saveGState()
                ctx.clip(to: local)
                drawBaseImage(ctx)
                ctx.restoreGState()
            }
            drawSelectionChrome(ctx, local: toLocal(sel))
        } else if let hovered = session.hoveredWindow, session.stage == .selecting {
            drawWindowHighlight(ctx, local: toLocal(hovered.frame))
        }

        drawAnnotations(ctx)

        if session.stage == .selecting, Prefs.bool("snip.magnifier", true) {
            drawMagnifierIfNeeded(ctx)
        }
    }

    private func drawBaseImage(_ ctx: CGContext) {
        ctx.saveGState()
        // CGImage is stored top-row-first; flip so it lands upright in a
        // top-left-origin context.
        ctx.translateBy(x: 0, y: localBounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(capture.image, in: localBounds)
        ctx.restoreGState()
    }

    private func drawSelectionChrome(_ ctx: CGContext, local: CGRect) {
        guard local.width >= 1, local.height >= 1 else { return }
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(local.insetBy(dx: 0.5, dy: 0.5))

        // Grab handles: corners and edge midpoints (each edge drags too).
        let handle: CGFloat = 7
        ctx.setFillColor(NSColor.white.cgColor)
        for corner in SelectionEdit.handlePoints(of: local) {
            let r = CGRect(x: corner.x - handle / 2, y: corner.y - handle / 2,
                           width: handle, height: handle)
            ctx.fill(r)
            ctx.stroke(r)
        }

        let label = "\(Int(session.selection?.width ?? 0)) × \(Int(session.selection?.height ?? 0))"
        drawBadge(ctx, text: label,
                  at: CGPoint(x: local.minX, y: local.maxY + 6))
        ctx.restoreGState()
    }

    private func drawWindowHighlight(_ ctx: CGContext, local: CGRect) {
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(2)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.stroke(local.insetBy(dx: 1, dy: 1))
        ctx.restoreGState()
    }

    private func drawBadge(_ ctx: CGContext, text: String, at point: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 5
        let box = CGRect(x: point.x, y: point.y,
                         width: size.width + pad * 2, height: size.height + pad)
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        let path = CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()

        let previous = NSGraphicsContext.current
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        (text as NSString).draw(at: CGPoint(x: point.x + pad, y: point.y + pad / 2),
                                withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.current = previous
    }

    private func drawAnnotations(_ ctx: CGContext) {
        guard let sel = session.selection else { return }
        ctx.saveGState()
        // Clip to the selection so nothing bleeds onto the dimmed area.
        ctx.clip(to: toLocal(sel))
        ctx.translateBy(x: -capture.bounds.minX, y: -capture.bounds.minY)

        for annotation in session.annotations {
            annotation.draw(in: ctx, textColor: annotation.color)
        }
        if let draft = session.draft {
            draft.draw(in: ctx, textColor: draft.color)
        }
        ctx.restoreGState()
    }

    private func drawMagnifierIfNeeded(_ ctx: CGContext) {
        guard let point = session.cursor else { return }
        let local = toLocal(point)
        let side: CGFloat = 128
        let sample: CGFloat = 16          // sampled region in points

        var origin = CGPoint(x: local.x + 20, y: local.y + 20)
        if origin.x + side > localBounds.maxX { origin.x = local.x - side - 20 }
        if origin.y + side > localBounds.maxY { origin.y = local.y - side - 20 }

        let target = CGRect(origin: origin, size: CGSize(width: side, height: side))
        let source = CGRect(x: local.x - sample / 2, y: local.y - sample / 2,
                            width: sample, height: sample)

        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.85).cgColor)
        ctx.fillEllipse(in: target.insetBy(dx: -3, dy: -3))
        ctx.addEllipse(in: target)
        ctx.clip()

        ctx.saveGState()
        ctx.translateBy(x: 0, y: localBounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .none
        // Map the sampled region of the display image into the lens.
        let s = capture.scale
        let srcPixels = CGRect(x: source.minX * s, y: source.minY * s,
                               width: source.width * s, height: source.height * s)
        if let sub = capture.image.cropping(to: srcPixels) {
            ctx.draw(sub, in: CGRect(x: target.minX,
                                     y: localBounds.height - target.maxY,
                                     width: target.width, height: target.height))
        }
        ctx.restoreGState()

        // Crosshair inside the lens.
        ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: target.midX, y: target.minY + 8))
        ctx.addLine(to: CGPoint(x: target.midX, y: target.maxY - 8))
        ctx.move(to: CGPoint(x: target.minX + 8, y: target.midY))
        ctx.addLine(to: CGPoint(x: target.maxX - 8, y: target.midY))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: Mouse

    override func rightMouseDown(with event: NSEvent) {
        session.controller?.handleEscape()
    }

    override func mouseDown(with event: NSEvent) {
        if textField != nil { commitTextEntry(); return }
        if window?.isKeyWindow == false { window?.makeKey() }
        guard session.stage == .selecting else {
            let point = globalPoint(convert(event.locationInWindow, from: nil))
            // Pressing on the frame resizes it; inside, it moves (no tool
            // chosen) or annotates with the chosen tool.
            if let sel = session.selection, let handle = SelectionEdit.handle(at: point, in: sel) {
                resizing = (handle, sel)
                return
            }
            if session.tool == nil {
                if let sel = session.selection, sel.contains(point) {
                    moving = (point, sel)
                    NSCursor.closedHand.set()
                }
                return
            }
            beginAnnotation(at: point, event: event)
            return
        }
        let point = globalPoint(convert(event.locationInWindow, from: nil))
        session.anchor = point
        session.cursor = point
        session.selection = CGRect(origin: point, size: .zero)
        session.controller?.refreshAll()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = globalPoint(convert(event.locationInWindow, from: nil))
        session.cursor = point

        if let resizing {
            session.selection = SelectionEdit.resize(resizing.original, handle: resizing.handle, to: point)
            session.controller?.selectionDidMove()
            return
        }
        if let moving {
            let delta = CGSize(width: point.x - moving.start.x, height: point.y - moving.start.y)
            session.selection = SelectionEdit.move(moving.original, by: delta, within: session.screensBounds)
            session.controller?.selectionDidMove()
            return
        }

        if session.stage == .selecting {
            guard let anchor = session.anchor else { return }
            session.selection = CGRect(x: min(anchor.x, point.x),
                                       y: min(anchor.y, point.y),
                                       width: abs(point.x - anchor.x),
                                       height: abs(point.y - anchor.y))
            session.controller?.refreshAll()
            return
        }

        updateDraft(to: point)
        session.controller?.refreshAll()
    }

    override func mouseUp(with event: NSEvent) {
        if moving != nil {
            moving = nil
            NSCursor.openHand.set()
            session.controller?.selectionDidMove()
            return
        }
        if let resizing {
            self.resizing = nil
            if let sel = session.selection, !SelectionEdit.isUsable(sel) {
                session.selection = resizing.original
            }
            session.controller?.selectionDidMove()
            return
        }
        if session.stage == .selecting {
            finishSelection(at: globalPoint(convert(event.locationInWindow, from: nil)))
            return
        }

        if let draft = session.draft {
            // Without screen pixels a mosaic would cover nothing: keep no empty step to undo.
            if case .mosaic(_, nil, _) = draft.shape {
                session.draft = nil
                session.controller?.refreshAll()
                return
            }
            session.annotations.append(draft)
            session.redoStack.removeAll()
            session.draft = nil
        }
        session.controller?.refreshAll()
    }

    private func finishSelection(at point: CGPoint) {
        if let sel = session.selection, sel.width >= 4, sel.height >= 4 {
            session.stage = .annotating
            session.controller?.selectionDidComplete()
            return
        }
        // Click (not drag) -> adopt the detected window under the cursor.
        if session.enabledWindowDetection,
           let hovered = WindowPicker.topmost(at: point, in: session.windows) {
            session.selection = hovered.frame
            session.stage = .annotating
            session.controller?.selectionDidComplete()
            return
        }
        session.selection = nil
        session.anchor = nil
        session.controller?.cancel()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = globalPoint(convert(event.locationInWindow, from: nil))
        guard session.stage == .selecting else {
            // Edges resize; inside, a hand (moves) or the chosen tool.
            switch SelectionEdit.pointer(at: point, selection: session.selection, tool: session.tool) {
            case .resize(let handle): SelectionEdit.cursor(for: handle).set()
            case .move: NSCursor.openHand.set()
            case .tool(let tool): SnipCursor.cursor(for: tool, brushSize: session.mosaicSize).set()
            case .arrow: NSCursor.arrow.set()
            }
            return
        }
        session.cursor = point
        session.hoveredWindow = session.enabledWindowDetection
            ? WindowPicker.topmost(at: point, in: session.windows) : nil
        session.controller?.refreshAll()
    }

    // MARK: Annotation input

    private func beginAnnotation(at point: CGPoint, event: NSEvent) {
        guard let tool = session.tool, let sel = session.selection, sel.contains(point) else { return }
        session.anchor = point

        switch tool {
        case .rectangle:
            session.draft = Annotation(shape: .rectangle(CGRect(origin: point, size: .zero)),
                                       color: session.color, lineWidth: session.lineWidth, filled: session.frameFilled)
        case .ellipse:
            session.draft = Annotation(shape: .ellipse(CGRect(origin: point, size: .zero)),
                                       color: session.color, lineWidth: session.lineWidth, filled: session.frameFilled)
        case .arrow:
            session.draft = Annotation(shape: .arrow(from: point, to: point),
                                       color: session.color, lineWidth: session.lineWidth)
        case .pen:
            session.draft = Annotation(shape: .pen([point]),
                                       color: session.color, lineWidth: session.lineWidth)
        case .text:
            beginTextEntry(at: point)
        case .mosaic:
            session.draft = Annotation(shape: .mosaic([point], pixels: session.mosaicPixels,
                                                      area: session.screensBounds),
                                       color: session.color, lineWidth: session.mosaicSize)
        }
        session.controller?.refreshAll()
    }

    private func updateDraft(to point: CGPoint) {
        guard let draft = session.draft, let anchor = session.anchor else { return }
        var updated = draft
        switch draft.shape {
        case .rectangle:
            updated.shape = .rectangle(CGRect(x: min(anchor.x, point.x),
                                              y: min(anchor.y, point.y),
                                              width: abs(point.x - anchor.x),
                                              height: abs(point.y - anchor.y)))
        case .ellipse:
            updated.shape = .ellipse(CGRect(x: min(anchor.x, point.x),
                                            y: min(anchor.y, point.y),
                                            width: abs(point.x - anchor.x),
                                            height: abs(point.y - anchor.y)))
        case .arrow:
            updated.shape = .arrow(from: anchor, to: point)
        case .pen(var points):
            points.append(point)
            updated.shape = .pen(points)
        case .mosaic(var points, let pixels, let area):
            points.append(point)
            updated.shape = .mosaic(points, pixels: pixels, area: area)
        case .text:
            break
        }
        session.draft = updated
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if handleCommandKey(event) { return }
        switch event.keyCode {
        case 53: // Esc
            session.controller?.handleEscape()
        case 36, 76: // Return / keypad Enter
            session.controller?.finish()
        default:
            break   // swallow: no system beep for stray keys
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if textField != nil { return super.performKeyEquivalent(with: event) }
        return handleCommandKey(event) || super.performKeyEquivalent(with: event)
    }

    /// ⌘Z undo · ⇧⌘Z redo · ⌘C copy & finish · ⌘S save · ⌘T pin.
    private func handleCommandKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "z":
            if flags.contains(.shift) { session.redo() } else { session.undo() }
            return true
        case "c":
            session.controller?.finish()
            return true
        case "s":
            session.controller?.save()
            return true
        case "t":
            session.controller?.pin()
            return true
        default:
            return false
        }
    }
}

extension OverlayView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Esc while typing leaves the screenshot too, like everywhere else.
            cancelTextEntry()
            session.controller?.handleEscape()
            return true
        }
        return false
    }
}

// MARK: - Overlay window

final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Controller

final class OverlayController {
    /// The dimmed full-screen layer you draw on.
    static let overlayLevel = NSWindow.Level.screenSaver
    /// The toolbar sits one level higher: a press on the overlay brings that
    /// window to the front of its level, which used to bury a same-level toolbar.
    static let toolbarLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

    private let session: SnipSession
    private var windows: [OverlayWindow] = []
    private var views: [OverlayView] = []
    private var toolbar: ToolbarPanel?
    private var scrollController: ScrollCaptureController?
    private var didFinish = false
    private let autoScroll: Bool

    init(captures: [DisplayCapture], autoScroll: Bool = false) {
        self.autoScroll = autoScroll
        session = SnipSession(captures: captures)
        session.controller = self
    }

    func present() {
        session.windows = WindowPicker.candidates()

        for screen in NSScreen.screens {
            let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber
            let displayID = CGDirectDisplayID(screenNumber?.uint32Value ?? 0)
            guard let capture = session.captures.first(where: { $0.displayID == displayID })
                    ?? session.captures.first(where: { $0.bounds.equalTo(screen.frame) })
            else { continue }

            let window = OverlayWindow(contentRect: screen.frame,
                                       styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered,
                                       defer: false)
            window.level = Self.overlayLevel
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                         .stationary, .ignoresCycle]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.hidesOnDeactivate = false

            let view = OverlayView(capture: capture, session: session)
            window.contentView = view
            window.setFrame(screen.frame, display: false)
            window.orderFrontRegardless()

            windows.append(window)
            views.append(view)
        }

        FocusKeeper.activateSelf()
        // Key window = the display the pointer is on, so Esc/Enter work there.
        let mouse = NSEvent.mouseLocation
        let keyIndex = windows.firstIndex { $0.frame.contains(mouse) } ?? 0
        if keyIndex < windows.count {
            windows[keyIndex].makeKeyAndOrderFront(nil)
            windows[keyIndex].makeFirstResponder(views[keyIndex])
        }
        NSCursor.crosshair.push()
    }

    func refreshAll() {
        // Broadcast the shared selection to every display overlay.
        for view in views {
            view.needsDisplay = true
        }
        if session.stage == .annotating {
            showToolbarIfNeeded()
        }
    }

    /// Esc (also right-click and the toolbar's ✕) leaves the screenshot at
    /// once, whatever stage it is in — selecting, selected or annotating.
    func handleEscape() {
        cancel()
    }

    func finish() {
        guard !didFinish else { return }
        didFinish = true
        let copied = session.copyToPasteboard()
        close()
        if copied, Prefs.bool("snip.toast", true) { Toast.show("Screenshot copied") }
    }

    /// Pin: leaves the capture floating on screen exactly where it was taken.
    func pin() {
        guard !didFinish, let sel = session.selection,
              let image = session.renderFinalImage() else { return }
        didFinish = true
        close()
        PinnedImageWindow.pin(image, at: sel)
    }

    /// Renders first, removes the overlay, then asks where to save.
    func save() {
        guard !didFinish, let image = session.renderFinalImage() else { return }
        didFinish = true
        close()
        SnipSession.save(image)
    }

    func cancel() {
        close()
    }

    /// Removes every overlay surface without ending the snip lifecycle.
    private func teardownOverlays() {
        toolbar?.close()
        toolbar = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
    }

    /// Long / scrolling screenshot: the region is polled repeatedly and new
    /// rows are stitched by vertical overlap.
    func startScrollCapture() {
        guard let sel = session.selection, sel.width >= 8, sel.height >= 8 else { return }
        NSCursor.pop()
        teardownOverlays()
        // Hand the keyboard and scroll focus back to the app being captured.
        FocusKeeper.restore()

        let controller = ScrollCaptureController(region: sel)
        scrollController = controller
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { controller.start() }
    }

    func finishScrollCapture() { scrollController?.finish() }

    private(set) var isClosed = false
    /// Test hook (see --snip-selftest).
    var debugSession: SnipSession { session }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        NSCursor.pop()
        teardownOverlays()
        AppDelegate.shared?.snipDidEnd()
        FocusKeeper.restore()
    }

    private func showToolbarIfNeeded() {
        guard toolbar == nil, let sel = session.selection else { return }
        let panel = ToolbarPanel(session: session, controller: self)
        panel.show(near: sel)
        toolbar = panel
    }

    /// The frame was adjusted after selection: redraw and keep the toolbar
    /// docked to its new bottom-right corner.
    func selectionDidMove() {
        refreshAll()
        if let sel = session.selection { toolbar?.show(near: sel) }
    }

    func selectionDidComplete() {
        refreshAll()
        guard autoScroll else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.startScrollCapture()
        }
    }

    /// Scripted demo state (used by `--demo`) so the overlay can be captured
    /// for documentation without a human dragging a rectangle. With the main
    /// window open the frame is that window (Home), so only OmniHub shows.
    func runDemo() {
        guard let first = session.captures.first else { return }
        // The display showing most of the main window, else the first one.
        let shown = MainWindow.shownFrameCG
        let display = shown.flatMap { frame in
            session.captures.max { a, b in
                let x = a.bounds.intersection(frame), y = b.bounds.intersection(frame)
                return x.width * x.height < y.width * y.height
            }
        } ?? first
        let b = display.bounds
        let window = shown.map { $0.intersection(b) }.flatMap { $0.isEmpty ? nil : $0 }
        let sel = window ?? CGRect(x: b.minX + 200, y: b.minY + 160, width: 760, height: 440)
        session.selection = sel
        session.cursor = CGPoint(x: sel.midX, y: sel.midY)
        session.stage = .annotating
        session.tool = .rectangle   // its options (shapes, Fill, colours) show under the toolbar
        // Placed as parts of the frame, so they land on the same cards at any size.
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: sel.minX + x * sel.width, y: sel.minY + y * sel.height, width: w * sel.width, height: h * sel.height)
        }
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: sel.minX + x * sel.width, y: sel.minY + y * sel.height)
        }
        session.annotations = [
            Annotation(shape: .rectangle(box(0.275, 0.225, 0.34, 0.33)), color: .systemRed, lineWidth: 4),
            Annotation(shape: .ellipse(box(0.62, 0.25, 0.36, 0.25)), color: .systemBlue, lineWidth: 4),
            // Filled: what is inside is covered.
            Annotation(shape: .rectangle(box(0.29, 0.635, 0.31, 0.12)), color: .systemYellow, lineWidth: 4, filled: true),
            Annotation(shape: .arrow(from: point(0.5, 0.9), to: point(0.7, 0.72)), color: .systemYellow, lineWidth: 4),
            Annotation(shape: .text("OmniHub", point(0.29, 0.03)), color: .systemRed, lineWidth: 3)
        ]
        selectionDidComplete()
    }
}
