import AppKit

/// The main window's page changes, in transform and opacity only (the
/// layout itself changes at once; these are presentation animations over
/// it). Pages fade up; a Settings topic glides in from the right and the
/// list of topics drops back in. With Reduce Motion, a short crossfade.
enum MainWindowMotion {
    static let settingsDuration: CFTimeInterval = 0.42
    static let pageDuration: CFTimeInterval = 0.24
    /// How far the page travels as it arrives.
    static let travel: CGFloat = 36
    private static let easeOutExpo = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

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
