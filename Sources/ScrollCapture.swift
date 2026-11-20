import AppKit
import CoreGraphics
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import ScreenCaptureKit
import CoreMedia

// MARK: - Frame acquisition

enum FrameGrabber {
    /// What the capture reads: the part of the region on the display that
    /// holds most of it, at that display's native pixels.
    struct Target {
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
        /// Width of the sampled rectangle in points.
        let pointWidth: CGFloat
    }

    /// `region` is in global points (top-left origin).
    static func target(for region: CGRect, among displays: [SCDisplay]) -> Target? {
        var best: (display: SCDisplay, bounds: CGRect, area: CGFloat)?
        for display in displays {
            let bounds = CGDisplayBounds(display.displayID)
            let inter = bounds.intersection(region)
            guard !inter.isNull else { continue }
            let area = inter.width * inter.height
            if area > (best?.area ?? 0) { best = (display, bounds, area) }
        }
        guard let best else { return nil }
        let inter = best.bounds.intersection(region)
        let local = CGRect(x: inter.minX - best.bounds.minX,
                           y: inter.minY - best.bounds.minY,
                           width: inter.width, height: inter.height)
        return Target(filter: SCContentFilter(display: best.display, excludingWindows: []),
                      configuration: ScreenCapture.configuration(for: best.display, localRect: local),
                      pointWidth: local.width)
    }

    /// An image of the region as raw RGBA rows at native pixel resolution.
    static func frame(from image: CGImage, pointWidth: CGFloat) -> (frame: ScrollFrame, scale: CGFloat)? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &buffer,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (ScrollFrame(width: width, height: height, rgba: buffer),
                CGFloat(width) / max(pointWidth, 1))
    }
}

/// Live frames of the region while the user scrolls. A ScreenCaptureKit
/// screenshot takes 20–45 ms, too slow to keep up with a fast flick; the
/// stream pushes every change (up to 60 a second) and a sample just takes
/// the newest one.
final class RegionStream: NSObject, SCStreamOutput, SCStreamDelegate {
    private static let maxFramesPerSecond: Int32 = 60
    /// Frames ScreenCaptureKit may have in flight; one is held as `latest`.
    private static let queueDepth = 5

    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var stream: SCStream?
    private let frames = DispatchQueue(label: "omnihub.scrollcapture.frames", qos: .userInitiated)

    /// `done(true)` once frames flow (on an arbitrary queue).
    func start(_ target: FrameGrabber.Target, done: @escaping (Bool) -> Void) {
        let config = target.configuration
        config.minimumFrameInterval = CMTime(value: 1, timescale: Self.maxFramesPerSecond)
        config.queueDepth = Self.queueDepth
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let stream = SCStream(filter: target.filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frames)
        } catch {
            done(false)
            return
        }
        self.stream = stream
        stream.startCapture { error in done(error == nil) }
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
        lock.lock()
        latest = nil
        lock.unlock()
    }

    /// The newest frame, nil until the first one arrives. Its bytes are
    /// taken as device RGB, exactly like a screenshot of the same pixels
    /// (VTCreateCGImageFromCVPixelBuffer colour-converts and would not match).
    func latestImage() -> CGImage? {
        lock.lock()
        let buffer = latest
        lock.unlock()
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let height = CVPixelBufferGetHeight(buffer)
        let perRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let provider = CGDataProvider(data: Data(bytes: base, count: perRow * height) as CFData) else { return nil }
        let bgra = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        return CGImage(width: CVPixelBufferGetWidth(buffer), height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: perRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bgra,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Only complete frames carry pixels; idle ones mean "nothing changed".
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = sampleBuffer.imageBuffer else { return }
        lock.lock()
        latest = buffer
        lock.unlock()
    }
}

// MARK: - Interactive controller

