import AppKit

/// Which edges of the screenshot frame a drag moves. A corner moves two.
struct SelectionHandle: OptionSet, Hashable {
    let rawValue: Int
    static let left = SelectionHandle(rawValue: 1)
    static let right = SelectionHandle(rawValue: 2)
    static let top = SelectionHandle(rawValue: 4)
    static let bottom = SelectionHandle(rawValue: 8)
}

/// Geometry for adjusting a finished selection before it is confirmed.
/// Coordinates are the CG global space (origin top-left, y down).
enum SelectionEdit {
    /// How far from an edge (in points, either side) a press still grabs it.
    static let grabTolerance: CGFloat = 6
    /// A frame smaller than this after a resize is rejected.
    static let minimumSide: CGFloat = 4

    /// The edges under `point`, or nil when the press is not on the frame.
    static func handle(at point: CGPoint, in rect: CGRect,
                       tolerance: CGFloat = grabTolerance) -> SelectionHandle? {
        let grab = rect.insetBy(dx: -tolerance, dy: -tolerance)
        guard grab.contains(point) else { return nil }
        var handle: SelectionHandle = []
        if abs(point.x - rect.minX) <= tolerance { handle.insert(.left) }
        else if abs(point.x - rect.maxX) <= tolerance { handle.insert(.right) }
        if abs(point.y - rect.minY) <= tolerance { handle.insert(.top) }
        else if abs(point.y - rect.maxY) <= tolerance { handle.insert(.bottom) }
        return handle.isEmpty ? nil : handle
    }

    /// `original` with the grabbed edges moved to `point`. Dragging an edge
    /// past the opposite one flips the frame instead of inverting it.
    static func resize(_ original: CGRect, handle: SelectionHandle, to point: CGPoint) -> CGRect {
        let x1 = handle.contains(.left) ? point.x : original.minX
        let x2 = handle.contains(.right) ? point.x : original.maxX
        let y1 = handle.contains(.top) ? point.y : original.minY
        let y2 = handle.contains(.bottom) ? point.y : original.maxY
        return CGRect(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
    }

    /// What the pointer shows over the overlay once a region is selected.
    enum Pointer: Equatable {
        case resize(SelectionHandle)
        /// No tool chosen: a drag inside moves the frame.
        case move
        case tool(AnnotationTool)
        case arrow
    }

    static func pointer(at point: CGPoint, selection: CGRect?, tool: AnnotationTool?) -> Pointer {
        guard let selection else { return .arrow }
        if let handle = handle(at: point, in: selection) { return .resize(handle) }
        guard selection.contains(point) else { return .arrow }
        return tool.map(Pointer.tool) ?? .move
    }

    /// `original` shifted by `delta`, kept whole inside `bounds` (the screens).
    static func move(_ original: CGRect, by delta: CGSize, within bounds: CGRect) -> CGRect {
        var moved = original.offsetBy(dx: delta.width, dy: delta.height)
        moved.origin.x = min(max(moved.minX, bounds.minX), bounds.maxX - moved.width)
        moved.origin.y = min(max(moved.minY, bounds.minY), bounds.maxY - moved.height)
        return moved
    }

    static func isUsable(_ rect: CGRect) -> Bool {
        rect.width >= minimumSide && rect.height >= minimumSide
    }

    /// The eight grab squares drawn on the frame: corners and edge midpoints.
    static func handlePoints(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)]
    }

    static func cursor(for handle: SelectionHandle) -> NSCursor {
        let horizontal = handle.contains(.left) || handle.contains(.right)
        let vertical = handle.contains(.top) || handle.contains(.bottom)
        if horizontal && vertical {
            if #available(macOS 15.0, *) {
                let position: NSCursor.FrameResizePosition
                switch (handle.contains(.left), handle.contains(.top)) {
                case (true, true): position = .topLeft
                case (false, true): position = .topRight
                case (true, false): position = .bottomLeft
                case (false, false): position = .bottomRight
                }
                return NSCursor.frameResize(position: position, directions: .all)
            }
            return .crosshair
        }
        return horizontal ? .resizeLeftRight : .resizeUpDown
    }
}
