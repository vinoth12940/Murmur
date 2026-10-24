# Murmur Production Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Murmur stable and releasable (Stage 1 and 2), then add the highest-value Wispr Flow-style features (Stage 3) without breaking the on-device/no-account promise.

**Architecture:** Keep the single `@MainActor` `AppDelegate` coordinator and the existing helper types. Pure logic (silence detection, rules parsing, chunking, formatting, version compare) moves into small testable types; a dependency-free `test.sh` compiles `Sources/*.swift` (minus `main.swift`) with `Tests/main.swift`. Release tooling is plain shell (`swiftc`, `codesign`, `notarytool`, `hdiutil`); there is still no SwiftPM or third-party dependency.

**Tech Stack:** Swift 5 mode, AppKit, AVFoundation, Speech (`SpeechAnalyzer`), FoundationModels, zsh, GitHub Actions.

**Spec:** the conversation: the gap analysis in `docs/ARCHITECTURE.md` plus the three-stage list the user approved ("implement all three stages").

## Global Constraints

- macOS 26+, Apple Silicon, `-swift-version 5`, `-target arm64-apple-macosx26.0`.
- No third-party dependencies; no background network access. The only network call allowed is a **user-initiated** "Check for Updates…" request to the GitHub Releases API.
- Audio and text never leave the Mac; no telemetry or automatic crash reporting.
- Bundle identifier stays `com.vinoth.murmur`.
- Callbacks from audio/CGEvent/Carbon threads hop to main with `Task { @MainActor in … }` or `DispatchQueue.main.async`.
- New files in `Sources/` are picked up by the glob; new frameworks go in `build.sh`.
- No signing secrets, Team IDs or personal emails are committed; signing is driven by environment variables.
- Defaults for new behaviour must preserve current behaviour (history off, live preview off, secure-field protection on).

## Review Focus

1. Mic or input device changes mid-recording (AirPods connect): recording ends cleanly with the text so far; no crash.
2. `Dictation.start()` throws after the tap is installed: the next start succeeds (no duplicate-tap crash).
3. Mac sleeps/wakes: trigger key and wake word work again without relaunch.
4. First launch offline, then online: speech model prepares itself without relaunch.
5. Very long dictation (several thousand characters): cleaned in chunks; one failing chunk does not downgrade the rest.
6. Focus is in a password field: Murmur refuses to dictate there and never pastes into it.
7. Malformed rules file (unterminated quotes, empty phrases, huge file): never crashes, bad lines become instructions or are skipped.

---

## Stage 1: Stability

### Task 1: Logging that cannot grow or leak

**Files:** Modify `Sources/Log.swift`, `Sources/WakeWord.swift`; Test `Tests/main.swift`

**Interfaces:**
- Produces: `Log.write(_:)` (unchanged), `Log.rotateIfNeeded(url: URL, maxBytes: Int)` (static, testable), `Log.verbose: Bool` (reads `UserDefaults` key `verboseLog`, default false).

- [ ] Test: file of `maxBytes + 1` bytes is moved to `<name>.1` and a fresh file is created; a second rotation replaces `.1`.
- [ ] Implement rotation (512 KB) inside the log queue before each write.
- [ ] Wake listener logs heard text only when `Log.verbose`; always logs `wake: MATCH`.
- [ ] Commit.

### Task 2: Pure silence/no-speech detector

**Files:** Create `Sources/SilenceDetector.swift`; Modify `Sources/AppDelegate.swift` (`handleLevel`); Test `Tests/main.swift`

**Interfaces:**
- Produces:
  ```swift
  struct SilenceDetector {
      enum Decision { case keepGoing, stop, cancel }
      init(now: Date, voiceThreshold: Float = 0.12, silenceTimeout: TimeInterval = 2.5, noSpeechTimeout: TimeInterval = 12)
      mutating func reset(now: Date)
      mutating func update(level: Float, now: Date, latched: Bool) -> Decision
  }
  ```

