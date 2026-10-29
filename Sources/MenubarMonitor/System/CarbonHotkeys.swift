import Carbon
import MenubarCore

/// The global hotkey through Carbon's `RegisterEventHotKey` (APP-08). It needs no Accessibility permission and no
/// Input Monitoring: macOS itself matches the key and tells the app that registered it. It works for an `.accessory`
/// app as well, since the event goes to the application's event target, which exists whatever the activation policy.
///
/// Never registered from a test or a probe: that would take the shortcut from whatever app holds it on the user's Mac.
/// The tests use `FakeHotkeyRegistrar`.
@MainActor
final class CarbonHotkeys: HotkeyRegistrar {
    /// the hotkey's four-character signature, `mmhk`
    nonisolated private static let signature: OSType = 0x6D6D_686B
    nonisolated private static let hotKeyID: UInt32 = 1

    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// what the Carbon callback reaches; there is one registrar per app
    private static var onPress: (@MainActor () -> Void)?

    func register(_ shortcut: HotkeyShortcut, onPress: @escaping @MainActor () -> Void) throws {
        unregister()
        try installHandler()
        var reference: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers.rawValue, id, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else {
            // eventHotKeyExistsErr: another app, or this one, registered the same key and modifiers.
            throw status == OSStatus(eventHotKeyExistsErr) ? HotkeyError.taken : HotkeyError.refused(Int(status))
        }
        self.reference = reference
        Self.onPress = onPress
    }

    func unregister() {
        if let reference {
            UnregisterEventHotKey(reference)
            self.reference = nil
        }
        Self.onPress = nil
    }

    /// Installs the handler for hotkey presses once; it stays for the life of the app and ignores presses while no
    /// shortcut is registered.
    private func installHandler() throws {
        guard handler == nil else {
            return
        }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                var id = EventHotKeyID()
                let read = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard read == noErr, id.signature == CarbonHotkeys.signature, id.id == CarbonHotkeys.hotKeyID else {
                    return OSStatus(eventNotHandledErr)
                }
                // Carbon delivers on the main thread; the hop keeps the call out of the C callback's context.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { CarbonHotkeys.onPress?() }
                }
                return noErr
            },
            1, &type, nil, &handler)
        guard status == noErr else {
            throw HotkeyError.refused(Int(status))
        }
    }
}
