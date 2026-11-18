import AppKit
import CoreGraphics
import ScreenCaptureKit

/// One captured display: the *whole* display at native pixel resolution.
///
/// Each display is captured whole, once, and cropped locally: every overlay
/// stays instant, and a selection can span displays without recapturing.
struct DisplayCapture {
    let displayID: CGDirectDisplayID
    /// Display bounds in the CoreGraphics global space (origin top-left, y down).
    let bounds: CGRect
    let image: CGImage

    /// Backing scale between points and pixels for this display.
    var scale: CGFloat {
        bounds.width > 0 ? CGFloat(image.width) / bounds.width : 1
    }
}

/// Screen pixels come from ScreenCaptureKit (`CGDisplayCreateImage` is
/// obsolete from macOS 15 on). Same Screen Recording permission as before.
enum ScreenCapture {
    /// A capture that never answers must not leave the screenshot hanging.
    static let captureTimeout: TimeInterval = 3

    static func isTrusted() -> Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestAccess() -> Bool { CGRequestScreenCaptureAccess() }

    static func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// Active displays as an ID list, one entry per display.
    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// The displays ScreenCaptureKit can read (nil without permission).
    static func shareableDisplays(_ done: @escaping ([SCDisplay]?) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
            done(content?.displays)
        }
    }

    /// Native pixels per point of a display (its current mode).
    static func pixelScale(of id: CGDirectDisplayID, pointWidth: Int) -> CGFloat {
        guard let mode = CGDisplayCopyDisplayMode(id), pointWidth > 0 else { return 1 }
        return CGFloat(mode.pixelWidth) / CGFloat(pointWidth)
    }

    /// Capture settings for a display, or for `localRect` (points, the
    /// display's top-left space) on it: native pixels, no pointer.
    static func configuration(for display: SCDisplay, localRect: CGRect? = nil) -> SCStreamConfiguration {
        let scale = pixelScale(of: display.displayID, pointWidth: display.width)
        let config = SCStreamConfiguration()
        let size = localRect?.size ?? CGSize(width: display.width, height: display.height)
        if let localRect { config.sourceRect = localRect }
        config.width = Int((size.width * scale).rounded())
        config.height = Int((size.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        return config
    }

    /// Captures every active display in one pass, before any overlay is shown
    /// (an overlay must never appear in the frame being captured). `done`
    /// runs on the main queue, in display order; empty when nothing could be
    /// captured.
    static func captureAllDisplays(_ done: @escaping ([DisplayCapture]) -> Void) {
        let order = activeDisplayIDs()
        shareableDisplays { displays in
            let displays = (displays ?? []).filter { order.contains($0.displayID) }
            guard !displays.isEmpty else { DispatchQueue.main.async { done([]) }; return }
            let group = DispatchGroup()
            let lock = NSLock()
            var captures: [DisplayCapture] = []
            for display in displays {
                group.enter()
                SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []),
                                                 configuration: configuration(for: display)) { image, _ in
                    defer { group.leave() }
                    let bounds = CGDisplayBounds(display.displayID)
                    guard let image, bounds.width > 0, bounds.height > 0 else { return }
                    lock.lock()
                    captures.append(DisplayCapture(displayID: display.displayID, bounds: bounds, image: image))
                    lock.unlock()
                }
            }
            var finished = false
            let finish = {
                guard !finished else { return }
                finished = true
                lock.lock()
                let sorted = captures.sorted {
                    (order.firstIndex(of: $0.displayID) ?? 0) < (order.firstIndex(of: $1.displayID) ?? 0)
                }
                lock.unlock()
                done(sorted)
            }
            group.notify(queue: .main, execute: finish)
            DispatchQueue.main.asyncAfter(deadline: .now() + captureTimeout, execute: finish)
        }
    }

    /// Crops one display capture to a rectangle expressed in that display's
    /// *local* top-left coordinate space (the global rect offset by the
    /// display's origin).
    static func crop(_ capture: DisplayCapture, localRect: CGRect) -> CGImage? {
        let s = capture.scale
        let pixelRect = CGRect(x: (localRect.minX * s).rounded(.down),
                               y: (localRect.minY * s).rounded(.down),
                               width: (localRect.width * s).rounded(.up),
                               height: (localRect.height * s).rounded(.up))
        let clamped = pixelRect.intersection(CGRect(x: 0, y: 0,
                                                    width: capture.image.width,
                                                    height: capture.image.height))
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return nil }
        return capture.image.cropping(to: clamped)
    }
}
