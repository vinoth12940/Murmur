import Carbon.HIToolbox
import Foundation

/// Global hotkey through Carbon's RegisterEventHotKey: needs no Accessibility permission
/// and swallows the key combination so the focused app never sees it.
final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32

    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var installed = false

    init?(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        Self.installDispatcher()
        id = Self.nextID
        Self.nextID += 1
        Self.handlers[id] = handler
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D52_4D52), id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            Self.handlers[id] = nil
            return nil
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
    }

    private static func installDispatcher() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(0x686B_6964) /* typeEventHotKey */, nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
