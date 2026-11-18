import AppKit
import Vision
import VisionKit

/// Text recognition for pinned screenshots.
enum OCR {
    /// All text in the image, top to bottom (nil when none was found).
    static func recognize(_ image: NSImage, completion: @escaping (String?) -> Void) {
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { completion(nil); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            DispatchQueue.main.async { completion(lines.isEmpty ? nil : lines.joined(separator: "\n")) }
        }
    }
}

/// Pin: a screenshot pinned on top of everything.
///
/// Drag to move · scroll, pinch, or the − / ＋ buttons (shown while the pointer
/// is over the image) to zoom · the × button, double-click or Esc to close ·
/// right-click for copy / save / opacity. Stays visible on every Space and over
/// full-screen apps.
final class PinnedImageWindow: NSPanel, EscDismissable {
    private static var open: [PinnedImageWindow] = []
    static var count: Int { open.count }

    private let image: NSImage
    private let baseSize: NSSize
    private var zoom: CGFloat = 1

    /// Pins `image` so it covers `cgRect` (CG global space, top-left origin) —
    /// i.e. exactly where it was captured.
    static func pin(_ image: NSImage, at cgRect: CGRect) {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let frame = NSRect(x: cgRect.minX, y: primaryHeight - cgRect.maxY,
                           width: cgRect.width, height: cgRect.height)
        show(image, frame: frame)
    }

    /// Pins whatever image is on the clipboard, centred on the pointer's screen.
    @discardableResult
    static func pinClipboard() -> Bool {
        guard let image = NSImage(pasteboard: NSPasteboard.general),
              image.size.width >= 1, image.size.height >= 1 else {
            Toast.show("No image on the clipboard")
            return false
        }
        var size = image.size
        let visible = NSScreen.underMouse?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let fit = min(1, visible.width * 0.8 / size.width, visible.height * 0.8 / size.height)
        size = NSSize(width: size.width * fit, height: size.height * fit)
        // Cascade so several pins do not hide each other.
        let shift = CGFloat(open.count % 6) * 24
        show(image, frame: NSRect(x: visible.midX - size.width / 2 + shift,
                                  y: visible.midY - size.height / 2 - shift,
                                  width: size.width, height: size.height))
        return true
    }

    static func closeAll() {
        for window in open { window.orderOut(nil) }
        open.removeAll()
    }

    static let pinLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

