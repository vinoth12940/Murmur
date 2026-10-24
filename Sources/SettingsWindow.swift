import AppKit

/// Connects one checkbox to a setting.
@MainActor
private final class ToggleBinding: NSObject {
    let get: () -> Bool
    let set: (Bool) -> Void
    init(get: @escaping () -> Bool, set: @escaping (Bool) -> Void) {
        self.get = get
        self.set = set
    }
    @objc func changed(_ sender: NSButton) { set(sender.state == .on) }
}

/// The Settings window: the same options as the menu plus the ones that do not fit in it.
@MainActor
final class SettingsWindowController: NSObject {
    private unowned let app: AppDelegate
    private var window: NSWindow?
    private var bindings: [(NSButton, ToggleBinding)] = []
    private let triggerPopup = NSPopUpButton()
    private let languagePopup = NSPopUpButton()

    init(app: AppDelegate) {
        self.app = app
    }

    func show() {
        if window == nil { build() }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func checkbox(_ title: String, note: String? = nil, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> NSView {
        let binding = ToggleBinding(get: get, set: set)
        let button = NSButton(checkboxWithTitle: title, target: binding, action: #selector(ToggleBinding.changed(_:)))
        bindings.append((button, binding))
        guard let note else { return button }
        let label = NSTextField(wrappingLabelWithString: note)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 380
        let stack = NSStackView(views: [button, label])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        label.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 20).isActive = true
        return stack
    }

    private func labeled(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func build() {
        for key in TriggerKey.allCases {
            triggerPopup.addItem(withTitle: key.title)
            triggerPopup.lastItem?.representedObject = key.rawValue
        }
        triggerPopup.target = self
        triggerPopup.action = #selector(triggerChanged)
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        languagePopup.widthAnchor.constraint(equalToConstant: 240).isActive = true

        let editRules = NSButton(title: "Edit Rules File…", target: self, action: #selector(editRulesPressed))
        let clearHistory = NSButton(title: "Clear Saved History", target: self, action: #selector(clearHistoryPressed))
        let buttons = NSStackView(views: [editRules, clearHistory])
        buttons.spacing = 10

        let views: [NSView] = [
            labeled("Trigger key", triggerPopup),
            labeled("Language", languagePopup),
            checkbox("Clean up with Apple Intelligence", note: "Removes “um”, repeats and false starts, and applies your rules.",
                     get: { [app] in app.cleanupEnabled }, set: { [app] in app.cleanupEnabled = $0 }),
            checkbox("Wake word: say “Hey Murmur”", note: "Keeps the microphone open while Murmur is idle. Audio is never saved.",
                     get: { [app] in app.wakeWordEnabled }, set: { [app] in app.wakeWordEnabled = $0 }),
            checkbox("Spoken commands", note: "Say “new line” or “new paragraph” to insert them.",
                     get: { [app] in app.spokenCommandsEnabled }, set: { [app] in app.spokenCommandsEnabled = $0 }),
            checkbox("Show live text while speaking (experimental)", note: "Displays what is being recognised in the floating pill.",
                     get: { [app] in app.livePreviewEnabled }, set: { [app] in app.livePreviewEnabled = $0 }),
            checkbox("Save dictation history on this Mac", note: "Off by default. Stored privately in Application Support; never uploaded.",
                     get: { [app] in app.historyEnabled }, set: { [app] in app.historyEnabled = $0 }),
            checkbox("Launch at login",
                     get: { [app] in app.launchAtLogin }, set: { [app] in app.launchAtLogin = $0 }),
            checkbox("Log what the wake word hears", note: "For troubleshooting only. Written to ~/Library/Logs/Murmur.log.",
                     get: { [app] in app.verboseLogEnabled }, set: { [app] in app.verboseLogEnabled = $0 }),
            buttons,
        ]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: stack.fittingSize),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Murmur Settings"
        window.isReleasedWhenClosed = false
        window.contentView = stack
        window.setContentSize(stack.fittingSize)
        window.center()
        self.window = window
    }

    private func refresh() {
        for (button, binding) in bindings { button.state = binding.get() ? .on : .off }

        if let index = TriggerKey.allCases.firstIndex(of: app.triggerKey) { triggerPopup.selectItem(at: index) }

        languagePopup.removeAllItems()
        let current = Locale(identifier: app.localeID).identifier(.bcp47)
        let locales = app.supportedLocales.sorted { Self.name($0) < Self.name($1) }
        if locales.isEmpty {
            languagePopup.addItem(withTitle: Self.name(Locale(identifier: app.localeID)))
        }
        for locale in locales {
            languagePopup.addItem(withTitle: Self.name(locale))
            languagePopup.lastItem?.representedObject = locale.identifier
            if locale.identifier(.bcp47) == current { languagePopup.select(languagePopup.lastItem) }
        }
    }

    private static func name(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    @objc private func triggerChanged() {
        guard let raw = triggerPopup.selectedItem?.representedObject as? String, let key = TriggerKey(rawValue: raw) else { return }
        app.changeTriggerKey(key)
    }

    @objc private func languageChanged() {
        guard let id = languagePopup.selectedItem?.representedObject as? String else { return }
        app.changeLanguage(id)
    }

    @objc private func editRulesPressed() { app.openRulesFile() }
    @objc private func clearHistoryPressed() { app.clearHistoryNow() }
}
