# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Murmur is a macOS menu-bar dictation app (Swift, AppKit, no Xcode project / SwiftPM). Hold a trigger key (default Right ⌥), press ⌃Space, or say "Hey Murmur" → speech is transcribed on-device, cleaned up with Apple Intelligence, and pasted into the focused app. Audio never leaves the Mac. Requires macOS 26 (SpeechAnalyzer, FoundationModels) on Apple Silicon.

## Build & run

There is no package manifest or linter. Everything is built by one script that calls `swiftc` directly on `Sources/*.swift`:

```bash
./build.sh              # builds build/Murmur.app (wipes build/ first), ad-hoc codesigned
./build.sh --install    # also kills the running Murmur, replaces /Applications/Murmur.app
./test.sh               # unit tests: compiles Sources/*.swift (minus main.swift) with Tests/main.swift
./release.sh            # signed + notarized DMG (needs MURMUR_SIGN_IDENTITY, MURMUR_NOTARY_PROFILE; see docs/RELEASING.md)
```

- `Tests/main.swift` has a tiny `check`/`expect` harness. Put new logic in pure types and add checks there; audio, hotkeys, pasting and windows are checked by hand (`docs/TESTING.md`).
- Under the Claude sandbox, `swift Tools/make_icon.swift` (used by `build.sh`) and writes to `.git` need the sandbox off; `./test.sh` runs fine inside it.

- New source files in `Sources/` are picked up automatically by the glob; new frameworks must be added to the `-framework` list in `build.sh`.
- The icon is generated at build time by `Tools/make_icon.swift` (run as a script) → `iconutil`. `build/` is fully generated output.
- Ad-hoc signing (the default) means macOS TCC permissions (Microphone, Speech, Input Monitoring, Accessibility) can reset after rebuilds; the identifier is pinned to `com.vinoth.murmur` to help.
- `Info.plist` sets `LSUIElement` (no Dock icon) and the mic/speech usage strings.
- Diagnostics: `~/Library/Logs/Murmur.log` (via `Log.write`). User rules live at `~/Library/Application Support/Murmur/rules.md`.

## Architecture

`main.swift` just boots `NSApplication` (accessory policy) with `AppDelegate`, which is the single `@MainActor` coordinator and owns a small state machine (`preparing → idle → recording → processing`). Everything else is a focused helper:

- **Trigger input (two independent paths feeding the same start/stop logic in `AppDelegate`)**
  - `KeyMonitor` – listen-only `CGEventTap` for a modifier-only trigger key (`TriggerKey` enum: keyCode + device-dependent flag mask). Needs Input Monitoring; `AppDelegate.startKeyMonitor` retries every 2 s so granting permission works without relaunch. Another key pressed while the trigger is held cancels the gesture (so ⌥E etc. still work).
  - `HotKey` – Carbon `RegisterEventHotKey` wrapper (no permission needed, swallows the combo). Used for ⌃Space (toggle) and Escape (cancel, registered only while recording). Returns nil if the combo is already taken.
  - Gesture logic in `AppDelegate` (`triggerDown/Up`): hold >250 ms = push-to-talk; double-tap within 0.45 s = "latched" hands-free mode, which ends on a tap, ⌃Space, or ~2.5 s of silence (level > 0.12 counts as voice; gives up after 12 s with no speech).
- **`Dictation`** – `AVAudioEngine` tap → `AVAudioConverter` to the analyzer's format → `SpeechAnalyzer`/`SpeechTranscriber` (on-device). `prepare()` resolves the locale and downloads the speech asset; `start()/stop()/cancel()` run per utterance. `onLevel` fires on the audio thread (AppDelegate hops to main).
- **`WakeWordListener` / `WakePhrase`** – separate always-on `SpeechTranscriber` session (volatile results, recycled every 120 s) that fuzzy-matches "Hey Murmur" via edit distance. It only runs while state is `.idle` (`syncWakeListener`, triggered by the `state` didSet) because it and `Dictation` share the one mic; on a match it releases the mic and `onWake` starts a latched recording.
- **`Cleaner` + `Rules`** – after transcription: Apple Intelligence (`LanguageModelSession`, 20 s timeout, output sanity-length-checked) → falls back to regex `basicCleanup` if the model is unavailable → then `Rules.applyReplacements` always runs, so `"heard" -> "written"` lines are guaranteed even if the model ignores them. `Rules` parses a user-editable text file: `#` comments, `"a" -> "b"` literal replacements (whole-word, case-insensitive), any other line = free-form instruction injected into the model prompt.
- **`Paster`** – puts text on the pasteboard (marked transient for clipboard managers), synthesizes ⌘V via `CGEvent` (needs Accessibility; waits for the Option key to be released first), then restores the user's prior clipboard after 700 ms if nobody else changed it. Without Accessibility it leaves text on the clipboard and the HUD says so.
- **`HUD`** – non-activating floating panel (never steals focus from the target field). `Glyph` draws the menu-bar icon.

Settings are plain `UserDefaults` keys on `AppDelegate` (`cleanup`, `locale`, `wakeWord`, `trigger`, `spokenCommands`, `history`, `livePreview`, `verboseLog`, `onboardingDone`, `askedAccessibility`, `askedInputMonitoring`); the status-bar menu is rebuilt from scratch on every open in `menuNeedsUpdate`. `SetupWindow` / `SettingsWindow` are AppKit windows that read and write those properties through `AppDelegate`.

Reliability rules that exist for a reason (see `docs/ARCHITECTURE.md` §20): the audio tap closure must never touch `self`; a failed `Dictation.start()` must `teardown()`; sleep/wake rebuilds the event tap; dictation and paste are refused in password fields; cleanup runs in chunks.

`Rules` also understands `"phrase" => "text"` snippets, `vocabulary:` lines and `[App]` sections; rules are loaded when a recording starts, for the frontmost app. `SilenceDetector`, `SpokenFormatting`, `History`, `Updater`, `Diagnostics` and `Permissions` are small helpers; the only network request in the app is `Updater.checkLatest()`, triggered from the menu.

## Conventions worth knowing

- Swift 5 language mode (`-swift-version 5`) with the `AppDelegate` marked `@MainActor`; callbacks from audio/CGEvent/Carbon threads hop to main with `Task { @MainActor in … }` or `DispatchQueue.main.async` — keep that pattern when adding callbacks.
- Permissions are requested lazily (menu item or first paste), not on every launch.
