import AppKit
import IOKit.pwr_mgt

extension Notification.Name {
    static let keepAwakeChanged = Notification.Name("omnihub.keepAwakeChanged")
}

/// Keeps the display from sleeping while idle, for a while or until turned
/// off. A power assertion held by this process: it ends with it, so the
/// state is never stored.
final class KeepAwake {
    static let shared = KeepAwake()

    /// Its sign wherever it is shown (status icon, Home).
    static let symbolName = "cup.and.saucer.fill"

    /// The choices offered, in minutes; 0 = until turned off.
    static let choices = [30, 60, 120, 0]

    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?
    /// When it turns itself off; `.distantFuture` = never.
    private(set) var until: Date?

    var isOn: Bool { until != nil }

    /// Starts (or restarts with a new length); `minutes` 0 = no end.
    func turnOn(minutes: Int) {
        turnOn(seconds: TimeInterval(minutes * 60))
    }

    /// `seconds` 0 = no end (test hook for short lengths).
    func turnOn(seconds: TimeInterval) {
        if assertion == 0 {
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "OmniHub: Keep Awake" as CFString, &assertion)
            guard result == kIOReturnSuccess else {
                assertion = 0
                Toast.show("Could not keep the Mac awake", duration: 2)
                return
            }
        }
        timer?.invalidate()
        timer = nil
        if seconds > 0 {
            until = Date().addingTimeInterval(seconds)
            let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
                self?.turnOff()
                Toast.show("Keep Awake ended", duration: 2)
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            until = .distantFuture
        }
        NotificationCenter.default.post(name: .keepAwakeChanged, object: nil)
    }

    func turnOff() {
        timer?.invalidate()
        timer = nil
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        guard until != nil else { return }
        until = nil
        NotificationCenter.default.post(name: .keepAwakeChanged, object: nil)
    }

    /// The minutes picked last time it was turned on (nil when off).
    private(set) var chosenMinutes: Int?

    /// Turns on for `minutes` from the menus, or off with nil.
    func choose(_ minutes: Int?) {
        chosenMinutes = minutes
        if let minutes { turnOn(minutes: minutes) } else { turnOff() }
    }

    static func title(minutes: Int) -> String {
        switch minutes {
        case 0: return L("Until Turned Off")
        case 60: return L("1 Hour")
        case 120: return L("2 Hours")
        default: return L("%ld Minutes", minutes)
        }
    }

    /// "Off", "Until turned off", "42 min left".
    var statusText: String {
        guard let until else { return L("Off") }
        if until == .distantFuture { return L("On until turned off") }
        let minutes = max(1, Int((until.timeIntervalSinceNow / 60).rounded(.up)))
        return L("%ld min left", minutes)
    }

    /// A submenu: the lengths, then Turn Off; the current one is ticked.
    func menu(target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu()
        for minutes in Self.choices {
            let item = NSMenuItem(title: Self.title(minutes: minutes), action: action, keyEquivalent: "")
            item.target = target
            item.tag = minutes
            item.state = isOn && chosenMinutes == minutes ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        // No action while off: menus grey it out.
        let off = NSMenuItem(title: L("Turn Off"), action: isOn ? action : nil, keyEquivalent: "")
        off.target = target
        off.tag = -1
        menu.addItem(off)
        return menu
    }
}