    /// Any click on a pin brings it above the other pins.
    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) { raise() }
        super.sendEvent(event)
    }

    private func raise() {
        orderFrontRegardless()
        Self.open.removeAll { $0 === self }
        Self.open.append(self)
    }

    /// Test hook: pins from bottom to top, as the window server stacks them.
    static var debugStacking: [Int] {
        let numbers = NSWindow.windowNumbers(options: []) ?? []   // front to back
        return open.compactMap { pin in numbers.firstIndex(of: NSNumber(value: pin.windowNumber)) }
    }
    static var debugPins: [PinnedImageWindow] { open }
    func debugClick() { raise() }

    private static func show(_ image: NSImage, frame: NSRect) {
        let window = PinnedImageWindow(image: image, frame: frame)
        open.append(window)
        window.orderFrontRegardless()
    }

    private init(image: NSImage, frame: NSRect) {
        self.image = image
        self.baseSize = frame.size
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // Above the dock card (status-bar level): opening any page never
        // covers a pin. Among pins, the newest or last clicked is on top.
        level = Self.pinLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true

        let view = PinnedImageView(frame: NSRect(origin: .zero, size: frame.size))
        view.image = image
        view.imageScaling = .scaleAxesIndependently
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        view.owner = self
        contentView = view
        view.installLiveText(for: image)
        view.installControls()
    }

    var zoomPercent: Int { Int((zoom * 100).rounded()) }

    /// Button / keyboard zoom: one step about the centre of the image.
    fileprivate func step(_ direction: CGFloat) {
        zoom(by: direction > 0 ? 0.25 : -0.2, around: NSPoint(x: frame.midX, y: frame.midY))
    }

    /// Test hook.
    static func debugZoomFirst(_ direction: CGFloat) -> String {
        guard let first = open.first else { return "no pin" }
        let before = first.frame.size
        first.step(direction)
        return "zoom \(first.zoomPercent)% size \(Int(before.width))x\(Int(before.height)) -> \(Int(first.frame.width))x\(Int(first.frame.height))"
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if flags.subtracting(.shift) == .command {
            switch event.keyCode {
            case 24, 69: step(1); return true        // = / keypad +
            case 27, 78: step(-1); return true       // - / keypad -
            case 29, 82: resetZoom(); return true    // 0
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override var canBecomeKey: Bool { true }

    func dismissByEscape() {
        orderOut(nil)
        Self.open.removeAll { $0 === self }
    }

    // MARK: Zoom

    fileprivate func zoom(by delta: CGFloat, around point: NSPoint) {
        let next = min(5, max(0.2, zoom * (1 + delta)))
        guard next != zoom else { return }
        let old = frame
        let size = NSSize(width: baseSize.width * next, height: baseSize.height * next)
        // Keep the point under the cursor fixed while resizing.
        let fx = old.width > 0 ? (point.x - old.minX) / old.width : 0.5
        let fy = old.height > 0 ? (point.y - old.minY) / old.height : 0.5
        zoom = next
        setFrame(NSRect(x: point.x - size.width * fx, y: point.y - size.height * fy,
                        width: size.width, height: size.height), display: true)
        (contentView as? PinnedImageView)?.zoomChanged()
    }

    fileprivate func resetZoom() {
        let centre = NSPoint(x: frame.midX, y: frame.midY)
        zoom = 1
        setFrame(NSRect(x: centre.x - baseSize.width / 2, y: centre.y - baseSize.height / 2,
                        width: baseSize.width, height: baseSize.height), display: true)
        (contentView as? PinnedImageView)?.zoomChanged()
    }

    // MARK: Menu actions

    fileprivate func contextMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        add("Copy Image", #selector(copyImage))
        add("Copy Text", #selector(copyText))
        add("Save As…", #selector(saveImage))
        menu.addItem(.separator())
        add("Zoom In", #selector(zoomInAction))
        add("Zoom Out", #selector(zoomOutAction))
        add("Actual Size", #selector(actualSize))
        add(alphaValue < 1 ? "Opaque" : "Translucent", #selector(toggleOpacity))
        menu.addItem(.separator())
        add("Close", #selector(closePin))
        add("Close All Pins", #selector(closeEvery))
        return menu
    }

    @objc private func copyImage() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        Toast.show("Copied")
    }

    /// Copies the selected text if some is selected, otherwise all the text
    /// recognised in the image.
    @objc private func copyText() {
        func put(_ text: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            Toast.show("Text copied")
        }
        if let selected = (contentView as? PinnedImageView)?.selectedText, !selected.isEmpty {
            put(selected)
            return
        }
        OCR.recognize(image) { text in
            if let text { put(text) } else { Toast.show("No text found") }
        }
    }

    @objc private func saveImage() { SnipSession.save(image) }
    @objc private func actualSize() { resetZoom() }
    @objc private func zoomInAction() { step(1) }
    @objc private func zoomOutAction() { step(-1) }
    fileprivate func closeFromButton() { dismissByEscape() }
    @objc private func toggleOpacity() { alphaValue = alphaValue < 1 ? 1 : 0.6 }
    @objc private func closePin() { dismissByEscape() }
    @objc private func closeEvery() { Self.closeAll() }
}

private final class PinnedImageView: NSImageView {
    weak var owner: PinnedImageWindow?
    private let controls = NSStackView()
    private let percent = NSTextField(labelWithString: "100%")
    private var tracking: NSTrackingArea?

    // Let the window drag from anywhere on the image.
    override var mouseDownCanMoveWindow: Bool { true }

    /// − 100% ＋ × in the top-right corner, visible while the pointer is
    /// over the image.
    func installControls() {
        func button(_ symbol: String, _ tooltip: String, _ action: Selector) -> NSButton {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage(),
                                  target: self, action: action)
            button.isBordered = false
            button.contentTintColor = .white
            button.toolTip = tooltip
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true
            return button
        }
        percent.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        percent.textColor = .white
        controls.orientation = .horizontal
        controls.spacing = 2
        controls.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        controls.wantsLayer = true
        controls.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        controls.layer?.cornerRadius = 8
        for view in [button("minus.magnifyingglass", "Zoom Out", #selector(zoomOut)), percent,
                     button("plus.magnifyingglass", "Zoom In", #selector(zoomIn)),
                     button("xmark", "Close", #selector(closeTapped))] as [NSView] {
            controls.addArrangedSubview(view)
        }
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.isHidden = true
        addSubview(controls)
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
        ])
    }

    /// Live Text over the image (macOS 13+): text in the screenshot can be
    /// selected with the mouse and copied with ⌘C. Anywhere else the image
    /// still drags the window.
    private var liveText: NSView?

    func installLiveText(for image: NSImage) {
        guard #available(macOS 13.0, *), ImageAnalyzer.isSupported else { return }
        let overlay = ImageAnalysisOverlayView()
        overlay.preferredInteractionTypes = .textSelection
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.trackingImageView = self
        addSubview(overlay)
        liveText = overlay
        Task { [weak overlay] in
            let analyzer = ImageAnalyzer()
            guard let analysis = try? await analyzer.analyze(image, orientation: .up,
                                                             configuration: ImageAnalyzer.Configuration([.text])) else { return }
            await MainActor.run { overlay?.analysis = analysis }
        }
    }

    var selectedText: String? {
        guard #available(macOS 14.0, *), let overlay = liveText as? ImageAnalysisOverlayView else { return nil }
        return overlay.selectedText
    }

    /// The overlay only gets the mouse where there is text to select.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard #available(macOS 13.0, *), let overlay = liveText as? ImageAnalysisOverlayView,
              let hit, hit === overlay || hit.isDescendant(of: overlay) else { return hit }
        let local = overlay.convert(point, from: superview)
        return overlay.hasInteractiveItem(at: local) || overlay.hasActiveTextSelection ? hit : self
    }

    func zoomChanged() { percent.stringValue = "\(owner?.zoomPercent ?? 100)%" }

    @objc private func zoomIn() { owner?.step(1) }
    @objc private func zoomOut() { owner?.step(-1) }
    @objc private func closeTapped() { owner?.closeFromButton() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { controls.isHidden = false }
    override func mouseExited(with event: NSEvent) { controls.isHidden = true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            owner?.dismissByEscape()
            return
        }
        // Clicking makes it key, so Esc closes this pin.
        window?.makeKey()
        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 300 : event.scrollingDeltaY / 20
        guard delta != 0 else { return }
        owner?.zoom(by: max(-0.3, min(0.3, delta)), around: NSEvent.mouseLocation)
    }

    /// Trackpad pinch.
    override func magnify(with event: NSEvent) {
        owner?.zoom(by: event.magnification, around: NSEvent.mouseLocation)
    }

    override func menu(for event: NSEvent) -> NSMenu? { owner?.contextMenu() }
}
