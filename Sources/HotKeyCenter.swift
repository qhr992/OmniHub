import AppKit
import Carbon.HIToolbox

/// A key plus Carbon modifier mask.
struct KeyCombo: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// "⇧⌘V"-style label.
    var display: String {
        var out = ""
        if modifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { out += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { out += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { out += "⌘" }
        return out + KeyCombo.keyName(keyCode)
    }

    var stored: String { "\(keyCode):\(modifiers)" }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(stored: String) {
        let parts = stored.split(separator: ":")
        guard parts.count == 2, let key = UInt32(parts[0]), let mods = UInt32(parts[1]) else { return nil }
        self.init(keyCode: key, modifiers: mods)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }

    private static let names: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Grave: "`", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_Space: L("Space"), kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
    ]

    static func keyName(_ keyCode: UInt32) -> String {
        names[Int(keyCode)] ?? "Key \(keyCode)"
    }

    static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
            .contains(Int(keyCode))
    }
}

/// Everything that can be bound to a global shortcut.
enum HotKeyAction: String, CaseIterable {
    case snip, pinClipboard, clipboard, terminal, tasks, activity, dock, playPause

    var title: String {
        switch self {
        case .snip: return L("Screenshot")
        case .pinClipboard: return L("Pin Clipboard Image")
        case .clipboard: return L("Clipboard")
        case .terminal: return L("Terminal")
        case .tasks: return L("Agenda")
        case .dock: return L("Show / Hide Dock")
        case .playPause: return L("Play / Pause")
        case .activity: return L("Activity")
        }
    }

    /// nil = no shortcut out of the box.
    var defaultCombo: KeyCombo? {
        let cmd = UInt32(cmdKey), shift = UInt32(shiftKey), ctrl = UInt32(controlKey)
        switch self {
        case .snip: return KeyCombo(keyCode: UInt32(kVK_ANSI_1), modifiers: cmd)
        case .pinClipboard: return KeyCombo(keyCode: UInt32(kVK_ANSI_2), modifiers: cmd | shift)
        case .clipboard: return KeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: cmd | shift)
        case .terminal: return KeyCombo(keyCode: UInt32(kVK_ANSI_Grave), modifiers: ctrl)
        case .tasks: return KeyCombo(keyCode: UInt32(kVK_ANSI_T), modifiers: cmd | shift)
        case .dock: return KeyCombo(keyCode: UInt32(kVK_ANSI_O), modifiers: cmd | shift)
        case .playPause: return KeyCombo(keyCode: UInt32(kVK_Space), modifiers: cmd | shift)
        case .activity: return KeyCombo(keyCode: UInt32(kVK_ANSI_A), modifiers: ctrl | UInt32(optionKey))
        }
    }

    fileprivate var prefKey: String { "hotkey.\(rawValue)" }
}

/// Owns the global shortcuts: persisted per action, re-registered on change.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [HotKeyAction: () -> Void] = [:]
    private var registered: [HotKeyAction: HotKey] = [:]
    private var failed: Set<HotKeyAction> = []
    private var suspended = false

    func setHandler(_ action: HotKeyAction, _ handler: @escaping () -> Void) {
        handlers[action] = handler
    }

    /// The user's choice: stored combo, explicit "none", or the default.
    func combo(for action: HotKeyAction) -> KeyCombo? {
        let stored = Prefs.string(action.prefKey)
        if stored == "none" { return nil }
        return KeyCombo(stored: stored) ?? action.defaultCombo
    }

    func display(for action: HotKeyAction) -> String {
        combo(for: action)?.display ?? ""
    }

    /// Which action already uses this combo, if any.
    func owner(of combo: KeyCombo, excluding: HotKeyAction) -> HotKeyAction? {
        HotKeyAction.allCases.first { $0 != excluding && self.combo(for: $0) == combo }
    }

    func set(_ combo: KeyCombo?, for action: HotKeyAction) {
        Prefs.set(action.prefKey, combo?.stored ?? "none")
        registerAll()
    }

    func resetAll() {
        for action in HotKeyAction.allCases { Prefs.set(action.prefKey, nil) }
        registerAll()
    }

    /// While a shell has the keyboard, shortcuts that a terminal needs
    /// itself (control keys, the terminal's own bindings) are let through.
    private var terminalTyping = false

    func setTerminalTyping(_ typing: Bool) {
        guard typing != terminalTyping else { return }
        terminalTyping = typing
        registerAll()
    }

    private func yieldsToTerminal(_ combo: KeyCombo, action: HotKeyAction) -> Bool {
        // The terminal's own key and the screenshot keys never yield: a
        // screenshot shortcut works on every page, even while typing.
        guard terminalTyping, ![.terminal, .snip].contains(action) else { return false }
        if combo.modifiers & UInt32(cmdKey) == 0 { return true }
        return TerminalKeymap.shared.isBound(keyCode: combo.keyCode, carbonModifiers: combo.modifiers)
    }

    func registerAll() {
        registered.removeAll()          // HotKey.deinit unregisters
        failed.removeAll()
        guard !suspended else { return }
        for action in HotKeyAction.allCases {
            guard let combo = combo(for: action), let handler = handlers[action] else { continue }
            if yieldsToTerminal(combo, action: action) { continue }
            if let hotKey = HotKey(keyCode: combo.keyCode, carbonModifiers: combo.modifiers, action: handler) {
                registered[action] = hotKey
            } else {
                failed.insert(action)
            }
        }
        NotificationCenter.default.post(name: .hotKeysChanged, object: nil)
    }

    func isActive(_ action: HotKeyAction) -> Bool { registered[action] != nil }

    /// While a shortcut is being recorded the existing ones must not fire.
    func suspend() { suspended = true; registered.removeAll() }
    func resume() { suspended = false; registerAll() }

    /// (label, state) lines for diagnostics.
    var report: [(String, String)] {
        HotKeyAction.allCases.map { action in
            let label = action.title
            guard let combo = combo(for: action) else { return (label, "Not set") }
            return (label, "\(combo.display) " + (failed.contains(action) ? "FAILED" : "ok"))
        }
    }
}

