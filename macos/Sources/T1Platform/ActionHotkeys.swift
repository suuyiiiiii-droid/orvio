import Carbon

/// Owns the Control–Option–Shift shortcuts for actions and remote presets.
@MainActor
public final class ActionHotkeys {
    private static let signature: OSType = 0x54314143 // T1AC
    private static let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8]
    public static let modeKeyCodes: Set<UInt16> = [UInt16(kVK_F10), UInt16(kVK_ANSI_1), UInt16(kVK_ANSI_2), UInt16(kVK_ANSI_3)]

    public static func label(_ id: Int) -> String {
        switch id {
        case 11: "1"
        case 12: "2"
        case 13: "3"
        default: "F\(id)"
        }
    }

    private var handler: EventHandlerRef?
    private var registrations: [Int: EventHotKeyRef] = [:]
    private var held: Set<Int> = []
    private var trigger: ((Int) -> Void)?

    public init() {}

    isolated deinit { stop() }

    public func start(actionsEnabled: Bool = true, modesEnabled: Bool = false, _ trigger: @escaping (Int) -> Void) -> [Int] {
        stop()
        var shortcuts = actionsEnabled ? Dictionary(uniqueKeysWithValues: Self.functionKeys.enumerated().map { ($0.offset + 1, $0.element) }) : [:]
        if modesEnabled { shortcuts.merge([10: kVK_F10, 11: kVK_ANSI_1, 12: kVK_ANSI_2, 13: kVK_ANSI_3]) { _, key in key } }
        guard !shortcuts.isEmpty else { return [] }
        let target = GetApplicationEventTarget()
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let handlerStatus = InstallEventHandler(target, { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
            )
            guard status == noErr else { return OSStatus(eventNotHandledErr) }
            let shortcuts = Unmanaged<ActionHotkeys>.fromOpaque(context).takeUnretainedValue()
            let kind = GetEventKind(event)
            return MainActor.assumeIsolated { shortcuts.receive(identifier, kind: kind) }
        }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard handlerStatus == noErr else { return shortcuts.keys.sorted() }

        self.trigger = trigger
        let modifiers = UInt32(controlKey | optionKey | shiftKey)
        var failed: [Int] = []
        for (index, key) in shortcuts.sorted(by: { $0.key < $1.key }) {
            let identifier = EventHotKeyID(signature: Self.signature, id: UInt32(index))
            var registration: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(key), modifiers, identifier, target, OptionBits(kEventHotKeyExclusive), &registration
            )
            if status == noErr, let registration {
                registrations[index] = registration
            } else {
                failed.append(index)
            }
        }
        if registrations.isEmpty { stop() }
        return failed
    }

    public func stop() {
        for registration in registrations.values {
            UnregisterEventHotKey(registration)
        }
        if let handler { RemoveEventHandler(handler) }
        registrations.removeAll()
        held.removeAll()
        handler = nil
        trigger = nil
    }

    private func receive(_ identifier: EventHotKeyID, kind: UInt32) -> OSStatus {
        let index = Int(identifier.id)
        guard identifier.signature == Self.signature, registrations[index] != nil else {
            return OSStatus(eventNotHandledErr)
        }
        switch kind {
        case UInt32(kEventHotKeyPressed):
            if held.insert(index).inserted { trigger?(index) }
        case UInt32(kEventHotKeyReleased):
            held.remove(index)
        default:
            return OSStatus(eventNotHandledErr)
        }
        return noErr
    }
}
