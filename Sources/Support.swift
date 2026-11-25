import AppKit

extension Notification.Name {
    static let tasksChanged = Notification.Name("omnihub.tasksChanged")
    static let mediaChanged = Notification.Name("omnihub.mediaChanged")
    static let clipboardChanged = Notification.Name("omnihub.clipboardChanged")
}

/// Panels summoned by a hotkey. Esc always dismisses them.
protocol EscDismissable: AnyObject {
    func dismissByEscape()
}

/// Remembers which app was frontmost before one of our panels took focus, so
/// closing the panel hands the keyboard straight back to it.
enum FocusKeeper {
    private static var previous: NSRunningApplication?

    static func activateSelf() {
        let own = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != own {
            previous = front
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Call after a panel was hidden. Does nothing while another of our
    /// panels is still open.
    static func restore() {
        // Pins and the dock are permanent fixtures, not "open panels".
        let stillOpen = NSApp.windows.contains {
            $0.isVisible && $0 is EscDismissable
                && !($0 is FloatingDockPanel) && !($0 is PinnedImageWindow)
        }
        guard !stillOpen, let app = previous, !app.isTerminated else { return }
        app.activate(options: [])
    }
}

/// Short self-dismissing confirmation ("Copied").
final class Toast: NSPanel {
    private static var current: Toast?

    static func show(_ text: String, duration: TimeInterval = 1.4) {
        current?.orderOut(nil)
        let toast = Toast(text: L(text))
        current = toast
        toast.alphaValue = 0
        toast.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; toast.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; toast.animator().alphaValue = 0 },
                                                 completionHandler: {
                toast.orderOut(nil)
                if current === toast { current = nil }
            })
        }
    }

    private init(text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 36, height: 36)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let box = NSView(frame: NSRect(origin: .zero, size: size))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        box.layer?.cornerRadius = 10
        label.frame.origin = NSPoint(x: 18, y: (size.height - label.frame.height) / 2)
        box.addSubview(label)
        contentView = box

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 90))
        }
    }
}

extension NSScreen {
    /// The screen the mouse is on — where a summoned panel should appear.
    static var underMouse: NSScreen? {
        screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? main ?? screens.first
    }
}

/// Quits and starts OmniHub again (after a language change).
enum AppRelaunch {
    static func now() {
        // A shell outlives us: it waits until this process is gone, then
        // opens the app again, so the new copy is not handed to the old one.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                          Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier)]
        do {
            try task.run()
        } catch {
            Toast.show(L("Could not restart: %@", error.localizedDescription), duration: 2.5)
            return
        }
        NSApp.terminate(nil)
    }
}

/// Self-tests share the app's preferences: whatever they switch is put back
/// as the user had it when the test process exits.
enum SelfTestPrefs {
    private static var saved: [String: Any]?

    static func keep() {
        guard saved == nil, let id = Bundle.main.bundleIdentifier else { return }
        saved = UserDefaults.standard.persistentDomain(forName: id) ?? [:]
        atexit { SelfTestPrefs.restore() }
    }

    private static func restore() {
        guard let saved, let id = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.setPersistentDomain(saved, forName: id)
        UserDefaults.standard.synchronize()
    }
}