extension Notification.Name {
    static let hotKeysChanged = Notification.Name("omnihub.hotKeysChanged")
    static let settingsChanged = Notification.Name("omnihub.settingsChanged")
}

// MARK: - Recorder control

/// Click, then press the new shortcut. ⌫ clears it, Esc cancels.
final class ShortcutRecorder: FocusButton {
    let hotKeyAction: HotKeyAction
    private var recording = false

    init(action: HotKeyAction) {
        self.hotKeyAction = action
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        self.action = #selector(beginRecording)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 150).isActive = true
        refresh()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: .hotKeysChanged, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    @objc func refresh() {
        guard !recording else { return }
        let text = HotKeyCenter.shared.display(for: hotKeyAction)
        title = text.isEmpty ? L("Click to record") : text
    }

    private var monitor: Any?

    /// A panel does not become key for a mere button click; recording
    /// needs the keyboard.
    override var needsPanelToBecomeKey: Bool { true }

    @objc private func beginRecording() {
        guard !recording else { return }
        recording = true
        title = L("Press shortcut…")
        HotKeyCenter.shared.suspend()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKey()
        window?.makeFirstResponder(self)
        // Every key press goes through this monitor first, whatever view
        // has the focus, so nothing else can swallow the new shortcut.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recording else { return event }
            self.capture(event)
            return nil
        }
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func endRecording() {
        stopMonitor()
        guard recording else { return }
        recording = false
        HotKeyCenter.shared.resume()
        refresh()
    }

    override func resignFirstResponder() -> Bool {
        endRecording()
        return super.resignFirstResponder()
    }

    /// True while this control wants the next key press for itself
    /// (the app-wide Esc handler checks it).
    var isRecording: Bool { recording }

    private func capture(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let mods = KeyCombo.carbonModifiers(from: flags)
        let keyCode = UInt32(event.keyCode)

        if mods == 0, keyCode == UInt32(kVK_Escape) { endRecording(); return }
        if mods == 0, keyCode == UInt32(kVK_Delete) {
            recording = false
            stopMonitor()
            HotKeyCenter.shared.resume()
            HotKeyCenter.shared.set(nil, for: hotKeyAction)
            refresh()
            return
        }
        // A bare letter would swallow normal typing everywhere.
        let strong = mods & UInt32(cmdKey | controlKey | optionKey) != 0
        guard strong || KeyCombo.isFunctionKey(keyCode) else {
            NSSound.beep()
            title = L("Needs ⌘ / ⌃ / ⌥")
            return
        }
        let combo = KeyCombo(keyCode: keyCode, modifiers: mods)
        if let owner = HotKeyCenter.shared.owner(of: combo, excluding: hotKeyAction) {
            NSSound.beep()
            title = L("Used by “%@”", owner.title)
            return
        }
        recording = false
        stopMonitor()
        HotKeyCenter.shared.resume()
        HotKeyCenter.shared.set(combo, for: hotKeyAction)
        refresh()
    }
}
