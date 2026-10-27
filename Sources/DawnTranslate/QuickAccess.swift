import AppKit
import Carbon

// Carbon hot keys register only these two combinations, without observing typing
// or requiring Accessibility/Input Monitoring access.
final class QuickAccess {
    private var handler: EventHandlerRef?
    private var keys: [EventHotKeyRef] = []
    let action: @MainActor (UInt32) -> Void
    private(set) var available = true
    init(action: @escaping @MainActor (UInt32) -> Void) {
        self.action = action
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == 0x44574E54 else { return OSStatus(eventNotHandledErr) }
            let service = Unmanaged<QuickAccess>.fromOpaque(context).takeUnretainedValue()
            let id = identifier.id
            Task { @MainActor in service.action(id) }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { available = false; return }
        for (id, key) in [(UInt32(1), kVK_ANSI_D), (UInt32(2), kVK_ANSI_V)] {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey),
                                             EventHotKeyID(signature: 0x44574E54, id: id), GetApplicationEventTarget(), 0, &reference)
            if result == noErr, let reference { keys.append(reference) }
            else { available = false }
        }
    }
    deinit {
        for key in keys { UnregisterEventHotKey(key) }
        if let handler { RemoveEventHandler(handler) }
    }
}
