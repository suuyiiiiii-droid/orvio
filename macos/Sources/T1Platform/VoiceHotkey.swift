import Carbon

/// Owns the optional Control–Option–Shift–F9 push-to-talk shortcut.
@MainActor
public final class VoiceHotkey {
    private static let signature: OSType = 0x54315648 // T1VH
    private static let hotkeyID = EventHotKeyID(signature: signature, id: 1)
    private var handler: EventHandlerRef?
    private var registration: EventHotKeyRef?
    private var onDown: (() -> Void)?
    private var onUp: (() -> Void)?
    private var held = false

    public init() {}

    isolated deinit { stop() }

    public func start(down: @escaping () -> Void, up: @escaping () -> Void) -> Bool {
        stop()
        let target = GetApplicationEventTarget()
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let result = InstallEventHandler(target, { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<VoiceHotkey>.fromOpaque(context).takeUnretainedValue()
            let kind = GetEventKind(event)
            return MainActor.assumeIsolated { shortcut.receive(identifier, kind: kind) }
        }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { return false }

        let modifiers = UInt32(controlKey | optionKey | shiftKey)
        let status = RegisterEventHotKey(UInt32(kVK_F9), modifiers, Self.hotkeyID, target,
                                         OptionBits(kEventHotKeyExclusive), &registration)
        guard status == noErr, registration != nil else {
            stop()
            return false
        }
        onDown = down
        onUp = up
        return true
    }

    public func stop() {
        if let registration { UnregisterEventHotKey(registration) }
        if let handler { RemoveEventHandler(handler) }
        registration = nil
        handler = nil
        held = false
        onDown = nil
        onUp = nil
    }

    private func receive(_ identifier: EventHotKeyID, kind: UInt32) -> OSStatus {
        guard registration != nil, identifier.signature == Self.signature, identifier.id == Self.hotkeyID.id else {
            return OSStatus(eventNotHandledErr)
        }
        if kind == UInt32(kEventHotKeyPressed), !held {
            held = true
            onDown?()
        } else if kind == UInt32(kEventHotKeyReleased), held {
            held = false
            onUp?()
        }
        return noErr
    }
}
