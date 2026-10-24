import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Inserts text into whatever app and field has focus by placing it on the pasteboard and
/// sending ⌘V, then restoring the previous pasteboard. Works in native apps and browsers alike.
enum Paster {
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// True when the focused UI element is a password field. False when unknown or Accessibility is off.
    static func focusedFieldIsSecure() -> Bool {
        guard hasAccessibility, let element = focusedElement() else { return false }
        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success else { return false }
        return (subrole as? String) == "AXSecureTextField"
    }

    /// Name of the app being dictated into, for per-app rules and history: [display name, bundle id].
    static func frontmostAppNames() -> [String] {
        guard let app = NSWorkspace.shared.frontmostApplication else { return [] }
        return [app.localizedName, app.bundleIdentifier].compactMap { $0 }
    }

    private static func focusedElement() -> AXUIElement? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (focused as! AXUIElement)
    }

    /// The currently selected text in the focused app: read through Accessibility when the app supports it,
    /// otherwise by copying with ⌘C and restoring the user's clipboard. Nil when nothing is selected.
    static func selectedText() async -> String? {
        guard hasAccessibility else { return nil }
        if let element = focusedElement() {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
               let text = value as? String, !text.isEmpty { return text }
        }
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        pasteboard.clearContents()
        let marker = pasteboard.changeCount
        await waitForOptionRelease()
        sendCommandKey(kVK_ANSI_C)
        for _ in 0..<10 where pasteboard.changeCount == marker { try? await Task.sleep(for: .milliseconds(50)) }
        let copied = pasteboard.changeCount == marker ? nil : pasteboard.string(forType: .string)
        restore(saved, to: pasteboard)
        guard let copied, !copied.isEmpty else { return nil }
        return copied
    }

    /// The Option key from the shortcut may still be down; wait so ⌘V isn't read as ⌥⌘V.
    private static func waitForOptionRelease() async {
        for _ in 0..<20 where CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate) {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func sendCommandKey(_ key: Int) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    /// Returns false when the text could only be left on the clipboard (no Accessibility access).
    @discardableResult
    static func paste(_ text: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Ask clipboard managers not to record this temporary entry.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ourChange = pasteboard.changeCount

        guard hasAccessibility else { return false }

        await waitForOptionRelease()
        sendCommandKey(kVK_ANSI_V)

        // Give the target app time to read the pasteboard, then put the user's clipboard back.
        try? await Task.sleep(for: .milliseconds(700))
        if pasteboard.changeCount == ourChange { restore(saved, to: pasteboard) }
        return true
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func restore(_ saved: [[(NSPasteboard.PasteboardType, Data)]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
