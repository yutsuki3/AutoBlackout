import Carbon.HIToolbox

/// A system-wide keyboard shortcut (Carbon `RegisterEventHotKey`: needs no Accessibility or Input
/// Monitoring permission, and works while another app is frontmost).
///
/// It exists for the case where the built-in display is off and the external display is connected
/// but shows nothing (e.g. the monitor's input was switched to another computer): there is no
/// screen to open the menu on, but the keyboard still works.
final class GlobalHotKey {
    /// ⌃⌥⌘R — restore the built-in display. Also shown on the menu's "Force-restore" item.
    static let restoreKeyCode = UInt32(kVK_ANSI_R)
    static let restoreModifiers = UInt32(cmdKey | controlKey | optionKey)

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// Returns `nil` if the system refused the registration (e.g. another app owns the shortcut).
    /// `action` runs on the main thread.
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x4142_4F54), id: 1) // 'ABOT'
        let registered = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr else { return nil }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
