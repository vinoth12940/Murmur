import AppKit

/// First-run window (also in the menu as "Setup & Permissions…"): shows what Murmur needs, with live status
/// and a button per item. It refreshes every second, so granting a permission in System Settings shows up here.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    private unowned let app: AppDelegate
    private var window: NSWindow?
    private var timer: Timer?
    private var rows: [Row] = []

    private enum Item: Int, CaseIterable { case microphone, inputMonitoring, accessibility, speech }

    private struct Row {
        let item: Item
        let icon: NSImageView
        let status: NSTextField
        let button: NSButton
    }

    init(app: AppDelegate) {
        self.app = app
    }

    func show() {
        if window == nil { build() }
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    private func build() {
        let title = NSTextField(labelWithString: "Welcome to Murmur")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        let intro = NSTextField(wrappingLabelWithString:
            "Hold the trigger key, speak, and your words are typed for you. Audio stays on this Mac. " +
            "Murmur needs the permissions below; they are only used for dictation.")
        intro.textColor = .secondaryLabelColor
        intro.preferredMaxLayoutWidth = 460

        let stack = NSStackView(views: [title, intro])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)

        for item in Item.allCases {
            let (name, detail) = Self.text(for: item)
            let icon = NSImageView()
            icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
            let nameLabel = NSTextField(labelWithString: name)
            nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            let detailLabel = NSTextField(wrappingLabelWithString: detail)
            detailLabel.font = .systemFont(ofSize: 11)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.preferredMaxLayoutWidth = 270
            let status = NSTextField(labelWithString: "")
            status.font = .systemFont(ofSize: 11, weight: .medium)
            let texts = NSStackView(views: [nameLabel, detailLabel, status])
            texts.orientation = .vertical
            texts.alignment = .leading
            texts.spacing = 2
            let button = NSButton(title: "Allow…", target: self, action: #selector(buttonPressed(_:)))
            button.tag = item.rawValue
            button.bezelStyle = .rounded
            button.isHidden = item == .speech
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [icon, texts, spacer, button])
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = 12
            row.widthAnchor.constraint(equalToConstant: 460).isActive = true
            stack.addArrangedSubview(row)
            rows.append(Row(item: item, icon: icon, status: status, button: button))
        }

        let footer = NSTextField(wrappingLabelWithString:
            "Reopen this any time from the menu bar icon → Setup & Permissions…")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        footer.preferredMaxLayoutWidth = 340
        let done = NSButton(title: "Done", target: self, action: #selector(donePressed))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let spacer = NSView()
        let bottom = NSStackView(views: [footer, spacer, done])
        bottom.orientation = .horizontal
        bottom.alignment = .centerY
        bottom.widthAnchor.constraint(equalToConstant: 460).isActive = true
        stack.addArrangedSubview(bottom)

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: stack.fittingSize),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Murmur Setup"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = stack
        window.setContentSize(stack.fittingSize)
        window.center()
        self.window = window
    }

    private static func text(for item: Item) -> (String, String) {
        switch item {
        case .microphone: return ("Microphone", "Murmur listens only while you are dictating.")
        case .inputMonitoring: return ("Input Monitoring", "Lets Murmur notice when you hold the trigger key. It never records what you type.")
        case .accessibility: return ("Accessibility", "Lets Murmur paste the text into the app you are using.")
        case .speech: return ("Speech model", "The on-device model that turns your voice into text.")
        }
    }

    private func refresh() {
        for row in rows {
            let granted: Bool
            let statusText: String
            switch row.item {
            case .microphone:
                granted = Permissions.microphone == .granted
                statusText = Permissions.microphone.label
            case .inputMonitoring:
                granted = Permissions.inputMonitoring == .granted
                statusText = Permissions.inputMonitoring.label
            case .accessibility:
                granted = Permissions.accessibility == .granted
                statusText = Permissions.accessibility.label
            case .speech:
                granted = app.statusLine == "Ready"
                statusText = app.statusLine
            }
            let symbol = granted ? "checkmark.circle.fill" : "circle.dashed"
            row.icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: statusText)
            row.icon.contentTintColor = granted ? .systemGreen : .tertiaryLabelColor
            row.status.stringValue = statusText
            row.status.textColor = granted ? .systemGreen : .secondaryLabelColor
            row.button.isEnabled = !granted
            row.button.title = granted ? "Allowed" : "Allow…"
        }
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        guard let item = Item(rawValue: sender.tag) else { return }
        switch item {
        case .microphone:
            if Permissions.microphone == .notDetermined {
                Task { _ = await Dictation.requestMicrophone() }
            } else {
                Permissions.openSettings(.microphone)
            }
        case .inputMonitoring:
            KeyMonitor.requestPermission()
            Permissions.openSettings(.inputMonitoring)
        case .accessibility:
            Paster.requestAccessibility()
            Permissions.openSettings(.accessibility)
        case .speech:
            break
        }
    }

    @objc private func donePressed() {
        window?.close()
    }
}
