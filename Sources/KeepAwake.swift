import AppKit
import IOKit.pwr_mgt

extension Notification.Name {
    static let keepAwakeChanged = Notification.Name("omnihub.keepAwakeChanged")
}

/// Display Sleep: on (the display sleeps as macOS decides), or off for a
/// while or until turned back on. Off is a power assertion held by this
/// process: it ends with it, so the state is never stored. `isOn` is true
/// while the display is kept awake, i.e. while Display Sleep is off.
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
                Toast.show("Could not turn display sleep off", duration: 2)
                return
            }
        }
        timer?.invalidate()
        timer = nil
        if seconds > 0 {
            until = Date().addingTimeInterval(seconds)
            let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
                self?.turnOff()
                Toast.show("Display sleep is back on", duration: 2)
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

    /// Its name wherever it is offered.
    static var name: String { L("Display Sleep") }

    /// A way of turning Display Sleep off.
    static func title(minutes: Int) -> String {
        switch minutes {
        case 0: return L("Off Until Turned On")
        case 60: return L("Off for 1 Hour")
        case 120: return L("Off for 2 Hours")
        default: return L("Off for %ld Minutes", minutes)
        }
    }

    /// "On", "Off until turned on", "Off, back on in 42 min".
    var statusText: String {
        guard let until else { return L("On") }
        if until == .distantFuture { return L("Off until turned on") }
        return L("Off, back on in %ld min", minutesLeft(until))
    }

    /// One line for Home and the status icon: "Display Sleep" while on, else
    /// "Display Sleep Off" / "Display sleep back in 42 min".
    var summary: String {
        guard let until else { return Self.name }
        if until == .distantFuture { return L("Display Sleep Off") }
        return L("Display sleep back in %ld min", minutesLeft(until))
    }

    private func minutesLeft(_ until: Date) -> Int {
        max(1, Int((until.timeIntervalSinceNow / 60).rounded(.up)))
    }

    /// A submenu: On, then the ways of turning it off; the current one is ticked.
    func menu(target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu()
        let on = NSMenuItem(title: L("On"), action: action, keyEquivalent: "")
        on.target = target
        on.tag = -1
        on.state = isOn ? .off : .on
        menu.addItem(on)
        menu.addItem(.separator())
        for minutes in Self.choices {
            let item = NSMenuItem(title: Self.title(minutes: minutes), action: action, keyEquivalent: "")
            item.target = target
            item.tag = minutes
            item.state = isOn && chosenMinutes == minutes ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
}
