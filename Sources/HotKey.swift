import AppKit
import Carbon.HIToolbox

/// Global hotkey through Carbon:
/// `InstallEventHandler` on `kEventClassKeyboard`/`kEventHotKeyPressed`
/// (and `…Released` for keys that act while held) plus `RegisterEventHotKey`. Carbon's hotkey API is still the only route to a
/// system-wide shortcut that needs no Accessibility permission.
final class HotKey {
    private static var registry: [UInt32: (press: () -> Void, release: (() -> Void)?)] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerRef: EventHandlerRef?

    private var hotKeyRef: EventHotKeyRef?
    private let id: UInt32

    /// `onRelease`: also told when the key goes up (for keys that act while held).
    init?(keyCode: UInt32, carbonModifiers: UInt32, action: @escaping () -> Void,
          onRelease: (() -> Void)? = nil) {
        HotKey.installHandlerIfNeeded()
        let newID = HotKey.nextID
        HotKey.nextID += 1

        // Signature "OmHb" tags OmniHub's own hotkeys.
        let hotKeyID = EventHotKeyID(signature: OSType(0x4F6D_4862), id: newID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode,
                                        carbonModifiers,
                                        hotKeyID,
                                        GetApplicationEventTarget(),
                                        0,
                                        &ref)
        guard status == noErr, let ref else { return nil }
        self.hotKeyRef = ref
        self.id = newID
        HotKey.registry[newID] = (action, onRelease)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        HotKey.registry.removeValue(forKey: id)
    }

    private static func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let callback: EventHandlerUPP = { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event,
                                        EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID),
                                        nil,
                                        MemoryLayout<EventHotKeyID>.size,
                                        nil,
                                        &hotKeyID)
            guard err == noErr, let entry = HotKey.registry[hotKeyID.id] else {
                return OSStatus(eventNotHandledErr)
            }
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                guard let release = entry.release else { return OSStatus(eventNotHandledErr) }
                DispatchQueue.main.async(execute: release)
            } else {
                DispatchQueue.main.async(execute: entry.press)
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, specs.count, &specs, nil, &handlerRef)
    }
}

/// Carbon modifier bitmask helpers.
enum HotKeyModifier {
    static let command = UInt32(cmdKey)
    static let shift = UInt32(shiftKey)
    static let option = UInt32(optionKey)
    static let control = UInt32(controlKey)
}
