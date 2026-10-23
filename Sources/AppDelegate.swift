import AppKit
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement
import Speech

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum State { case preparing, idle, recording, processing }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let hud = HUD()
    private let dictation = Dictation()
    private let keys = KeyMonitor()
    private var escapeKey: HotKey?
    private var toggleKey: HotKey?
    private let wake = WakeWordListener()
    private var state: State = .preparing { didSet { refreshIcon(); syncWakeListener() } }
    private var lastText = ""
    private var statusLine = "Preparing speech model…"
    private var supportedLocales: [Locale] = []

    // Gesture state: hold = push-to-talk, quick double-tap = hands-free until tapped again or silence.
    private let holdDelay: Duration = .milliseconds(250)
    private let doubleTapWindow: TimeInterval = 0.45
    private var holdTask: Task<Void, Never>?
    private var startTask: Task<Bool, Never>?
    private var triggerHeld = false
    private var startedByHold = false
    private var latched = false
    private var ignoreNextUp = false
    private var lastTapUp: Date?
    private var heardSpeech = false
    private var lastVoice = Date()
    private var recordingStarted = Date()

    private let defaults = UserDefaults.standard
    private var cleanupEnabled: Bool {
        get { defaults.object(forKey: "cleanup") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "cleanup") }
    }
    private var localeID: String {
        get { defaults.string(forKey: "locale") ?? Locale.current.identifier }
        set { defaults.set(newValue, forKey: "locale") }
    }
    private var wakeWordEnabled: Bool {
        get { defaults.bool(forKey: "wakeWord") }
        set { defaults.set(newValue, forKey: "wakeWord"); syncWakeListener() }
    }
    private var triggerKey: TriggerKey {
        get { TriggerKey(rawValue: defaults.string(forKey: "trigger") ?? "") ?? .rightOption }
        set { defaults.set(newValue.rawValue, forKey: "trigger"); keys.trigger = newValue }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Rules.ensureFileExists()
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        refreshIcon()

        keys.trigger = triggerKey
        keys.onDown = { [weak self] in Task { @MainActor in self?.triggerDown() } }
        keys.onUp = { [weak self] in Task { @MainActor in self?.triggerUp() } }
        keys.onOtherKey = { [weak self] in Task { @MainActor in self?.otherKeyPressed() } }
        startKeyMonitor()

        // ⌃Space: press to start, press again to stop (or pause for ~2.5 s).
        toggleKey = HotKey(keyCode: kVK_Space, modifiers: controlKey) { [weak self] in
            Task { @MainActor in self?.toggle() }
        }
        Log.write("launch: ⌃Space hotkey \(toggleKey == nil ? "NOT registered (taken)" : "registered")")
        if toggleKey == nil {
            hud.flash("⌃Space is taken by macOS. Turn off “Select the previous input source” in Keyboard Shortcuts.", seconds: 6)
        }

        wake.onWake = { [weak self] in
            DispatchQueue.main.async { self?.wakeHeard() }
        }
        dictation.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.handleLevel(level) }
        }
        Task {
            _ = await Dictation.requestMicrophone()
            await prepareSpeech()
        }
        // Permissions are requested from the menu or on first paste, not on every launch.
    }

    /// The key listener needs Input Monitoring; keep retrying so granting it takes effect without a relaunch.
    private func startKeyMonitor() {
        if keys.start() { return }
        if !KeyMonitor.hasPermission, !defaults.bool(forKey: "askedInputMonitoring") {
            defaults.set(true, forKey: "askedInputMonitoring")
            KeyMonitor.requestPermission()
        }
        Task {
            while !keys.start() {
                try? await Task.sleep(for: .seconds(2))
            }
            hud.flash("Ready: hold \(triggerKey.shortName) to dictate")
        }
    }

    // MARK: Trigger gestures

    private func triggerDown() {
        triggerHeld = true
        if state == .recording && latched {
            // Tap while hands-free recording: finish.
            latched = false
            ignoreNextUp = true
            stopRecording()
            return
        }
        guard state == .idle else { return }

        if let last = lastTapUp, Date().timeIntervalSince(last) < doubleTapWindow {
            // Second quick tap: hands-free mode.
            lastTapUp = nil
            latched = true
            ignoreNextUp = true
            startRecording()
            return
        }
        startedByHold = false
        holdTask?.cancel()
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: holdDelay)
            guard !Task.isCancelled, triggerHeld, state == .idle else { return }
            startedByHold = true
            startRecording()
        }
    }

    private func triggerUp() {
        triggerHeld = false
        if ignoreNextUp { ignoreNextUp = false; return }
        holdTask?.cancel()
        if startedByHold {
            startedByHold = false
            if state == .recording { stopRecording() }
        } else {
            lastTapUp = Date()
        }
    }

    private func otherKeyPressed() {
        // A key pressed together with the trigger means a normal shortcut (e.g. ⌥E), not dictation.
        guard triggerHeld, !startedByHold else { return }
        holdTask?.cancel()
        lastTapUp = nil
    }

    private func handleLevel(_ level: Float) {
        hud.updateLevel(level)
        guard state == .recording else { return }
        if level > 0.12 { heardSpeech = true; lastVoice = Date() }
        guard latched else { return }
        if heardSpeech, Date().timeIntervalSince(lastVoice) > 2.5 {
            latched = false
            stopRecording()
        } else if !heardSpeech, Date().timeIntervalSince(recordingStarted) > 12 {
            latched = false
            cancelRecording()
        }
    }

    // MARK: Wake word

    /// Runs the listener only while the app is idle and the option is on; the mic is free during dictation.
    private func syncWakeListener() {
        if wakeWordEnabled, state == .idle, let locale = dictation.locale, let format = dictation.analyzerFormat {
            wake.begin(locale: locale, format: format)
        } else {
            wake.stop()
        }
    }

    private func wakeHeard() {
        guard state == .idle, wakeWordEnabled else { syncWakeListener(); return }
        NSSound(named: "Tink")?.play()
        latched = true
        startRecording()
    }

    // MARK: Dictation flow

    private func prepareSpeech() async {
        state = .preparing
        supportedLocales = await Array(SpeechTranscriber.supportedLocales)
        do {
            try await dictation.prepare(locale: Locale(identifier: localeID)) { [weak self] message in
                Task { @MainActor in self?.statusLine = message; self?.hud.showBusy(message) }
            }
            statusLine = "Ready"
            Log.write("speech model ready; mic permission \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue), accessibility \(Paster.hasAccessibility), input monitoring \(KeyMonitor.hasPermission)")
            state = .idle
            hud.hide()
        } catch {
            statusLine = error.localizedDescription
            state = .idle
            hud.flash(error.localizedDescription, seconds: 5)
        }
    }

    /// Start/stop from the menu.
    private func toggle() {
        switch state {
        case .idle:
            latched = true
            startRecording()
        case .recording:
            latched = false
            stopRecording()
        case .preparing: hud.flash(statusLine)
        case .processing: NSSound.beep()
        }
    }

    private func startRecording() {
        guard dictation.isReady else {
            latched = false
            hud.flash(statusLine); return
        }
        state = .recording
        heardSpeech = false
        lastVoice = Date()
        recordingStarted = Date()
        hud.showListening(hint: latched ? "Pause or press ⌃Space to finish" : "Release to finish")
        escapeKey = HotKey(keyCode: kVK_Escape, modifiers: 0) { [weak self] in
            Task { @MainActor in self?.cancelRecording() }
        }
        startTask = Task {
            do {
                try await dictation.start()
                return true
            } catch {
                escapeKey = nil
                latched = false
                state = .idle
                hud.flash(error.localizedDescription, seconds: 4)
                return false
            }
        }
    }

    private func cancelRecording() {
        guard state == .recording else { return }
        escapeKey = nil
        latched = false
        startedByHold = false
        state = .idle
        let starting = startTask
        Task {
            _ = await starting?.value
            await dictation.cancel()
        }
        hud.flash("Cancelled", seconds: 1)
    }

    private func stopRecording() {
        escapeKey = nil
        state = .processing
        hud.showBusy("Transcribing…")
        let starting = startTask
        Task {
            guard await starting?.value == true else { state = .idle; return }
            do {
                let raw = try await dictation.stop()
                guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    state = .idle
                    hud.flash("Didn't catch that")
                    return
                }
                let useModel = cleanupEnabled
                if useModel { hud.showBusy("Polishing…") }
                let text = await Cleaner.clean(raw, rules: Rules.load(), useModel: useModel)
                lastText = text
                let pasted = await Paster.paste(text)
                state = .idle
                if pasted {
                    hud.hide()
                } else {
                    hud.flash("Copied to clipboard. Press ⌘V to paste. (Enable Accessibility for Murmur to paste for you.)", seconds: 5)
                    if !defaults.bool(forKey: "askedAccessibility") {
                        defaults.set(true, forKey: "askedAccessibility")
                        Paster.requestAccessibility()
                    }
                }
            } catch {
                state = .idle
                hud.flash("Dictation failed: \(error.localizedDescription)", seconds: 4)
            }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "Murmur · \(statusLine)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let hint = NSMenuItem(title: "⌃Space to start/stop · or hold \(triggerKey.shortName) to talk", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        if !keys.isRunning {
            let perm = NSMenuItem(title: "Allow Input Monitoring to enable \(triggerKey.shortName)…", action: #selector(openInputMonitoring), keyEquivalent: "")
            perm.target = self
            menu.addItem(perm)
        }
        menu.addItem(.separator())

        let toggleItem = NSMenuItem(title: state == .recording ? "Stop Dictation" : "Start Dictation",
                                    action: #selector(toggleFromMenu), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.isEnabled = state == .idle || state == .recording
        menu.addItem(toggleItem)

        let copyLast = NSMenuItem(title: "Copy Last Dictation", action: #selector(copyLast), keyEquivalent: "")
        copyLast.target = self
        copyLast.isEnabled = !lastText.isEmpty
        menu.addItem(copyLast)
        menu.addItem(.separator())

        let wakeItem = NSMenuItem(title: "Wake Word: say “Hey Murmur”", action: #selector(toggleWakeWord), keyEquivalent: "")
        wakeItem.target = self
        wakeItem.state = wakeWordEnabled ? .on : .off
        menu.addItem(wakeItem)

        let cleanup = NSMenuItem(title: "Clean Up with Apple Intelligence", action: #selector(toggleCleanup), keyEquivalent: "")
        cleanup.target = self
        cleanup.state = cleanupEnabled ? .on : .off
        menu.addItem(cleanup)
        if cleanupEnabled && !Cleaner.modelAvailable {
            let warn = NSMenuItem(title: "   \(Cleaner.unavailableReason) Basic cleanup is used.", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
        }
        let edit = NSMenuItem(title: "Edit Rules File…", action: #selector(editRules), keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)
        let reveal = NSMenuItem(title: "Show Rules in Finder", action: #selector(revealRules), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        menu.addItem(.separator())

        let triggerMenu = NSMenuItem(title: "Trigger Key", action: nil, keyEquivalent: "")
        let triggerSub = NSMenu()
        for key in TriggerKey.allCases {
            let item = NSMenuItem(title: key.title, action: #selector(pickTrigger(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key.rawValue
            item.state = key == triggerKey ? .on : .off
            triggerSub.addItem(item)
        }
        if triggerKey == .fn {
            triggerSub.addItem(.separator())
            let note = NSMenuItem(title: "Set “Press 🌐 key to” → Do Nothing in Keyboard settings", action: nil, keyEquivalent: "")
            note.isEnabled = false
            triggerSub.addItem(note)
        }
        triggerMenu.submenu = triggerSub
        menu.addItem(triggerMenu)

        let language = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let current = Locale(identifier: localeID).identifier(.bcp47)
        for locale in supportedLocales.sorted(by: { Self.name($0) < Self.name($1) }) {
            let item = NSMenuItem(title: Self.name(locale), action: #selector(pickLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = locale.identifier
            item.state = locale.identifier(.bcp47) == current ? .on : .off
            sub.addItem(item)
        }
        language.submenu = sub
        menu.addItem(language)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        if !Paster.hasAccessibility {
            let ax = NSMenuItem(title: "Grant Accessibility (needed to paste)…", action: #selector(grantAccessibility), keyEquivalent: "")
            ax.target = self
            menu.addItem(ax)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private static func name(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    @objc private func toggleFromMenu() {
        // Let the menu close first so the previously focused app is frontmost again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.toggle() }
    }
    @objc private func copyLast() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastText, forType: .string)
    }
    @objc private func toggleCleanup() { cleanupEnabled.toggle() }
    @objc private func toggleWakeWord() {
        wakeWordEnabled.toggle()
        hud.flash(wakeWordEnabled ? "Say “Hey Murmur” to start. The mic stays on while listening."
                                  : "Wake word off", seconds: 3)
    }
    @objc private func editRules() { Rules.ensureFileExists(); NSWorkspace.shared.open(Rules.fileURL) }
    @objc private func revealRules() { Rules.ensureFileExists(); NSWorkspace.shared.activateFileViewerSelecting([Rules.fileURL]) }
    @objc private func grantAccessibility() { Paster.requestAccessibility() }
    @objc private func openInputMonitoring() {
        KeyMonitor.requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func pickTrigger(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = TriggerKey(rawValue: raw) else { return }
        triggerKey = key
        hud.flash("Hold \(key.shortName) to dictate")
    }
    @objc private func pickLanguage(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, state == .idle else { return }
        localeID = id
        Task { await prepareSpeech() }
    }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            hud.flash("Launch at login failed: \(error.localizedDescription)", seconds: 4)
        }
    }

    private func refreshIcon() {
        statusItem.button?.image = Glyph.menuBarImage(recording: state == .recording)
        statusItem.button?.toolTip = "Murmur — ⌃Space or hold \(triggerKey.shortName) to dictate"
    }
}
