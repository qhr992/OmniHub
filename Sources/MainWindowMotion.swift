import AppKit

/// The main window's page changes, in transform and opacity only (the
/// layout itself changes at once; these are presentation animations over
/// it). Settings slides the page list away and glides in from the right;
/// Back slides the list back and the page in from the left; other pages
/// fade up. With Reduce Motion, a short crossfade.
enum MainWindowMotion {
    enum Kind { case enterSettings, leaveSettings, switchPage }

    static let settingsDuration: CFTimeInterval = 0.42
    static let pageDuration: CFTimeInterval = 0.24
    /// How far the page travels as it arrives.
    static let travel: CGFloat = 36
    private static let easeOutExpo = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

    private static var slideGeneration = 0

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The arriving page: fades in while moving `dx` / `dy` points home.
    static func arrive(_ layer: CALayer?, dx: CGFloat, dy: CGFloat, duration: CFTimeInterval, delay: CFTimeInterval = 0) {
        guard let layer else { return }
        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = CATransform3DMakeTranslation(reduceMotion ? 0 : dx, reduceMotion ? 0 : dy, 0)
        move.toValue = CATransform3DIdentity
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        group(layer, [move, fade], duration: reduceMotion ? 0.16 : duration, delay: delay, key: "omnihub.arrive")
    }

    /// The page list leaving (to the left) or coming back. `done` runs when
    /// it has gone, before the animation is removed (no flash back).
    static func slideList(_ layers: [CALayer?], width: CGFloat, out: Bool, done: @escaping () -> Void) {
        let away = CATransform3DMakeTranslation(-width, 0, 0)
        // A newer slide replaces this one: only the latest may finish up.
        slideGeneration += 1
        let generation = slideGeneration
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            guard generation == slideGeneration else { return }
            done()
            for layer in layers { layer?.removeAnimation(forKey: "omnihub.slide") }
        }
        for layer in layers.compactMap({ $0 }) {
            let move = CABasicAnimation(keyPath: "transform")
            move.fromValue = out ? CATransform3DIdentity : (reduceMotion ? CATransform3DIdentity : away)
            move.toValue = out ? (reduceMotion ? CATransform3DIdentity : away) : CATransform3DIdentity
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = out ? 1 : 0.2
            fade.toValue = out ? 0 : 1
            let both = CAAnimationGroup()
            both.animations = [move, fade]
            both.duration = reduceMotion ? 0.16 : settingsDuration
            both.timingFunction = easeOutExpo
            both.fillMode = .forwards
            both.isRemovedOnCompletion = false
            layer.add(both, forKey: "omnihub.slide")
        }
        CATransaction.commit()
    }

    /// A text change as a crossfade.
    static func crossfade(_ layer: CALayer?, duration: CFTimeInterval = 0.22) {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = duration
        fade.timingFunction = easeOutExpo
        layer?.add(fade, forKey: "omnihub.text")
    }

    private static func group(_ layer: CALayer, _ animations: [CAAnimation], duration: CFTimeInterval,
                              delay: CFTimeInterval, key: String) {
        let both = CAAnimationGroup()
        both.animations = animations
        both.duration = duration
        both.timingFunction = easeOutExpo
        if delay > 0 {
            both.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
            both.fillMode = .backwards
        }
        layer.add(both, forKey: key)
    }
}
