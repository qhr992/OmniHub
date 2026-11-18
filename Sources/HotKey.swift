import AppKit
import Carbon.HIToolbox

/// Global hotkey through Carbon:
/// `InstallEventHandler` on `kEventClassKeyboard`/`kEventHotKeyPressed` plus
/// `RegisterEventHotKey`. Carbon's hotkey API is still the only route to a
/// system-wide shortcut that needs no Accessibility permission.
final class HotKey {
    private static var registry: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerRef: EventHandlerRef?

    private var hotKeyRef: EventHotKeyRef?
    private let id: UInt32

    init?(keyCode: UInt32, carbonModifiers: UInt32, action: @escaping () -> Void) {
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
        HotKey.registry[newID] = action
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        HotKey.registry.removeValue(forKey: id)
    }

    private static func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
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
            guard err == noErr, let action = HotKey.registry[hotKeyID.id] else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async(execute: action)
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, nil, &handlerRef)
    }
}

/// Carbon modifier bitmask helpers.
enum HotKeyModifier {
    static let command = UInt32(cmdKey)
    static let shift = UInt32(shiftKey)
    static let option = UInt32(optionKey)
    static let control = UInt32(controlKey)
}