- [ ] Tests: not latched → always `.keepGoing`; latched + speech then 2.6 s quiet → `.stop`; latched + 12.1 s no speech → `.cancel`; level 0.13 resets the silence clock; level exactly 0.12 is not voice.
- [ ] Implement; replace `heardSpeech/lastVoice/recordingStarted` in `AppDelegate`.
- [ ] Commit.

### Task 3: Dictation failure cleanup, thread safety, device changes

**Files:** Modify `Sources/Dictation.swift`, `Sources/AppDelegate.swift`

**Interfaces:**
- Produces: `Dictation.onInterrupted: (() -> Void)?` (main-thread callers only via AppDelegate hop); `Dictation.start()` leaves no tap, analyzer, task or continuation behind when it throws.

- [ ] In `start()`: capture `onLevel` and the continuation as locals for the tap closure (no shared mutable reads on the audio thread); `removeTap` before `installTap`; wrap everything after analyzer creation in `do/catch` that calls an internal `teardown()` then rethrows.
- [ ] Observe `.AVAudioEngineConfigurationChange` on the engine while recording; post `onInterrupted`. AppDelegate responds by `stopRecording()` with HUD hint "Microphone changed".
- [ ] Commit.

### Task 4: Wake word survives device changes

**Files:** Modify `Sources/WakeWord.swift`

- [ ] Add a configuration-change watcher task to the session's task group in `runSession`; when it fires the session ends (returns false) and the loop starts a new session with the new input format.
- [ ] Commit.

### Task 5: Sleep/wake, retry, single instance, key monitor restart

**Files:** Modify `Sources/KeyMonitor.swift`, `Sources/AppDelegate.swift`

**Interfaces:**
- Produces: `KeyMonitor.stop()`; `AppDelegate.prepareSpeech()` retries with backoff 5, 15, 30, 60 s (then every 60 s) until ready, cancelled when the language changes.

- [ ] `KeyMonitor.stop()` removes the run-loop source, disables and invalidates the tap, resets `isDown`.
- [ ] `NSWorkspace.willSleepNotification`: cancel an active recording, stop wake listener. `didWakeNotification`: `keys.stop()`, `startKeyMonitor()`, `syncWakeListener()`.
- [ ] Retry loop in `prepareSpeech` failure path; menu shows "Retrying…" status.
- [ ] On launch, if another process with the same bundle id is running, activate nothing and terminate.
- [ ] Commit.

### Task 6: Chunked cleanup

**Files:** Modify `Sources/Cleaner.swift`; Test `Tests/main.swift`

**Interfaces:**
- Produces: `Cleaner.chunks(_ text: String, maxChars: Int = 700) -> [String]` (splits on sentence ends, then spaces; never empty chunks; joined with a space reproduces the text modulo whitespace).

- [ ] Tests: short text → one chunk; 3000-char text → every chunk ≤ 700 (a single 900-char word is allowed alone); no empty chunks; unicode safe.
- [ ] `Cleaner.clean` polishes each chunk with its own 20 s timeout; a failed chunk uses `basicCleanup` for that chunk only.
- [ ] Commit.

### Task 7: Secure-field protection

**Files:** Modify `Sources/Paster.swift`, `Sources/AppDelegate.swift`

**Interfaces:**
- Produces: `Paster.focusedFieldIsSecure() -> Bool` (false when Accessibility is not granted or the focused element is unknown).

- [ ] Use `AXUIElementCreateSystemWide` → focused element → `AXSubrole == "AXSecureTextField"`.
- [ ] `startRecording()` refuses with HUD "Murmur won't dictate into password fields"; before paste the check runs again and leaves text on clipboard with a HUD hint instead of pasting.
- [ ] Commit.

---

## Stage 2: Release engineering

### Task 8: Tests runner and rules/wake/cleanup coverage

**Files:** Create `Tests/main.swift`, `test.sh`; Modify `Sources/Rules.swift`

**Interfaces:**
- Produces: `Rules.parse(_ text: String) -> Rules` (pure; `load()` calls it); `./test.sh` exits non-zero on any failed check.

