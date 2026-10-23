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

        // The Option key from the shortcut may still be down; wait so ⌘V isn't read as ⌥⌘V.
        for _ in 0..<20 where CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate) {
            try? await Task.sleep(for: .milliseconds(50))
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }

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
