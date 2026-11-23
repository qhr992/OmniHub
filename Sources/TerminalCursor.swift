import AppKit

/// The terminal's block cursor, drawn as temporary attributes of the text
/// view's layout manager over one cell: the text is not touched and only
/// that cell is redrawn.
///
/// While the terminal has the keyboard the cursor breathes — it fades
/// smoothly between bright and faint, one cycle every `period` seconds.
/// Every output (typing echoes) starts a new cycle at full brightness, so it
/// stays solid while you type. Without the keyboard it rests as a dim block
/// that marks the place.
final class TerminalCursor {
    static let period: TimeInterval = 1.2
    static let brightest: CGFloat = 0.85
    static let faintest: CGFloat = 0.1
    static let resting: CGFloat = 0.35
    /// Above this opacity the glyph under the block is drawn dark.
    private static let inverseFrom: CGFloat = 0.45
    private static let tick: TimeInterval = 1.0 / 30

    /// Test hook: breathe although the window is not key (headless runs).
    static var debugAlwaysFocused = false

    private weak var textView: NSTextView?
    private(set) var range: NSRange?
    private var applied: NSRange?
    private var cycleStart = Date()
    private var timer: Timer?

    init(textView: NSTextView) {
        self.textView = textView
    }

    deinit { timer?.invalidate() }

    /// Opacity `elapsed` seconds into a cycle: brightest at the start,
    /// faintest half way, with a cosine ease in between.
    static func alpha(elapsed: TimeInterval) -> CGFloat {
        let phase = elapsed.truncatingRemainder(dividingBy: period) / period
        let wave = 0.5 + 0.5 * cos(2 * Double.pi * phase)
        return faintest + (brightest - faintest) * CGFloat(wave)
    }

    /// The text was redrawn and the cursor sits at `newRange` (nil: hidden).
    func move(to newRange: NSRange?) {
        // Edits shift temporary attributes along with the text: start clean.
        removeAll()
        range = newRange
        cycleStart = Date()
        update()
    }

    /// The view gained or lost the keyboard.
    func focusChanged() {
        cycleStart = Date()
        update()
    }

    var isFocused: Bool {
        guard let textView, let window = textView.window else { return false }
        return Self.debugAlwaysFocused || (window.isKeyWindow && window.firstResponder === textView)
    }

    /// The cursor cell's background as drawn now, in sRGB (test hook).
    var currentColor: NSColor? {
        guard let textView, let manager = textView.layoutManager, let range,
              range.upperBound <= (textView.textStorage?.length ?? 0) else { return nil }
        let value = manager.temporaryAttribute(.backgroundColor, atCharacterIndex: range.location, effectiveRange: nil)
        return (value as? NSColor)?.usingColorSpace(.sRGB)
    }

    private func update() {
        let breathing = isFocused && range != nil
        if breathing, timer == nil {
            let timer = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in self?.draw() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !breathing {
            timer?.invalidate()
            timer = nil
        }
        draw()
    }

    private func draw() {
        guard let textView, let manager = textView.layoutManager, let length = textView.textStorage?.length else { return }
        if let applied, applied != range, applied.upperBound <= length { remove(applied, from: manager) }
        applied = nil
        guard let range, range.upperBound <= length else { return }
        let alpha = isFocused ? Self.alpha(elapsed: Date().timeIntervalSince(cycleStart)) : Self.resting
        let colors = Self.colors(for: textView)
        manager.addTemporaryAttribute(.backgroundColor, value: colors.block.withAlphaComponent(alpha),
                                      forCharacterRange: range)
        if alpha > Self.inverseFrom {
            manager.addTemporaryAttribute(.foregroundColor, value: colors.glyph, forCharacterRange: range)
        } else {
            manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        }
        applied = range
    }

    private func remove(_ range: NSRange, from manager: NSLayoutManager) {
        manager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
    }

    private func removeAll() {
        guard let textView, let manager = textView.layoutManager, let length = textView.textStorage?.length,
              length > 0 else { return }
        remove(NSRange(location: 0, length: length), from: manager)
        applied = nil
    }

    /// Block and inverted-glyph colours for the appearance the terminal is
    /// drawn in (the card is always dark). A system colour turned into a
    /// fixed one outside drawing takes the app's appearance instead — light
    /// when macOS is in light mode — which gave a black block nobody could
    /// see on the dark card.
    private static func colors(for view: NSView) -> (block: NSColor, glyph: NSColor) {
        var block = NSColor.white
        var glyph = NSColor.black
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            block = NSColor.textColor.usingColorSpace(.sRGB) ?? .white
            glyph = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? .black
        }
        return (block, glyph)
    }
}
