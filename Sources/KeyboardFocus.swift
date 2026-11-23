import AppKit

/// Tab / ⇧Tab inside the dock card.
///
/// The card is built in code, so AppKit has no key-view loop for it and Tab
/// went nowhere (a text field's editor even keeps the Tab when there is no
/// next key view). The panel catches Tab itself, and `TabOrder` walks the
/// views of the panel the focus is in — a page, or a panel opened on top of
/// it (terminal settings, a drop-down) — in layout order, to the next
/// control that takes the keyboard.
/// (`nextKeyView` links are not used: AppKit fills them in by itself when a
/// window first shows, in an order that has nothing to do with the layout.)
///
/// Settings controls (check boxes, pop-ups, sliders, buttons) take the focus
/// whether or not macOS "Keyboard navigation" is on, so Tab reaches every
/// setting, and Space / the arrow keys change it.

/// A panel shown over a page: Tab stays inside it while the focus is there.
protocol TabScope: NSView {}

enum TabOrder {
    /// The control to focus after (or before) `current`, nil when there is none.
    static func next(after current: NSView, backwards: Bool) -> NSView? {
        guard let scope = scope(of: current) else { return nil }
        let stops = stops(in: scope)
        guard !stops.isEmpty else { return nil }
        guard let index = stops.firstIndex(where: { $0 === current || current.isDescendant(of: $0) }) else {
            return backwards ? stops.last : stops.first
        }
        let step = backwards ? stops.count - 1 : 1
        return stops[(index + step) % stops.count]
    }

    /// The panel `view` belongs to: the nearest overlay, else the page.
    static func scope(of view: NSView) -> NSView? {
        var node: NSView? = view
        while let current = node {
            if current is TabScope || current is DockPage { return current }
            node = current.superview
        }
        return nil
    }

    /// Where Tab starts when nothing in the card has the keyboard yet: the
    /// overlay on top of the page if one is open, else the page.
    static func topScope(in page: NSView) -> NSView {
        var top: NSView = page
        func visit(_ view: NSView) {
            for child in view.subviews where !child.isHidden {
                if child is TabScope { top = child }
                visit(child)
            }
        }
        visit(page)
        return top
    }

    /// Every control of `scope` that takes the keyboard, in layout order:
    /// stacks in their arranged order, other views in the order they were
    /// added. Overlays inside the scope are left out.
    static func stops(in scope: NSView) -> [NSView] {
        var result: [NSView] = []
        func visit(_ view: NSView) {
            guard !view.isHidden else { return }
            if view !== scope, view is TabScope { return }
            if isStop(view) { result.append(view) }
            if view is NSControl || view is NSTableView || view is NSTextView { return }
            var children = view.subviews
            if let stack = view as? NSStackView {
                let arranged = stack.arrangedSubviews
                children = arranged + children.filter { child in !arranged.contains { $0 === child } }
            }
            children.forEach(visit)
        }
        visit(scope)
        return result
    }

    static func isStop(_ view: NSView) -> Bool {
        guard view.window != nil, !view.isHiddenOrHasHiddenAncestor,
              view.bounds.width > 0, view.bounds.height > 0 else { return false }
        if view is NSTextView { return false }                         // the shell gets its own Tab
        if view is NSScrollView || view is NSClipView || view is NSScroller { return false }
        if let control = view as? NSControl, !control.isEnabled { return false }
        // A field being edited (a combo box at least) says it takes no
        // keyboard while its editor has it: editable is what counts.
        if let field = view as? NSTextField { return field.isEditable }
        return view.acceptsFirstResponder
    }
}

// MARK: - Controls that take Tab focus without "Keyboard navigation"

/// Keys that work a focused control (AppKit only wires them up when macOS
/// "Keyboard navigation" is on).
enum FocusKeys {
    /// Return, Enter or Space presses a button / opens a pop-up.
    static func presses(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            && [36, 76, 49].contains(event.keyCode)
    }

    /// ← / ↓ = -1, → / ↑ = +1, else 0.
    static func arrow(_ event: NSEvent) -> Int {
        switch event.keyCode {
        case 123, 125: return -1
        case 124, 126: return 1
        default: return 0
        }
    }
}

/// A button (or check box) that Tab can reach; Return, Enter or Space presses it.
class FocusButton: NSButton {
    override var canBecomeKeyView: Bool { isEnabled && !isHidden }
    override var acceptsFirstResponder: Bool { isEnabled }

    override func keyDown(with event: NSEvent) {
        if FocusKeys.presses(event) { performClick(nil) } else { super.keyDown(with: event) }
    }
}

/// A pop-up that Tab can reach; Return, Enter or Space opens it.
class FocusPopUp: NSPopUpButton {
    override var canBecomeKeyView: Bool { isEnabled && !isHidden }
    override var acceptsFirstResponder: Bool { isEnabled }

    override func keyDown(with event: NSEvent) {
        if FocusKeys.presses(event) { performClick(nil) } else { super.keyDown(with: event) }
    }
}

/// A slider that Tab can reach; the arrow keys move it in 2 % steps.
final class FocusSlider: NSSlider {
    private static let steps = 50.0

    override var canBecomeKeyView: Bool { isEnabled && !isHidden }
    override var acceptsFirstResponder: Bool { isEnabled }

    override func keyDown(with event: NSEvent) {
        let direction = FocusKeys.arrow(event)
        guard direction != 0 else { super.keyDown(with: event); return }
        let step = (maxValue - minValue) / Self.steps
        doubleValue = min(max(doubleValue + Double(direction) * step, minValue), maxValue)
        sendAction(action, to: target)
    }
}

/// A list that Tab can reach; the arrow keys move the selection.
final class FocusTable: NSTableView {
    override var acceptsFirstResponder: Bool { true }
}

/// A segmented control that Tab can reach; ← / → pick the neighbouring segment.
final class FocusSegments: NSSegmentedControl {
    override var canBecomeKeyView: Bool { isEnabled && !isHidden }
    override var acceptsFirstResponder: Bool { isEnabled }

    override func keyDown(with event: NSEvent) {
        let direction = FocusKeys.arrow(event)
        guard direction != 0, segmentCount > 0, [123, 124].contains(event.keyCode) else {
            super.keyDown(with: event)
            return
        }
        selectedSegment = (max(selectedSegment, 0) + direction + segmentCount) % segmentCount
        sendAction(action, to: target)
    }
}