/// Scrolling ("long") screenshot: samples the selected region many times a
/// second and stitches new content while the user scrolls the page.
final class ScrollCaptureController {
    private let region: CGRect
    private let stitcher = ScrollStitcher()
    private var timer: Timer?
    /// Set once the display is known (ScreenCaptureKit lists it asynchronously).
    private var target: FrameGrabber.Target?
    private var frames: RegionStream?
    private var finished = false
    private var scale: CGFloat = 2
    private var hud: ScrollHUD?
    private var border: RegionBorderWindow?
    /// Esc is registered as a global hotkey only while capturing: the app is
    /// not frontmost here (the user is scrolling another app), so a local key
    /// monitor would never see it.
    private var escapeHotKey: HotKey?
    /// ↑ / ↓ scroll the page under the region while capturing.
    private(set) var keyScroller: KeyScroller?

    /// Sampling has to outrun the scroll: two consecutive frames must still
    /// overlap, and a trackpad flick moves thousands of points per second.
    private let pollInterval: TimeInterval = 0.05
    /// Grabbing and stitching run here so the main thread stays responsive.
    private let work = DispatchQueue(label: "omnihub.scrollcapture", qos: .userInitiated)
    private var busy = false
    private var gotFirstFrame = false
    private var gotScroll = false
    private var lastProgress = Date()

    /// Test hook: rows stitched so far (read from the main thread; approximate).
    var debugStitchedHeight: Int { stitcher.height }

    /// Test hook: receive the result instead of the clipboard.
    var onResult: ((CGImage?, CGFloat, Int) -> Void)?

    init(region: CGRect) {
        // Whole points keep every frame the same pixel size.
        self.region = region.integral
    }

    func start() {
        border = RegionBorderWindow(region: region)
        border?.orderFrontRegardless()
        hud = ScrollHUD { [weak self] in self?.finish() }
        hud?.show(near: region)
        escapeHotKey = HotKey(keyCode: UInt32(kVK_Escape), carbonModifiers: 0) { [weak self] in
            self?.finish()
        }
        let keys = KeyScroller(region: region)
        keys.start()
        keyScroller = keys

        // Let the selection overlay disappear from the screen first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            ScreenCapture.shareableDisplays { displays in
                DispatchQueue.main.async { self?.begin(on: displays ?? []) }
            }
        }
    }

    /// Starts sampling once ScreenCaptureKit has listed the displays.
    private func begin(on displays: [SCDisplay]) {
        guard !finished else { return }
        guard let target = FrameGrabber.target(for: region, among: displays) else {
            finish()
            return
        }
        self.target = target
        let frames = RegionStream()
        self.frames = frames
        frames.start(target) { started in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.finished else { frames.stop(); return }
                guard started else { self.finish(); return }
                self.lastProgress = Date()
                let timer = Timer(timeInterval: self.pollInterval, repeats: true) { [weak self] _ in self?.tick() }
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
                self.tick()
            }
        }
    }

    private func tick() {
        guard !finished, !busy, let target, let frames else { return }
        busy = true
        work.async { [weak self] in
            guard let self else { return }
            var added = 0
            var total = 0
            var grabbedScale: CGFloat?
            if let image = frames.latestImage(),
               let grabbed = FrameGrabber.frame(from: image, pointWidth: target.pointWidth) {
                added = self.stitcher.append(grabbed.frame)
                total = self.stitcher.height
                grabbedScale = grabbed.scale
            }
            let full = self.stitcher.isFull
            DispatchQueue.main.async {
                self.busy = false
                guard !self.finished, let grabbedScale else { return }
                self.scale = grabbedScale
                self.frameProcessed(added: added, total: total, full: full)
            }
        }
    }

    private func frameProcessed(added: Int, total: Int, full: Bool) {
        hud?.update(pixels: Int(CGFloat(total) / scale))
        let now = Date()

        if !gotFirstFrame {
            gotFirstFrame = true
            lastProgress = now
        } else if added > 0 {
            gotScroll = true
            lastProgress = now
        }
        if full { finish(); return }

        // The user scrolls: wait patiently for the first scroll, then stop
        // after a few seconds of stillness (or on Esc / Done).
        let idle = now.timeIntervalSince(lastProgress)
        if idle >= (gotScroll ? 4.0 : 20.0) { finish() }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        timer = nil
        frames?.stop()
        frames = nil
        escapeHotKey = nil
        keyScroller?.stop()
        keyScroller = nil
        hud?.orderOut(nil)
        hud = nil
        border?.orderOut(nil)
        border = nil

        // Runs after any frame that is still being stitched.
        work.async { [self] in
            let image = stitcher.makeImage()
            let gaps = stitcher.gaps
            let pixelSize = (stitcher.width, stitcher.height)
            DispatchQueue.main.async { self.deliver(image, gaps: gaps, pixelSize: pixelSize) }
        }
    }

    private func deliver(_ image: CGImage?, gaps: Int, pixelSize: (Int, Int)) {
        if let onResult {
            onResult(image, scale, gaps)
            return
        }
        defer { AppDelegate.shared?.snipDidEnd() }
        guard let image else {
            Toast.show("Scrolling screenshot failed: nothing captured")
            return
        }
        let size = NSSize(width: CGFloat(pixelSize.0) / scale, height: CGFloat(pixelSize.1) / scale)
        let nsImage = NSImage(cgImage: image, size: size)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])
        if let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            pasteboard.setData(png, forType: .png)
        }
        var message = "Scrolling screenshot copied (\(Int(size.width)) × \(Int(size.height)))"
        if gaps > 0 { message += " · \(gaps) fast scroll(s), content may be missing" }
        Toast.show(message, duration: gaps > 0 ? 3.5 : 2.0)
    }
}

