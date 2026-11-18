import AppKit
import CoreGraphics

/// A candidate window for magnetic selection.
struct WindowCandidate {
    let ownerPID: pid_t
    let appName: String
    let title: String
    /// Window bounds in the CoreGraphics global space (origin top-left).
    let frame: CGRect
}

/// Window auto-detection: `CGWindowListCopyWindowInfo` filtered by
/// `kCGWindowOwnerPID` / `kCGWindowName`, with `NSRunningApplication` name
/// lookups.
enum WindowPicker {
    static func candidates() -> [WindowCandidate] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        var result: [WindowCandidate] = []

        // CGWindowListCopyWindowInfo is ordered front-to-back, so the first
        // match containing a point is the topmost window there.
        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != selfPID else { continue }

            // Layer 0 == ordinary application windows; excludes menu bar,
            // Dock, status items and floating system chrome.
            if let layer = info[kCGWindowLayer as String] as? Int, layer != 0 { continue }

            // Untitled windows are skipped.
            guard let title = info[kCGWindowName as String] as? String, !title.isEmpty else { continue }

            let appName = NSRunningApplication(processIdentifier: ownerPID)?.localizedName
                ?? (info[kCGWindowOwnerName as String] as? String)
                ?? ""

            // The Dock and the window server are skipped.
            if appName == "Dock" || appName == "Window Server" { continue }

            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            if frame.width < 8 || frame.height < 8 { continue }

            result.append(WindowCandidate(ownerPID: ownerPID,
                                          appName: appName,
                                          title: title,
                                          frame: frame))
        }
        return result
    }

    /// Topmost candidate containing a point in the CG global space.
    static func topmost(at point: CGPoint, in candidates: [WindowCandidate]) -> WindowCandidate? {
        candidates.first { $0.frame.contains(point) }
    }
}
