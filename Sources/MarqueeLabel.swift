import AppKit

/// Single-line label that scrolls sideways when the text does not fit:
/// rests at the start, glides to reveal the end, rests, then starts over.
/// A new line can roll in from below (`roll(to:)`).
final class MarqueeLabel: NSView {
    private let textLayer = CATextLayer()
    private var textWidth: CGFloat = 0

    var font = NSFont.systemFont(ofSize: 12, weight: .medium) { didSet { rebuild() } }
    var textColor = NSColor.white { didSet { rebuild() } }

    var text = "" {
        didSet { if oldValue != text { rebuild() } }
    }

    /// How long a line takes to roll in: slow, like a lyrics view.
    static let rollDuration: CFTimeInterval = 1.2
    /// Lines rolled in so far (diagnostics).
    private(set) var rolls = 0

    /// Shows `next` rolling up from below while the current line drifts up
    /// and fades (a crossfade with Reduce Motion).
    func roll(to next: String) {
        guard next != text else { return }
        guard window != nil, bounds.height > 0, !text.isEmpty else {
            text = next
            return
        }
        let outgoing = CATextLayer()
        outgoing.string = textLayer.string
        outgoing.contentsScale = textLayer.contentsScale
        outgoing.anchorPoint = .zero
        outgoing.bounds = textLayer.bounds
        outgoing.position = textLayer.presentation()?.position ?? textLayer.position
        outgoing.truncationMode = .none
        layer?.addSublayer(outgoing)
        text = next
        rolls += 1

        let reduce = MainWindowMotion.reduceMotion
        let lift = reduce ? 0 : bounds.height
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { outgoing.removeFromSuperlayer() }
        let away = CABasicAnimation(keyPath: "transform.translation.y")
        away.fromValue = 0
        away.toValue = lift
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1
        fadeOut.toValue = 0
        let leave = CAAnimationGroup()
        leave.animations = [away, fadeOut]
        leave.duration = reduce ? 0.3 : Self.rollDuration
        leave.timingFunction = ease
        leave.fillMode = .forwards
        leave.isRemovedOnCompletion = false
        outgoing.add(leave, forKey: "roll")

        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -lift
        rise.toValue = 0
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        let arrive = CAAnimationGroup()
        arrive.animations = [rise, fadeIn]
        arrive.duration = reduce ? 0.3 : Self.rollDuration
        arrive.timingFunction = ease
        textLayer.add(arrive, forKey: "roll")
        CATransaction.commit()
    }

    /// Points the text overflows by (0 when it fits) — diagnostics.
    var overflow: CGFloat { max(0, textWidth - bounds.width) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        textLayer.anchorPoint = .zero
        textLayer.truncationMode = .none
        textLayer.isWrapped = false
        layer?.addSublayer(textLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { rebuild() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        textLayer.contentsScale = window?.backingScaleFactor ?? 2
        rebuild()
    }

    private func rebuild() {
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: textColor])
        let size = attributed.size()
        textWidth = ceil(size.width)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.removeAnimation(forKey: "marquee")
        textLayer.string = attributed
        textLayer.contentsScale = window?.backingScaleFactor ?? 2
        textLayer.bounds = CGRect(x: 0, y: 0, width: textWidth, height: ceil(size.height))
        let y = (bounds.height - ceil(size.height)) / 2
        let overflow = textWidth - bounds.width
        // Short text is centred; long text starts flush left.
        textLayer.position = CGPoint(x: overflow > 0 ? 0 : (bounds.width - textWidth) / 2, y: y)
        CATransaction.commit()

        guard overflow > 0, window != nil, bounds.width > 0 else { return }
        // Lyric lines only last a few seconds, so the glide is brisk; it
        // waits for the line to finish rolling in.
        let travel = Double(overflow) / 45          // 45 pt per second
        let hold = 0.8 + Self.rollDuration
        let total = hold + travel + hold
        let animation = CAKeyframeAnimation(keyPath: "position.x")
        animation.values = [0, 0, -overflow, -overflow]
        animation.keyTimes = [0, NSNumber(value: hold / total), NSNumber(value: (hold + travel) / total), 1]
        animation.duration = total
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        textLayer.add(animation, forKey: "marquee")
    }
}