- [ ] Tests: `WakePhrase.matches` accepts "hey murmur", "hey murmer", "k murmur", rejects "more", "hey more", "remember"; `distance("kitten","sitting") == 3`; `Rules.parse` handles comments, `"a" -> "b"`, curly quotes, empty `from`, missing `->`; `applyReplacements` is whole-word, case-insensitive, spaces match `\s+`; `basicCleanup("um so I I want uh to go")` == `"So I want to go"`.
- [ ] Implement `test.sh` (compile all `Sources/*.swift` except `main.swift` plus `Tests/main.swift` to `$TMPDIR`, run).
- [ ] Commit.

### Task 9: Versioning, signing, notarization, DMG

**Files:** Create `VERSION`, `Murmur.entitlements`, `release.sh`, `docs/RELEASING.md`; Modify `build.sh`, `Info.plist`

**Interfaces:**
- Produces: `./build.sh` accepts `MURMUR_SIGN_IDENTITY` (default ad-hoc `-`) and signs with hardened runtime + entitlements when an identity is given; `./release.sh` outputs `build/Murmur-<version>.dmg` and, when `MURMUR_NOTARY_PROFILE` is set, notarizes and staples app and DMG.

- [ ] `VERSION` holds `1.0.0`; `build.sh` writes it to `CFBundleShortVersionString` and the git commit count to `CFBundleVersion`.
- [ ] Entitlements: `com.apple.security.device.audio-input` only (app is intentionally not sandboxed: event tap + Accessibility).
- [ ] `release.sh` refuses to run without a `Developer ID Application` identity unless `--unsigned` is passed (for a local DMG test).
- [ ] Verify: ad-hoc and `--unsigned` DMG builds; `codesign --verify --strict` passes.
- [ ] Commit.

### Task 10: Update check (user-initiated) and diagnostics

**Files:** Create `Sources/Updater.swift`, `Sources/Diagnostics.swift`; Modify `Sources/AppDelegate.swift`; Test `Tests/main.swift`

**Interfaces:**
- Produces: `Updater.isNewer(_ remote: String, than local: String) -> Bool` (strips leading `v`, compares numeric components, missing = 0); `Updater.checkLatest() async throws -> (version: String, url: URL)`; `Diagnostics.report(state: String, settings: [String: String]) -> String` (no username paths, no transcripts).

- [ ] Tests: `isNewer("v1.2.0","1.1.9")`, `isNewer("1.0","1.0.0") == false`, `isNewer("1.0.1","1.0.0")`, garbage → false.
- [ ] Menu: "Check for Updates…" (opens release page if newer) and "Copy Diagnostics".
- [ ] Commit.

### Task 11: CI, release workflow, community files, Homebrew cask template

