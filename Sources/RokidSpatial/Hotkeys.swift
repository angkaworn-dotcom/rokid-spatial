// System-wide hotkeys via Carbon's RegisterEventHotKey.
//
// The obvious alternative, NSEvent.addGlobalMonitorForEvents, needs
// Accessibility consent. Carbon hotkeys need nothing, and the app has to work
// while your focus is in another application by definition — the whole point
// is that you keep working while the screen follows your head.

import Foundation
import Carbon.HIToolbox

final class Hotkeys {
    struct Binding {
        let keyCode: UInt32
        let modifiers: UInt32
        let label: String
        let action: () -> Void
    }

    private var handlers: [UInt32: Binding] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1

    /// ⌃⌥ — unlikely to collide with anything the user already relies on.
    static let defaultModifiers = UInt32(controlKey | optionKey)

    func register(keyCode: Int, modifiers: UInt32 = Hotkeys.defaultModifiers,
                  label: String, action: @escaping () -> Void) {
        let id = nextID
        nextID += 1
        handlers[id] = Binding(keyCode: UInt32(keyCode), modifiers: modifiers,
                               label: label, action: action)

        var ref: EventHotKeyRef?
        var hotKeyID = EventHotKeyID(signature: OSType(0x524B4453), id: id)  // 'RKDS'
        RegisterEventHotKey(UInt32(keyCode), modifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
        _ = hotKeyID
    }

    func start() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }

            let hotkeys = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
            hotkeys.handlers[hotKeyID.id]?.action()
            return noErr
        }, 1, &spec, context, &eventHandler)
    }

    func stop() {
        for ref in refs where ref != nil {
            UnregisterEventHotKey(ref)
        }
        refs.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    deinit { stop() }
}