// MARK: - Region border

/// Thin frame drawn just *outside* the captured region so it never lands in
/// a frame, and clicks/scrolls pass straight through it.
final class RegionBorderWindow: NSPanel {
    private static let thickness: CGFloat = 3

    init(region: CGRect) {
        let t = Self.thickness
        let outer = region.insetBy(dx: -t, dy: -t)
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let frame = NSRect(x: outer.minX, y: primaryHeight - outer.maxY,
                           width: outer.width, height: outer.height)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = BorderView(frame: NSRect(origin: .zero, size: frame.size))
        view.thickness = t
        contentView = view
    }

    private final class BorderView: NSView {
        var thickness: CGFloat = 3
        override func draw(_ dirtyRect: NSRect) {
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: bounds.insetBy(dx: thickness / 2, dy: thickness / 2))
            path.lineWidth = thickness
            path.stroke()
        }
    }
}

// MARK: - HUD

final class ScrollHUD: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Keeps the HUD out of the frames even if it has to overlap the region.
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.stringValue = baseText
        label.translatesAutoresizingMaskIntoConstraints = false

        let done = NSButton(title: "Done", target: self, action: #selector(finishTapped))
        done.bezelStyle = .rounded
        done.controlSize = .small
        done.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(label)
        effect.addSubview(done)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            done.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -10),
            done.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            done.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 10)
        ])
        contentView = effect
    }

    private let baseText = "Scrolling screenshot: scroll down or hold ↓"

    @objc private func finishTapped() { onFinish() }

    /// Sits outside the region: above it when there is room, otherwise below.
    func show(near region: CGRect) {
        guard let screen = ScreenGeometry.screen(containing: CGPoint(x: region.midX, y: region.midY))
        else { return }
        let top = ScreenGeometry.appKitPoint(fromCG: CGPoint(x: region.midX, y: region.minY), on: screen)
        let bottom = ScreenGeometry.appKitPoint(fromCG: CGPoint(x: region.midX, y: region.maxY), on: screen)
        let visible = screen.visibleFrame
        let gap: CGFloat = 12

        var y = top.y + gap                                   // above the region
        if y + frame.height > visible.maxY {
            y = bottom.y - gap - frame.height                 // below it
            if y < visible.minY { y = visible.maxY - frame.height - 4 }   // no room: overlap the top
        }
        var x = top.x - frame.width / 2
        x = max(visible.minX + 4, min(x, visible.maxX - frame.width - 4))
        setFrameOrigin(NSPoint(x: x, y: y))
        orderFrontRegardless()
    }

    func update(pixels: Int) {
        label.stringValue = "\(baseText) · \(pixels) px · Esc to finish"
    }
}
