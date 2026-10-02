import AppKit
import Carbon.HIToolbox

/// Carbon の RegisterEventHotKey によるグローバルホットキー。
/// アクセシビリティ権限なしで、どのアプリが前面にあっても反応する。複数のキーを ID で区別する。
final class HotKey {
    /// (ID, 押した=true / 離した=false)
    var action: ((UInt32, Bool) -> Void)?

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?

    init() {
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            let id = hotKeyID.id
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async { hotKey.action?(id, pressed) }
            return noErr
        }, specs.count, &specs, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    /// 登録に失敗した場合(他アプリと衝突など)は false
    @discardableResult
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32) -> Bool {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4B4B_5452), id: id) // 'KKTR'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKeyRefs[id] = ref
        return true
    }

    func unregisterAll() {
        for ref in hotKeyRefs.values { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
    }

    // MARK: - 表示用ユーティリティ

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    static func modifierFlags(fromCarbon m: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if m & UInt32(controlKey) != 0 { flags.insert(.control) }
        if m & UInt32(optionKey) != 0 { flags.insert(.option) }
        if m & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if m & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    static func label(modifiers: UInt32, keyName: String) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName
    }

    static func keyName(for event: NSEvent) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
            kVK_F18: "F18", kVK_F19: "F19",
        ]
        if let name = special[Int(event.keyCode)] { return name }
        return event.charactersIgnoringModifiers?.uppercased() ?? "?"
    }
}
