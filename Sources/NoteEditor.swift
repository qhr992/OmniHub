import AppKit

/// The Agenda's note box: one line when empty, growing with the text up to
/// `maxLines`, then scrolling with a visible scroller. Return runs
/// `onReturn` (Add / Save), Option-Return starts a new line, and Tab moves
/// on as in a text field.
final class NoteEditor: NSScrollView, NSTextViewDelegate {
    var onReturn: (() -> Void)?
    let textView = PlaceholderTextView()

    private static let lineHeight: CGFloat = 16
    private static let inset = NSSize(width: 3, height: 4)
    private let maxLines: Int
    private var height: NSLayoutConstraint!

    init(placeholder: String, maxLines: Int) {
        self.maxLines = maxLines
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        borderType = .bezelBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        // A scroller that stays put (not the overlay kind), so a long note
        // shows at once that there is more.
        scrollerStyle = .legacy
        drawsBackground = true
        backgroundColor = .textBackgroundColor

        textView.placeholder = placeholder
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = Self.inset
        textView.frame = NSRect(origin: .zero, size: contentSize)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: .greatestFiniteMagnitude)
        textView.typingAttributes = Self.attributes
        textView.delegate = self
        textView.setAccessibilityPlaceholderValue(placeholder)
        documentView = textView

        translatesAutoresizingMaskIntoConstraints = false
        height = heightAnchor.constraint(equalToConstant: Self.height(lines: 1))
        height.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A fixed line height: Chinese and Latin lines alike, so the box
    /// grows by whole lines.
    private static var attributes: [NSAttributedString.Key: Any] {
        let lines = NSMutableParagraphStyle()
        lines.minimumLineHeight = lineHeight
        lines.maximumLineHeight = lineHeight
        return [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.textColor, .paragraphStyle: lines]
    }

    private static func height(lines: Int) -> CGFloat { CGFloat(lines) * lineHeight + inset.height * 2 + 2 }

    var string: String {
        get { textView.string }
        set {
            textView.textStorage?.setAttributedString(NSAttributedString(string: newValue, attributes: Self.attributes))
            textView.typingAttributes = Self.attributes
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            fit()
            contentView.scroll(to: .zero)
            reflectScrolledClipView(contentView)
        }
    }

    private var fittedWidth: CGFloat = 0

    /// The box got wider or narrower: the text wraps anew, so its height
    /// follows.
    override func layout() {
        super.layout()
        let width = contentSize.width
        guard abs(width - fittedWidth) > 0.5 else { return }
        fittedWidth = width
        textView.frame.size.width = width
        fit()
    }

    /// Height for the text, up to `maxLines`.
    private func fit() {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
        let lines = max(1, min(maxLines, Int((used / Self.lineHeight).rounded(.up))))
        height.constant = Self.height(lines: lines)
        textView.needsDisplay = true
    }

    func textDidChange(_ notification: Notification) { fit() }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onReturn?()
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            textView.insertText("\n", replacementRange: textView.selectedRange())
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            let backwards = selector == #selector(NSResponder.insertBacktab(_:))
            // The card keeps its own Tab order; a window uses the key view loop.
            if let card = window as? FloatingDockPanel, card.moveFocus(from: textView, backwards: backwards) { break }
            if backwards { window?.selectKeyView(preceding: textView) } else { window?.selectKeyView(following: textView) }
        default:
            return false
        }
        return true
    }

    /// Test hook: the scroller is showing (the note is longer than the box).
    var debugScrollerShown: Bool { verticalScroller.map { !$0.isHidden && $0.knobProportion < 1 } ?? false }
}

/// A text view that shows a grey hint while it is empty.
final class PlaceholderTextView: NSTextView {
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let origin = textContainerOrigin
        let padding = textContainer?.lineFragmentPadding ?? 0
        (placeholder as NSString).draw(at: NSPoint(x: origin.x + padding, y: origin.y),
                                       withAttributes: [.font: NSFont.systemFont(ofSize: 12),
                                                        .foregroundColor: NSColor.placeholderTextColor])
    }
}
