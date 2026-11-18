import AppKit
import Carbon.HIToolbox

/// Everything the terminal page does from the keyboard.
enum TerminalAction: String, CaseIterable {
    case newTab, closeTab, nextTab, previousTab
    case clear, copy, paste, selectAll, find
    case biggerText, smallerText, defaultText
    case scrollToTop, scrollToBottom, pageUp, pageDown
    case connections
    case tab1, tab2, tab3, tab4, tab5, tab6, tab7, tab8, tab9

    var title: String {
        switch self {
        case .newTab: return "New Tab"
        case .closeTab: return "Close Tab"
        case .nextTab: return "Next Tab"
        case .previousTab: return "Previous Tab"
        case .clear: return "Clear"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .selectAll: return "Select All"
        case .find: return "Find"
        case .biggerText: return "Bigger Text"
        case .smallerText: return "Smaller Text"
        case .defaultText: return "Default Text Size"
        case .scrollToTop: return "Scroll to Top"
        case .scrollToBottom: return "Scroll to Bottom"
        case .pageUp: return "Page Up"
        case .pageDown: return "Page Down"
        case .connections: return "Connections"
        default: return "Tab \(rawValue.dropFirst(3))"
        }
    }

    /// The ones offered in the settings page; the rest live in the file only.
    static let common: [TerminalAction] = [.newTab, .closeTab, .nextTab, .previousTab, .clear, .find, .connections]

    /// The shortcuts of macOS's own Terminal.
    var defaults: [String] {
        switch self {
        case .newTab: return ["cmd+t", "cmd+n"]
        case .closeTab: return ["cmd+w"]
        case .nextTab: return ["ctrl+tab", "cmd+shift+]"]
        case .previousTab: return ["ctrl+shift+tab", "cmd+shift+["]
        case .clear: return ["cmd+k"]
        case .copy: return ["cmd+c"]
        case .paste: return ["cmd+v"]
        case .selectAll: return ["cmd+a"]
        case .find: return ["cmd+f"]
        case .biggerText: return ["cmd+=", "cmd+shift+="]
        case .smallerText: return ["cmd+-"]
        case .defaultText: return ["cmd+0"]
        case .scrollToTop: return ["cmd+home"]
        case .scrollToBottom: return ["cmd+end"]
        case .pageUp: return ["cmd+pageup", "pageup"]
        case .pageDown: return ["cmd+pagedown", "pagedown"]
        case .connections: return ["cmd+shift+k"]
        default: return ["cmd+\(rawValue.dropFirst(3))"]
        }
    }
}

/// A key with modifiers, written "cmd+shift+k" in the configuration file.
struct LocalCombo: Equatable {
    var keyCode: UInt16
    var flags: NSEvent.ModifierFlags

    private static let mask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    private static let keyNames: [(String, Int)] = [
        ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
        ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
        ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
        ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
        ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
        ("z", kVK_ANSI_Z),
        ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3), ("4", kVK_ANSI_4),
        ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
        ("`", kVK_ANSI_Grave), ("-", kVK_ANSI_Minus), ("=", kVK_ANSI_Equal), ("[", kVK_ANSI_LeftBracket),
        ("]", kVK_ANSI_RightBracket), ("\\", kVK_ANSI_Backslash), (";", kVK_ANSI_Semicolon),
        ("'", kVK_ANSI_Quote), (",", kVK_ANSI_Comma), (".", kVK_ANSI_Period), ("/", kVK_ANSI_Slash),
        ("space", kVK_Space), ("return", kVK_Return), ("tab", kVK_Tab), ("delete", kVK_Delete),
        ("escape", kVK_Escape), ("left", kVK_LeftArrow), ("right", kVK_RightArrow), ("up", kVK_UpArrow),
        ("down", kVK_DownArrow), ("home", kVK_Home), ("end", kVK_End), ("pageup", kVK_PageUp),
        ("pagedown", kVK_PageDown),
        ("f1", kVK_F1), ("f2", kVK_F2), ("f3", kVK_F3), ("f4", kVK_F4), ("f5", kVK_F5), ("f6", kVK_F6),
        ("f7", kVK_F7), ("f8", kVK_F8), ("f9", kVK_F9), ("f10", kVK_F10), ("f11", kVK_F11), ("f12", kVK_F12)
    ]

    init(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.flags = flags.intersection(Self.mask)
    }

    init(event: NSEvent) {
        self.init(keyCode: event.keyCode, flags: event.modifierFlags)
    }

    init?(text: String) {
        var flags: NSEvent.ModifierFlags = []
        var key: Int?
        // "cmd+=" must not lose its "=" to the separator, so split by hand.
        var parts = text.lowercased().trimmingCharacters(in: .whitespaces).components(separatedBy: "+")
        if parts.count >= 2, parts.last == "", parts[parts.count - 2] == "" {
            parts.removeLast(2)
            parts.append("+")
        }
        for part in parts {
            switch part {
            case "cmd", "command": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt", "option", "alt": flags.insert(.option)
            case "ctrl", "control": flags.insert(.control)
            case "+": key = kVK_ANSI_Equal; flags.insert(.shift)
            default:
                guard let found = Self.keyNames.first(where: { $0.0 == part }) else { return nil }
                key = found.1
            }
        }
        guard let key else { return nil }
        self.init(keyCode: UInt16(key), flags: flags)
    }

    var text: String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("opt") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.command) { parts.append("cmd") }
        parts.append(Self.keyNames.first { $0.1 == Int(keyCode) }?.0 ?? "key\(keyCode)")
        return parts.joined(separator: "+")
    }

    /// "⇧⌘K"-style label.
    var display: String {
        KeyCombo(keyCode: UInt32(keyCode), modifiers: KeyCombo.carbonModifiers(from: flags)).display
    }
}

