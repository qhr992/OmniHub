import AppKit

/// Small HUD-styled building blocks shared by the toolbar and its options strip.
private enum HUD {
    static func background() -> NSVisualEffectView {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        return effect
    }

    static func row(insets: NSEdgeInsets) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = insets
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func embed(_ stack: NSStackView, in effect: NSView) {
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])
    }

    static func separator(height: CGFloat = 22) -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        box.heightAnchor.constraint(equalToConstant: height).isActive = true
        return box
    }

    static func toolButton(image: NSImage?, tooltip: String, side: CGFloat,
                           target: AnyObject, action: Selector) -> ToolButton {
        let button = ToolButton(image: image ?? NSImage(), target: target, action: action)
        button.title = ""
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.toolTip = tooltip
        button.widthAnchor.constraint(equalToConstant: side).isActive = true
        button.heightAnchor.constraint(equalToConstant: side).isActive = true
        return button
    }

    static func configure(_ panel: NSPanel, level: NSWindow.Level) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }
}

// MARK: - Toolbar

final class ToolbarPanel: NSPanel {
    private unowned let controller: OverlayController
    private let session: SnipSession
    /// One button per toolbar tool; the frame button stands for both frame shapes.
    private var toolButtons: [(tool: AnnotationTool, button: ToolButton)] = []
    private static let toolbarTools: [AnnotationTool] = [.rectangle, .arrow, .pen, .text, .mosaic]
    /// The chosen tool's options (shape, colour, brush size), under or over the toolbar.
    private lazy var options = ToolOptionsPanel(session: session) { [weak self] in self?.refreshChoices() }