**Files:** Create `.github/workflows/ci.yml`, `.github/workflows/release.yml`, `.github/ISSUE_TEMPLATE/bug_report.md`, `.github/pull_request_template.md`, `SECURITY.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `docs/TESTING.md`, `packaging/homebrew/murmur.rb`

- [ ] CI: build + `./test.sh` on push/PR. Release workflow: on `v*` tag, import cert from secrets, run `release.sh`, upload DMG. Both are unverified until a macOS 26 runner is confirmed; say so in `docs/RELEASING.md`.
- [ ] `docs/TESTING.md`: manual soak checklist from Review Focus.
- [ ] Commit.

---

## Stage 3: Features

### Task 12: Vocabulary hints, snippets, per-app sections, spoken formatting

**Files:** Modify `Sources/Rules.swift`, `Sources/Dictation.swift`, `Sources/Cleaner.swift`; Create `Sources/SpokenFormatting.swift`; Test `Tests/main.swift`

**Interfaces:**
- Produces: `Rules.vocabulary: [String]` (from `vocabulary: A, B` lines plus every replacement target); `Rules.snippets: [(phrase: String, text: String)]` (from `"phrase" => "text"`, `\n` becomes newline); `Rules.load(forApp: String?) -> Rules` (lines after a `[App Name]` or `[bundle.id]` header apply only to that app, case-insensitive; before any header = all apps; `[default]` = all); `Rules.applySnippets(to:) -> String`; `SpokenFormatting.apply(_ text: String) -> String` ("new paragraph" → blank line, "new line" → newline, tolerating surrounding punctuation/spacing); `Dictation.start(vocabulary: [String])` sets `AnalysisContext.contextualStrings[.general]`.

- [ ] Tests: snippets expand whole phrases, consume one trailing `.` only at the end, keep case of replacement; app sections select by name and by bundle id; vocabulary merges both sources, dedupes; `SpokenFormatting` cases ("hello new line world", "Done. New paragraph. Next" → "Done.\n\nNext").
- [ ] Pipeline order in `AppDelegate.stopRecording`: transcript → `Cleaner.clean` (rules for the frontmost app captured at record start) → snippets → spoken formatting → paste.
- [ ] Commit.

### Task 13: Dictation history (local, off by default)

**Files:** Create `Sources/History.swift`; Modify `Sources/AppDelegate.swift`; Test `Tests/main.swift`

**Interfaces:**
- Produces: `History(fileURL: URL, limit: Int = 200)` with `append(_ entry: HistoryEntry)`, `recent(_ n: Int) -> [HistoryEntry]`, `clear()`; `HistoryEntry { date: Date; app: String; text: String }`; stored as JSON Lines in Application Support, file mode 0600.

- [ ] Tests: append/limit trimming, `recent` newest first, `clear` removes the file, corrupt lines skipped.
- [ ] Menu: "Save Dictation History" toggle (default off), "History" submenu (click copies), "Clear History".
- [ ] Commit.

### Task 14: First-run setup and Settings windows

**Files:** Create `Sources/Permissions.swift`, `Sources/SetupWindow.swift`, `Sources/SettingsWindow.swift`; Modify `Sources/AppDelegate.swift`

**Interfaces:**
- Produces: `Permissions.status` (mic, inputMonitoring, accessibility as `.granted/.missing/.notDetermined`); `SetupWindowController.show()` (rows with live status refresh every second and an action button per row, shown once automatically then from menu "Setup & Permissions…"); `SettingsWindowController.show()` (toggles for cleanup, wake word, spoken commands, history, verbose log, live preview, launch at login; popups for trigger key and language; button to edit rules).

- [ ] Compile-verified; manual check required (document in `docs/TESTING.md`).
- [ ] Commit.

### Task 15: Live preview and edit-selection-by-voice

**Files:** Modify `Sources/Dictation.swift`, `Sources/HUD.swift`, `Sources/Cleaner.swift`, `Sources/Paster.swift`, `Sources/AppDelegate.swift`; Test `Tests/main.swift`

**Interfaces:**
- Produces: `Dictation.onPartial: ((String) -> Void)?` (only when live preview is enabled; volatile results never enter the final transcript); `HUD.showLive(_ text: String)`; `Paster.selectedText() async -> String?` (AX selected text, else ⌘C with clipboard restore); `Cleaner.edit(_ selection: String, instruction: String) async -> String?` (rejects output longer than `selection.count * 4 + 200`); ⌃⌥Space starts an "edit" recording: speak an instruction, the selection is rewritten and pasted over itself.

- [ ] Tests: `Cleaner.editLengthOK`-style helper accepts/rejects at the boundary.
- [ ] Live preview and edit mode default off / hotkey registered only if free; both flagged "needs live-audio verification" in the changelog.
- [ ] Commit.

---

## Final verification

- [ ] `./test.sh` passes; `./build.sh` succeeds; `./release.sh --unsigned` produces a DMG; `codesign --verify --strict build/Murmur.app` passes.
- [ ] Update `README.md`, `CLAUDE.md`, `docs/ARCHITECTURE.md`, `CHANGELOG.md`.
- [ ] Push branch `production-readiness`, open a PR (do not merge).