/// Terminal shortcuts, kept in `terminal-keys.json` next to the app's other
/// data so every one of them can be changed by hand. The common ones can
/// also be recorded in the settings page.
final class TerminalKeymap {
    static let shared = TerminalKeymap()
    static var fileURL: URL { Store.url("terminal-keys.json") }

    private var bindings: [TerminalAction: [LocalCombo]] = [:]
    private var loadedStamp: Date?

    private init() { load() }

    private func fileStamp() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: Self.fileURL.path))?[.modificationDate] as? Date
    }

    /// Reads the file, creating it with the defaults the first time. Unknown
    /// or missing entries fall back to the defaults.
    func load() {
        var stored: [String: [String]] = [:]
        if let data = try? Data(contentsOf: Self.fileURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in parsed {
                if let list = value as? [String] { stored[key] = list }
            }
        }
        bindings = [:]
        for action in TerminalAction.allCases {
            let texts = stored[action.rawValue] ?? action.defaults
            bindings[action] = texts.compactMap { LocalCombo(text: $0) }
        }
        if !FileManager.default.fileExists(atPath: Self.fileURL.path) { save() }
        loadedStamp = fileStamp()
    }

    /// Picks up hand edits of the file.
    func reloadIfChanged() {
        if fileStamp() != loadedStamp { load() }
    }

    private func save() {
        var object: [String: [String]] = [:]
        for action in TerminalAction.allCases {
            object[action.rawValue] = (bindings[action] ?? []).map(\.text)
        }
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
        loadedStamp = fileStamp()
    }

    func combos(for action: TerminalAction) -> [LocalCombo] { bindings[action] ?? [] }

    /// Whether a global shortcut (Carbon modifiers) is also a terminal key.
    func isBound(keyCode: UInt32, carbonModifiers mods: UInt32) -> Bool {
        var flags: NSEvent.ModifierFlags = []
        if mods & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if mods & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if mods & UInt32(optionKey) != 0 { flags.insert(.option) }
        if mods & UInt32(controlKey) != 0 { flags.insert(.control) }
        let combo = LocalCombo(keyCode: UInt16(keyCode), flags: flags)
        return bindings.values.contains { $0.contains(combo) }
    }

    func action(for event: NSEvent) -> TerminalAction? {
        let combo = LocalCombo(event: event)
        return TerminalAction.allCases.first { (bindings[$0] ?? []).contains(combo) }
    }

    /// Settings page: one combo replaces the action's list (nil clears it).
    /// Any other action that used the same combo gives it up.
    func set(_ combo: LocalCombo?, for action: TerminalAction) {
        if let combo {
            for other in TerminalAction.allCases where other != action {
                bindings[other]?.removeAll { $0 == combo }
            }
            bindings[action] = [combo]
        } else {
            bindings[action] = []
        }
        save()
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }

    func resetToDefaults() {
        try? FileManager.default.removeItem(at: Self.fileURL)
        load()
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }
}

/// Click, then press the new shortcut for a terminal action. ⌫ clears it,
/// Esc cancels.
final class LocalKeyRecorder: NSButton {
    private let terminalAction: TerminalAction
    private(set) var isRecording = false

    init(action: TerminalAction) {
        terminalAction = action
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        self.action = #selector(begin)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 150).isActive = true
        refresh()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .settingsChanged, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    @objc private func refresh() {
        guard !isRecording else { return }
        let combos = TerminalKeymap.shared.combos(for: terminalAction)
        title = combos.isEmpty ? "Click to record" : combos.map(\.display).joined(separator: " or ")
    }

    private var monitor: Any?
    override var needsPanelToBecomeKey: Bool { true }

    @objc private func begin() {
        guard !isRecording else { return }
        isRecording = true
        title = "Press shortcut…"
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKey()
        window?.makeFirstResponder(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            self.capture(event)
            return nil
        }
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func end() {
        stopMonitor()
        isRecording = false
        refresh()
    }

    override func resignFirstResponder() -> Bool {
        end()
        return super.resignFirstResponder()
    }

    private func capture(_ event: NSEvent) {
        let combo = LocalCombo(event: event)
        if combo.flags.isEmpty, combo.keyCode == UInt16(kVK_Escape) { end(); return }
        if combo.flags.isEmpty, combo.keyCode == UInt16(kVK_Delete) {
            isRecording = false
            stopMonitor()
            TerminalKeymap.shared.set(nil, for: terminalAction)
            refresh()
            return
        }
        // A bare key would swallow what is typed into the shell.
        guard combo.flags.contains(.command) || combo.flags.contains(.control) else {
            NSSound.beep()
            title = "Needs ⌘ or ⌃"
            return
        }
        isRecording = false
        stopMonitor()
        TerminalKeymap.shared.set(combo, for: terminalAction)
        refresh()
    }
}
