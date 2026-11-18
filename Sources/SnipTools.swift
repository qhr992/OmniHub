import AppKit

/// Toolbar button for an annotation tool: the chosen tool sits on an accent
/// plate with a white icon; hovering shows a faint plate.
final class ToolButton: NSButton {
    var isChosen = false { didSet { updatePlate() } }
    private var isHovered = false { didSet { updatePlate() } }

    private func updatePlate() {
        wantsLayer = true
        layer?.cornerRadius = 6
        let plate: NSColor = isChosen ? NSColor.controlAccentColor.withAlphaComponent(0.9)
            : isHovered ? NSColor.labelColor.withAlphaComponent(0.12) : .clear
        layer?.backgroundColor = plate.cgColor
        contentTintColor = isChosen ? .white : .labelColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

/// The pointer over the overlay tells which tool a drag will use.
enum SnipCursor {
    private static var cache: [AnnotationTool: NSCursor] = [:]

    static func cursor(for tool: AnnotationTool) -> NSCursor {
        if tool == .text { return .iBeam }
        if let cursor = cache[tool] { return cursor }
        let cursor = NSCursor(image: image(for: tool), hotSpot: NSPoint(x: 9, y: 9))
        cache[tool] = cursor
        return cursor
    }

    /// A crosshair (hot spot at 9,9) with the tool's icon on a small plate.
    private static func image(for tool: AnnotationTool) -> NSImage {
        let badge = badgeImage(for: tool)
        return NSImage(size: NSSize(width: 32, height: 32), flipped: true) { _ in
            let center = NSPoint(x: 9, y: 9)
            for (width, color) in [(CGFloat(3), NSColor.white), (CGFloat(1), NSColor.black)] {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: center.x - 8, y: center.y)); path.line(to: NSPoint(x: center.x + 8, y: center.y))
                path.move(to: NSPoint(x: center.x, y: center.y - 8)); path.line(to: NSPoint(x: center.x, y: center.y + 8))
                path.lineWidth = width
                color.setStroke()
                path.stroke()
            }
            let plate = NSRect(x: 15, y: 15, width: 16, height: 16)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: plate, xRadius: 4, yRadius: 4).fill()
            NSColor.black.withAlphaComponent(0.35).setStroke()
            NSBezierPath(roundedRect: plate.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4).stroke()
            badge.draw(in: plate.insetBy(dx: 2.5, dy: 2.5))
            return true
        }
    }

    private static func badgeImage(for tool: AnnotationTool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: tool.title)?
                .withSymbolConfiguration(config) else { return NSImage() }
        let size = NSSize(width: 11, height: 11)
        return NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.black.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