    init(session: SnipSession, controller: OverlayController) {
        self.session = session
        self.controller = controller
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 44),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        HUD.configure(self, level: OverlayController.toolbarLevel)
        buildContent()
    }

    private func buildContent() {
        let effect = HUD.background()
        let stack = HUD.row(insets: NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10))

        for tool in Self.toolbarTools {
            let title = tool.isFrame ? "Frame" : tool.title
            let button = HUD.toolButton(image: NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: title),
                                        tooltip: title, side: 26, target: self, action: #selector(selectTool(_:)))
            button.tag = toolButtons.count
            toolButtons.append((tool, button))
            stack.addArrangedSubview(button)
        }

        stack.addArrangedSubview(HUD.separator())
        stack.addArrangedSubview(makeButton(symbol: "arrow.uturn.backward", tooltip: "Undo", action: #selector(doUndo)))
        stack.addArrangedSubview(makeButton(symbol: "arrow.uturn.forward", tooltip: "Redo", action: #selector(doRedo)))
        stack.addArrangedSubview(HUD.separator())
        stack.addArrangedSubview(makeButton(symbol: "arrow.up.and.down.square", tooltip: "Scrolling screenshot",
                                            action: #selector(doScrollCapture)))
        stack.addArrangedSubview(makeButton(symbol: "pin", tooltip: "Pin on top (⌘T)", action: #selector(doPin)))
        stack.addArrangedSubview(makeButton(symbol: "square.and.arrow.down", tooltip: "Save (⌘S)", action: #selector(doSave)))
        // No close button: Esc (or right-click) leaves the screenshot.
        stack.addArrangedSubview(makeButton(symbol: "checkmark", tooltip: "Copy (Enter)", action: #selector(doFinish)))

        HUD.embed(stack, in: effect)
        contentView = effect
        refreshChoices()
    }

    private func makeButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.title = ""
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.contentTintColor = .labelColor
        button.toolTip = tooltip
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    /// Marks the chosen tool and shows its options next to the toolbar.
    private func refreshChoices() {
        let tool = session.tool
        for (slot, button) in toolButtons {
            if slot.isFrame {
                let shape = tool.flatMap { $0.isFrame ? $0 : nil } ?? session.frameShape
                button.image = NSImage(systemSymbolName: shape.symbolName, accessibilityDescription: "Frame")
                button.isChosen = tool?.isFrame == true
            } else {
                button.isChosen = tool == slot
            }
        }
        options.update(for: tool)
        placeOptions()
    }

    /// Under the toolbar, starting at the chosen tool; over it when there is no room below.
    private func placeOptions() {
        guard isVisible, options.hasContent, let chosen = toolButtons.first(where: { $0.button.isChosen })?.button,
              let screen = screen ?? NSScreen.main else {
            if let parent = options.parent { parent.removeChildWindow(options) }
            options.orderOut(nil)
            return
        }
        let anchor = convertToScreen(chosen.convert(chosen.bounds, to: nil))
        options.place(under: anchor, toolbar: frame, screen: screen.frame)
        if options.parent == nil { addChildWindow(options, ordered: .above) }
        options.orderFrontRegardless()
    }

    override func close() {
        options.close()
        super.close()
    }

    /// Test hooks (see --snip-selftest).
    func debugChoose(tool: AnnotationTool) {
        if let slot = toolButtons.first(where: { $0.tool == tool || ($0.tool.isFrame && tool.isFrame) }) {
            selectTool(slot.button)
        }
    }
    func debugChoose(shape: AnnotationTool) { options.debugChoose(shape: shape) }
    func debugChoose(color index: Int) { options.debugChoose(color: index) }
    func debugChoose(size index: Int) { options.debugChoose(size: index) }
    var debugToolNames: [String] { toolButtons.map { $0.button.toolTip ?? "" } }
    /// e.g. "tools=Frame shapes=Ellipse colors=2 sizes=hidden"; "hidden" when not offered.
    var debugChoices: String {
        let tools = toolButtons.filter(\.button.isChosen).map { $0.button.toolTip ?? "" }
        return "tools=" + tools.joined(separator: ",") + " " + options.debugChoices
    }
    var debugOptionsPanel: NSPanel { options }
    var debugChosenToolFrame: NSRect? {
        toolButtons.first(where: { $0.button.isChosen }).map { convertToScreen($0.button.convert($0.button.bounds, to: nil)) }
    }

    /// Docks under the bottom-right corner of the selection, clamped on screen.
    func show(near selection: CGRect) {
        let anchorPoint = CGPoint(x: selection.midX, y: selection.maxY)
        guard let screen = ScreenGeometry.screen(containing: anchorPoint) else { return }
        contentView?.layoutSubtreeIfNeeded()
        let size = contentView?.fittingSize ?? NSSize(width: 400, height: 44)
        setContentSize(size)

        let anchor = ScreenGeometry.appKitPoint(fromCG: CGPoint(x: selection.maxX, y: selection.maxY),
                                                on: screen)
        var origin = NSPoint(x: anchor.x - size.width, y: anchor.y - size.height - 8)
        origin.x = max(screen.frame.minX + 8, min(origin.x, screen.frame.maxX - size.width - 8))
        origin.y = max(screen.frame.minY + 8, min(origin.y, screen.frame.maxY - size.height - 8))
        setFrameOrigin(origin)
        orderFrontRegardless()
        placeOptions()
    }

    @objc private func selectTool(_ sender: NSButton) {
        guard toolButtons.indices.contains(sender.tag) else { return }
        let slot = toolButtons[sender.tag].tool
        let isChosen = slot.isFrame ? session.tool?.isFrame == true : session.tool == slot
        // The chosen tool again: back to no tool, where a drag moves the frame.
        session.tool = isChosen ? nil : (slot.isFrame ? session.frameShape : slot)
        refreshChoices()
    }

    @objc private func doUndo() { session.undo() }
    @objc private func doRedo() { session.redo() }
    @objc private func doScrollCapture() { controller.startScrollCapture() }
    @objc private func doSave() { controller.save() }
    @objc private func doPin() { controller.pin() }
    @objc private func doFinish() { controller.finish() }
}

// MARK: - Tool options

/// The chosen tool's options in a strip of their own: frame shapes and
/// colours for the frame, colours for arrow / pen / text, brush sizes for
/// the mosaic. Nothing for no tool.
final class ToolOptionsPanel: NSPanel {
    private let session: SnipSession
    private let onChange: () -> Void
    private var shapeButtons: [ToolButton] = []
    private var colorButtons: [NSButton] = []
    private var sizeButtons: [ToolButton] = []
    private var shapeViews: [NSView] = []
    /// Inner margins and the gap between options, in points.
    private static let insets = NSSize(width: 8, height: 5)
    private static let spacing: CGFloat = 6
    private static let colors: [NSColor] = [.systemRed, .systemYellow, .systemBlue, .white]
    /// Gap between the toolbar and the strip.
    private static let gap: CGFloat = 6
    private(set) var hasContent = false

    init(session: SnipSession, onChange: @escaping () -> Void) {
        self.session = session
        self.onChange = onChange
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 36),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        HUD.configure(self, level: OverlayController.toolbarLevel)
        buildContent()
    }

    private func buildContent() {
        for shape in AnnotationTool.frameShapes {
            let button = HUD.toolButton(image: NSImage(systemSymbolName: shape.symbolName, accessibilityDescription: shape.title),
                                        tooltip: shape.title, side: 24, target: self, action: #selector(selectShape(_:)))
            button.tag = shape.rawValue
            shapeButtons.append(button)
            shapeViews.append(button)
        }
        shapeViews.append(HUD.separator(height: 16))

        for (index, color) in Self.colors.enumerated() {
            let button = NSButton(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
            button.title = ""
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.backgroundColor = color.cgColor
            button.layer?.cornerRadius = 9
            button.tag = index
            button.target = self
            button.action = #selector(selectColor(_:))
            button.toolTip = "Color"
            // Fixed size: unconstrained, the stack squeezes the round swatches out of shape.
            button.widthAnchor.constraint(equalToConstant: 18).isActive = true
            button.heightAnchor.constraint(equalToConstant: 18).isActive = true
            colorButtons.append(button)
        }

        for (index, size) in Mosaic.brushSizes.enumerated() {
            let names = ["Small", "Medium", "Large"]
            let button = HUD.toolButton(image: Self.dot(diameter: 5 + CGFloat(index) * 5),
                                        tooltip: "Brush size: " + (index < names.count ? names[index] : "\(Int(size))"),
                                        side: 24, target: self, action: #selector(selectSize(_:)))
            button.tag = index
            sizeButtons.append(button)
        }
        contentView = HUD.background()
    }

    /// A filled dot that takes the button's tint.
    private static func dot(diameter: CGFloat) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: (side - diameter) / 2, y: (side - diameter) / 2,
                                        width: diameter, height: diameter)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Shows the options `tool` uses and marks the current choices.
    func update(for tool: AnnotationTool?) {
        let showsShapes = tool?.isFrame == true
        let showsColors = tool?.usesColor == true
        let showsSizes = tool == .mosaic
        let shown: [NSView] = (showsShapes ? shapeViews : []) + (showsColors ? colorButtons : [])
            + (showsSizes ? sizeButtons : [])
        layOut(shown)
        hasContent = !shown.isEmpty

        for button in shapeButtons { button.isChosen = button.tag == tool?.rawValue }
        for (index, button) in colorButtons.enumerated() {
            let chosen = Self.colors[index] == session.color
            button.layer?.borderWidth = chosen ? 2.5 : 1
            button.layer?.borderColor = (chosen ? NSColor.white : NSColor.black.withAlphaComponent(0.25)).cgColor
        }
        for (index, button) in sizeButtons.enumerated() { button.isChosen = Mosaic.brushSizes[index] == session.mosaicSize }

    }

    /// Lines the options up in one row at their fixed sizes and fits the
    /// strip around them (laid out by hand: a stack view measured re-shown
    /// options wrongly and clipped the strip).
    private func layOut(_ views: [NSView]) {
        guard let container = contentView else { return }
        for view in container.subviews where !views.contains(view) { view.removeFromSuperview() }
        let sizes = views.map(Self.size(of:))
        let height = (sizes.map(\.height).max() ?? 0) + Self.insets.height * 2
        var x = Self.insets.width
        for (view, size) in zip(views, sizes) {
            if view.superview !== container { container.addSubview(view) }
            view.frame = NSRect(x: x, y: ((height - size.height) / 2).rounded(), width: size.width, height: size.height)
            x += size.width + Self.spacing
        }
        let width = views.isEmpty ? 0 : x - Self.spacing + Self.insets.width
        setContentSize(NSSize(width: width, height: height))
    }

    private static func size(of view: NSView) -> NSSize {
        switch view {
        case is NSBox: return NSSize(width: 1, height: 16)
        case is ToolButton: return NSSize(width: 24, height: 24)
        default: return NSSize(width: 18, height: 18)
        }
    }

    /// Below the toolbar with its left edge under `anchor` (the chosen tool),
    /// or above the toolbar when it would leave the screen.
    func place(under anchor: NSRect, toolbar: NSRect, screen: NSRect) {
        let size = frame.size
        var origin = NSPoint(x: anchor.minX - 8, y: toolbar.minY - Self.gap - size.height)
        if origin.y < screen.minY + 4 { origin.y = toolbar.maxY + Self.gap }
        origin.x = max(screen.minX + 8, min(origin.x, screen.maxX - size.width - 8))
        setFrameOrigin(origin)
    }

    @objc private func selectShape(_ sender: NSButton) {
        guard let shape = AnnotationTool(rawValue: sender.tag), shape.isFrame else { return }
        session.frameShape = shape
        session.tool = shape
        onChange()
    }

    @objc private func selectColor(_ sender: NSButton) {
        guard sender.tag < Self.colors.count else { return }
        session.color = Self.colors[sender.tag]
        onChange()
    }

    @objc private func selectSize(_ sender: NSButton) {
        guard Mosaic.brushSizes.indices.contains(sender.tag) else { return }
        session.mosaicSize = Mosaic.brushSizes[sender.tag]
        onChange()
    }

    /// Test hooks (see --snip-selftest).
    func debugChoose(shape: AnnotationTool) {
        if let button = shapeButtons.first(where: { $0.tag == shape.rawValue }) { selectShape(button) }
    }
    func debugChoose(color index: Int) { if colorButtons.indices.contains(index) { selectColor(colorButtons[index]) } }
    func debugChoose(size index: Int) { if sizeButtons.indices.contains(index) { selectSize(sizeButtons[index]) } }
    var debugChoices: String {
        func list(_ buttons: [NSButton], _ chosen: (NSButton) -> Bool, _ name: (NSButton) -> String) -> String {
            buttons.first?.superview == nil ? "hidden" : buttons.filter(chosen).map(name).joined(separator: ",")
        }
        let shapes = list(shapeButtons, { ($0 as? ToolButton)?.isChosen == true },
                          { AnnotationTool(rawValue: $0.tag)?.title ?? "" })
        let colors = list(colorButtons, { $0.layer?.borderWidth == 2.5 }, { String($0.tag) })
        let sizes = list(sizeButtons, { ($0 as? ToolButton)?.isChosen == true }, { String($0.tag) })
        return "shapes=" + shapes + " colors=" + colors + " sizes=" + sizes
    }
}
