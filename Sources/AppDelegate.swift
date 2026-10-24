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
    private var editKey: HotKey?
    private let wake = WakeWordListener()
    private let history = History.shared
    private lazy var settingsWindow = SettingsWindowController(app: self)
    private lazy var setupWindow = SetupWindowController(app: self)
    private var state: State = .preparing {
        didSet {
            refreshIcon()
            syncWakeListener()
            if state == .idle { editMode = false }
        }
    }
    private var lastText = ""
    private(set) var statusLine = "Preparing speech model…"
    private(set) var supportedLocales: [Locale] = []

    // Gesture state: hold = push-to-talk, quick double-tap = hands-free until tapped again or silence.
    private let holdDelay: Duration = .milliseconds(250)
    private let doubleTapWindow: TimeInterval = 0.45
    private var holdTask: Task<Void, Never>?
    private var startTask: Task<Bool, Never>?
    private var keyMonitorTask: Task<Void, Never>?
    private var prepareRetry: Task<Void, Never>?
    private var prepareAttempt = 0
    private var triggerHeld = false
    private var startedByHold = false
    private var latched = false
    private var ignoreNextUp = false
    private var lastTapUp: Date?
    private var silence = SilenceDetector(now: Date())

    // What the current recording is for.
    private var editMode = false
    private var targetApp: [String] = []
    private var activeRules = Rules()

    private let defaults = UserDefaults.standard
    var cleanupEnabled: Bool {
        get { defaults.object(forKey: "cleanup") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "cleanup") }
    }
    var localeID: String {
        get { defaults.string(forKey: "locale") ?? Locale.current.identifier }
        set { defaults.set(newValue, forKey: "locale") }
    }
    var wakeWordEnabled: Bool {
        get { defaults.bool(forKey: "wakeWord") }
        set { defaults.set(newValue, forKey: "wakeWord"); syncWakeListener() }
    }
    var spokenCommandsEnabled: Bool {
        get { defaults.object(forKey: "spokenCommands") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "spokenCommands") }
    }
    var historyEnabled: Bool {
        get { defaults.bool(forKey: "history") }
        set { defaults.set(newValue, forKey: "history") }
    }
    var livePreviewEnabled: Bool {
        get { defaults.bool(forKey: "livePreview") }
        set { defaults.set(newValue, forKey: "livePreview") }
    }
    var verboseLogEnabled: Bool {
        get { defaults.bool(forKey: "verboseLog") }
        set { defaults.set(newValue, forKey: "verboseLog") }
    }
    var triggerKey: TriggerKey {
        get { TriggerKey(rawValue: defaults.string(forKey: "trigger") ?? "") ?? .rightOption }
        set { defaults.set(newValue.rawValue, forKey: "trigger"); keys.trigger = newValue }
    }
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                hud.flash("Launch at login failed: \(error.localizedDescription)", seconds: 4)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two copies would fight over the same hotkeys and microphone.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains(where: { $0 != NSRunningApplication.current && !$0.isTerminated }) {
            Log.write("launch: another Murmur is already running, quitting")
            NSApp.terminate(nil)
            return
        }

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
        // ⌃⌥Space: select text, press, say how to change it.
        editKey = HotKey(keyCode: kVK_Space, modifiers: controlKey | optionKey) { [weak self] in
            Task { @MainActor in self?.toggleEdit() }
        }
        Log.write("launch: ⌃⌥Space edit hotkey \(editKey == nil ? "NOT registered (taken)" : "registered")")

        wake.onWake = { [weak self] in
            DispatchQueue.main.async { self?.wakeHeard() }
        }
        dictation.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.handleLevel(level) }
        }
        dictation.onInterrupted = { [weak self] in
            DispatchQueue.main.async { self?.inputDeviceChanged() }
        }
        dictation.onPartial = { [weak self] text in
            DispatchQueue.main.async { self?.showPartial(text) }
        }
        observeSleepAndWake()

        Task {
            _ = await Dictation.requestMicrophone()
            await prepareSpeech()
        }
        // Permissions are requested from the setup window, the menu, or on first paste.
        if !defaults.bool(forKey: "onboardingDone") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showSetup() }
        }
    }

    /// The key listener needs Input Monitoring; keep retrying so granting it takes effect without a relaunch.
    private func startKeyMonitor() {
        keyMonitorTask?.cancel()
        keyMonitorTask = nil
        if keys.start() { return }
        if !KeyMonitor.hasPermission, !defaults.bool(forKey: "askedInputMonitoring"), defaults.bool(forKey: "onboardingDone") {
            defaults.set(true, forKey: "askedInputMonitoring")
            KeyMonitor.requestPermission()
        }
        keyMonitorTask = Task {
            while !Task.isCancelled, !keys.start() {
                try? await Task.sleep(for: .seconds(2))
            }
            if !Task.isCancelled { hud.flash("Ready: hold \(triggerKey.shortName) to dictate") }
        }
    }

    // MARK: Sleep and wake

    private func observeSleepAndWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.willSleep() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.didWake() }
        }
    }

    private func willSleep() {
        Log.write("system: going to sleep")
        if state == .recording { cancelRecording() }
        wake.stop()
    }

    /// The event tap and audio hardware can be stale after sleep; rebuild them instead of trusting them.
    private func didWake() {
        Log.write("system: woke from sleep")
        Task {
            try? await Task.sleep(for: .seconds(2)) // let the audio devices settle
            keys.stop()
            startKeyMonitor()
            syncWakeListener()
        }
    }

    private func inputDeviceChanged() {
        guard state == .recording else { return }
        Log.write("audio: input device changed while recording, finishing with what was heard")
        latched = false
        startedByHold = false
        stopRecording()
    }

    private func showPartial(_ text: String) {
        guard state == .recording, livePreviewEnabled, !editMode else { return }
        hud.showLive(text)
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
        switch silence.update(level: level, now: Date(), latched: latched) {
        case .keepGoing: break
        case .stop:
            latched = false
            stopRecording()
        case .cancel:
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

    /// Prepares the speech model. If that fails for a reason that can fix itself (offline on first launch),
    /// it tries again with growing pauses instead of waiting for the user to notice.
    private func prepareSpeech() async {
        prepareRetry?.cancel()
        prepareRetry = nil
        state = .preparing
        supportedLocales = await Array(SpeechTranscriber.supportedLocales)
        do {
            try await dictation.prepare(locale: Locale(identifier: localeID)) { [weak self] message in
                Task { @MainActor in self?.statusLine = message; self?.hud.showBusy(message) }
            }
            statusLine = "Ready"
            prepareAttempt = 0
            Log.write("speech model ready; mic permission \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue), accessibility \(Paster.hasAccessibility), input monitoring \(KeyMonitor.hasPermission)")
            state = .idle
            hud.hide()
        } catch {
            statusLine = error.localizedDescription
            state = .idle
            if prepareAttempt == 0 { hud.flash(error.localizedDescription, seconds: 5) }
            Log.write("speech model not ready: \(error.localizedDescription)")
            if case DictationError.unsupportedLanguage = error { return } // will not fix itself
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        let delays = [5, 15, 30, 60]
        let delay = delays[min(prepareAttempt, delays.count - 1)]
        prepareAttempt += 1
        statusLine += " Retrying in \(delay) s…"
        prepareRetry = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await prepareSpeech()
        }
    }

    /// Start/stop from ⌃Space or the menu.
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

    /// ⌃⌥Space: the same, but what you say is an instruction for the text you have selected.
    private func toggleEdit() {
        switch state {
        case .idle:
            latched = true
            startRecording(edit: true)
        case .recording:
            latched = false
            stopRecording()
        case .preparing: hud.flash(statusLine)
        case .processing: NSSound.beep()
        }
    }

    private func startRecording(edit: Bool = false) {
        guard dictation.isReady else {
            latched = false
            hud.flash(statusLine); return
        }
        if Paster.focusedFieldIsSecure() {
            latched = false
            hud.flash("Murmur won't dictate into password fields", seconds: 3)
            return
        }
        targetApp = Paster.frontmostAppNames()
        activeRules = Rules.load(appNames: targetApp)
        editMode = edit
        state = .recording
        silence.reset(now: Date())
        hud.showListening(hint: edit ? "Say how to change the selected text"
                                     : (latched ? "Pause or press ⌃Space to finish" : "Release to finish"))
        escapeKey = HotKey(keyCode: kVK_Escape, modifiers: 0) { [weak self] in
            Task { @MainActor in self?.cancelRecording() }
        }
        let vocabulary = activeRules.vocabulary
        let live = livePreviewEnabled && !edit
        startTask = Task {
            do {
                try await dictation.start(vocabulary: vocabulary, livePreview: live)
                return true
            } catch {
                escapeKey = nil
                latched = false
                state = .idle
                hud.flash(error.localizedDescription, seconds: 4)
                Log.write("start failed: \(error.localizedDescription)")
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
        let editing = editMode
        let rules = activeRules
        let appName = targetApp.first ?? ""
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
                if editing {
                    await finishEdit(instruction: raw)
                    return
                }
                let useModel = cleanupEnabled
                if useModel { hud.showBusy("Polishing…") }
                var text = await Cleaner.clean(raw, rules: rules, useModel: useModel)
                text = rules.applySnippets(to: text)
                if spokenCommandsEnabled { text = SpokenFormatting.apply(text) }
                lastText = text
                if historyEnabled {
                    history.append(HistoryEntry(date: Date(), app: appName, text: text))
                }
                guard !Paster.focusedFieldIsSecure() else {
                    state = .idle
                    hud.flash("Not pasting into a password field. “Copy Last Dictation” has your text.", seconds: 5)
                    return
                }
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
                Log.write("dictation failed: \(error.localizedDescription)")
            }
        }
    }

    /// The spoken words were an instruction: rewrite the selected text with it and paste the result over the selection.
    private func finishEdit(instruction: String) async {
        hud.showBusy("Editing…")
        guard Cleaner.modelAvailable else {
            state = .idle
            hud.flash("Editing needs Apple Intelligence. \(Cleaner.unavailableReason)", seconds: 5)
            return
        }
        guard let selection = await Paster.selectedText() else {
            state = .idle
            hud.flash("Select some text first, then say how to change it.", seconds: 4)
            return
        }
        guard let edited = await Cleaner.edit(selection, instruction: instruction) else {
            state = .idle
            hud.flash("Couldn't edit that, so the text is unchanged.", seconds: 4)
            return
        }
        guard !Paster.focusedFieldIsSecure() else {
            state = .idle
            hud.flash("Not editing inside a password field.", seconds: 3)
            return
        }
        lastText = edited
        let pasted = await Paster.paste(edited)
        state = .idle
        if pasted { hud.hide() } else { hud.flash("Copied the edited text. Press ⌘V to replace the selection.", seconds: 5) }
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
        if editKey != nil {
            let editHint = NSMenuItem(title: "⌃⌥Space to edit selected text by voice", action: nil, keyEquivalent: "")
            editHint.isEnabled = false
            menu.addItem(editHint)
        }
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

        if historyEnabled {
            let historyMenu = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let recent = history.recent(10)
            if recent.isEmpty {
                let none = NSMenuItem(title: "No dictations yet", action: nil, keyEquivalent: "")
                none.isEnabled = false
                sub.addItem(none)
            }
            for entry in recent {
                let flat = entry.text.replacingOccurrences(of: "\n", with: " ")
                let title = flat.count > 60 ? String(flat.prefix(60)) + "…" : flat
                let item = NSMenuItem(title: title, action: #selector(copyHistoryEntry(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.text
                sub.addItem(item)
            }
            sub.addItem(.separator())
            let clear = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
            clear.target = self
            sub.addItem(clear)
            historyMenu.submenu = sub
            menu.addItem(historyMenu)
        }
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
        login.state = launchAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let setup = NSMenuItem(title: "Setup & Permissions…", action: #selector(showSetupFromMenu), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)
        let diagnostics = NSMenuItem(title: "Copy Diagnostics", action: #selector(copyDiagnostics), keyEquivalent: "")
        diagnostics.target = self
        menu.addItem(diagnostics)

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

    // MARK: Actions (also used by the settings and setup windows)

    func changeTriggerKey(_ key: TriggerKey) {
        triggerKey = key
        hud.flash("Hold \(key.shortName) to dictate")
    }

    func changeLanguage(_ id: String) {
        guard state == .idle || state == .preparing else { return }
        localeID = id
        prepareAttempt = 0
        Task { await prepareSpeech() }
    }

    func openRulesFile() {
        Rules.ensureFileExists()
        NSWorkspace.shared.open(Rules.fileURL)
    }

    func clearHistoryNow() { history.clear() }

    func showSetup() {
        defaults.set(true, forKey: "onboardingDone")
        setupWindow.show()
    }

    @objc private func showSettings() { settingsWindow.show() }
    @objc private func showSetupFromMenu() { showSetup() }
    @objc private func toggleFromMenu() {
        // Let the menu close first so the previously focused app is frontmost again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.toggle() }
    }
    @objc private func copyLast() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastText, forType: .string)
    }
    @objc private func copyHistoryEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    @objc private func clearHistory() { history.clear() }
    @objc private func toggleCleanup() { cleanupEnabled.toggle() }
    @objc private func toggleWakeWord() {
        wakeWordEnabled.toggle()
        hud.flash(wakeWordEnabled ? "Say “Hey Murmur” to start. The mic stays on while listening."
                                  : "Wake word off", seconds: 3)
    }
    @objc private func editRules() { openRulesFile() }
    @objc private func revealRules() { Rules.ensureFileExists(); NSWorkspace.shared.activateFileViewerSelecting([Rules.fileURL]) }
    @objc private func grantAccessibility() { Paster.requestAccessibility() }
    @objc private func openInputMonitoring() {
        KeyMonitor.requestPermission()
        Permissions.openSettings(.inputMonitoring)
    }
    @objc private func pickTrigger(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = TriggerKey(rawValue: raw) else { return }
        changeTriggerKey(key)
    }
    @objc private func pickLanguage(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        changeLanguage(id)
    }
    @objc private func toggleLogin() { launchAtLogin.toggle() }

    @objc private func checkForUpdates() {
        hud.flash("Checking for updates…", seconds: 10)
        Task {
            do {
                let release = try await Updater.checkLatest()
                if Updater.isNewer(release.version, than: Updater.currentVersion) {
                    hud.flash("Murmur \(release.version) is available.", seconds: 4)
                    NSWorkspace.shared.open(release.page)
                } else {
                    hud.flash("You have the latest version (\(Updater.currentVersion)).", seconds: 3)
                }
            } catch {
                hud.flash("Couldn't check for updates: \(error.localizedDescription)", seconds: 4)
            }
        }
    }

    @objc private func copyDiagnostics() {
        let settings: [String: String] = [
            "cleanup": "\(cleanupEnabled)", "locale": localeID, "wakeWord": "\(wakeWordEnabled)",
            "trigger": triggerKey.rawValue, "spokenCommands": "\(spokenCommandsEnabled)",
            "history": "\(historyEnabled)", "livePreview": "\(livePreviewEnabled)",
            "appleIntelligence": Cleaner.modelAvailable ? "available" : Cleaner.unavailableReason,
            "keyMonitorRunning": "\(keys.isRunning)", "toggleHotkey": toggleKey == nil ? "taken" : "ok",
            "editHotkey": editKey == nil ? "taken" : "ok",
        ]
        let permissions = [
            "Microphone": Permissions.microphone.label,
            "Input Monitoring": Permissions.inputMonitoring.label,
            "Accessibility": Permissions.accessibility.label,
        ]
        let stateName = "\(state)"
        let report = Diagnostics.report(state: "\(stateName) · \(statusLine)", settings: settings,
                                        logTail: Log.tail(40), permissions: permissions)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        hud.flash("Diagnostics copied. Paste them into a bug report.", seconds: 3)
    }

    private func refreshIcon() {
        statusItem.button?.image = Glyph.menuBarImage(recording: state == .recording)
        statusItem.button?.toolTip = "Murmur — ⌃Space or hold \(triggerKey.shortName) to dictate"
    }
}
