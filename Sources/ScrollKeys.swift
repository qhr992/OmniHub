import AppKit
import Carbon.HIToolbox

/// ↑ / ↓ during a scrolling screenshot: scrolls the page under the region
/// without the pointer having to be there — one step per press, a slow
/// steady scroll while the key is held. The keys are taken only while the
/// capture runs (like Esc) and given back when it ends.
///
/// Each scroll is posted at the session level with its location set to the
/// middle of the region, so the window there scrolls wherever the pointer
/// is (posting needs Accessibility, which OmniHub already uses). Posting to
/// an app's pid or through the HID tap does not work: the first is dropped
/// for scroll events, the second goes to the window under the real pointer.
final class KeyScroller {
    /// One press scrolls this far (points).
    static let stepPoints: CGFloat = 40
    /// Held longer than this, the key starts a steady scroll…
    static let holdDelay: TimeInterval = 0.3
    /// …of `holdPoints` every `holdTick`: about 360 points a second, slow
    /// enough for every frame to overlap the previous one.
    static let holdTick: TimeInterval = 1.0 / 60
    static let holdPoints: CGFloat = 6

    private let region: CGRect                // CG global points, top-left origin
    private var keys: [HotKey] = []
    private var holdTimer: Timer?
    private var holding: CGFloat = 0          // +1 down, -1 up, 0 none
    private(set) var stepsSent = 0

    init(region: CGRect) {
        self.region = region
    }

    func start() {
        for (code, direction) in [(kVK_DownArrow, CGFloat(1)), (kVK_UpArrow, CGFloat(-1))] {
            if let key = HotKey(keyCode: UInt32(code), carbonModifiers: 0,
                                action: { [weak self] in self?.press(direction) },
                                onRelease: { [weak self] in self?.release(direction) }) {
                keys.append(key)
            }
        }
    }

    func stop() {
        keys = []
        holdTimer?.invalidate()
        holdTimer = nil
        holding = 0
    }

    /// `direction` +1 scrolls the page down (content moves up), -1 up.
    func press(_ direction: CGFloat) {
        if holding == direction, holdTimer != nil { return }      // a key repeat
        holdTimer?.invalidate()
        holding = direction
        scroll(by: direction * Self.stepPoints)
        let timer = Timer(fire: Date().addingTimeInterval(Self.holdDelay), interval: Self.holdTick,
                          repeats: true) { [weak self] _ in
            guard let self, self.holding != 0 else { return }
            self.scroll(by: self.holding * Self.holdPoints)
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    func release(_ direction: CGFloat) {
        guard holding == direction else { return }
        holdTimer?.invalidate()
        holdTimer = nil
        holding = 0
    }

    private func scroll(by points: CGFloat) {
        let center = CGPoint(x: region.midX, y: region.midY)
        // Pixel units: a positive value scrolls toward the top, so "down" is negative.
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: Int32((-points).rounded()), wheel2: 0, wheel3: 0) else { return }
        event.location = center
        event.post(tap: .cgSessionEventTap)
        stepsSent += 1
    }
}
