import AppKit
import AVFoundation
import Carbon.HIToolbox

/// Shared character artwork (Lan; Resources/character, made in Tools/boot-film).
/// Every accessor returns nil when the media was not bundled.
enum Artwork {
    private static func url(_ name: String, _ ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext)
    }

    static let avatar: NSImage? = url("Avatar", "png").flatMap { NSImage(contentsOf: $0) }
    static let background: NSImage? = url("Background", "jpg").flatMap { NSImage(contentsOf: $0) }
    static var bootVideo: URL? { url("BootAnimation", "mp4") }
}

/// Start-up animation: the Lan film played once in a rounded window
/// in the middle of the screen, then faded away. Click skips it.
/// An ordinary window: it opens in front once, like any app at launch, and
/// other windows can cover it. It never takes keyboard focus or keys.
final class BootAnimation {
    private static var current: BootAnimation?

    private var window: NSPanel?
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var safety: Timer?
    private var finishing = false
    private(set) static var lastOutcome = "never run"

    /// Plays unless disabled in settings (`force` = the settings preview).
    static func playIfEnabled(force: Bool = false) {
        guard force || Prefs.bool("boot.enabled", true) else { lastOutcome = "disabled"; return }
        guard current == nil else { return }
        guard let url = Artwork.bootVideo else { lastOutcome = "no video bundled"; return }
        let animation = BootAnimation()
        current = animation
        animation.show(url)
    }

    private func show(_ url: URL) {
        let screen = NSScreen.underMouse ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let width = min(960, visible.width * 0.7, visible.height * 0.7 * 16 / 9)
        let height = width * 9 / 16
        let rect = NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)

        let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .normal
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.managed]
        panel.isReleasedWhenClosed = false

        let view = SkipView(frame: NSRect(origin: .zero, size: rect.size))
        view.onSkip = { [weak self] in self?.finish(fast: true) }
        view.wantsLayer = true
        view.layer?.cornerRadius = 20
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = NSColor(srgbRed: 0.863, green: 0.906, blue: 0.898, alpha: 1).cgColor  // the film's mist #DCE7E5

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.volume = Prefs.bool("boot.sound", true) ? 0.6 : 0
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)

        let hint = NSTextField(labelWithString: "Click to skip")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor(srgbRed: 0.12, green: 0.2, blue: 0.21, alpha: 0.5)
        hint.sizeToFit()
        hint.frame.origin = NSPoint(x: rect.width - hint.frame.width - 16, y: 12)
        view.addSubview(hint)

        panel.contentView = view
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.35; panel.animator().alphaValue = 1 }

        window = panel
        self.player = player

        let center = NotificationCenter.default
        endObserver = center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Self.lastOutcome = "played to end"
            self?.finish(fast: false)
        }
        failObserver = center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Self.lastOutcome = "playback failed"
            self?.finish(fast: true)
        }
        // Never leave a stuck window behind if the media pipeline stalls.
        safety = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            Self.lastOutcome = "timed out"
            self?.finish(fast: true)
        }
        Self.lastOutcome = "playing"
        player.play()
    }

    private func finish(fast: Bool) {
        guard !finishing else { return }
        finishing = true
        if Self.lastOutcome == "playing" { Self.lastOutcome = "skipped" }
        safety?.invalidate()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        let panel = window
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fast ? 0.2 : 0.6
            panel?.animator().alphaValue = 0
        }, completionHandler: {
            self.player?.pause()
            self.player = nil
            panel?.orderOut(nil)
            self.window = nil
            BootAnimation.current = nil
        })
    }

    private final class SkipView: NSView {
        var onSkip: (() -> Void)?
        override func mouseDown(with event: NSEvent) { onSkip?() }
    }
}
