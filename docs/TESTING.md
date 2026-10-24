# Testing Murmur

## Automated

```bash
./test.sh
```

Compiles every file in `Sources/` (except `main.swift`) with `Tests/main.swift` and runs the checks: wake-phrase matching, rules parsing, replacements, snippets, per-app sections, spoken formatting, cleanup chunking, silence detection, history storage, log rotation, version comparison and diagnostics scrubbing. It exits non-zero if anything fails. No audio, permissions or Apple Intelligence are needed.

What the automated tests **cannot** cover is microphone capture, the speech recognizer, the language model, the event tap, pasting and the windows. Those need the checklist below.

## Manual soak checklist (run before each release)

Use a signed build installed in `/Applications`, on macOS 26, and watch `~/Library/Logs/Murmur.log`.

**Core**
- [ ] Hold the trigger key, speak, release: cleaned text is pasted (try Notes, Safari, a terminal).
- [ ] Double-tap for hands-free; it ends on a tap, on ⌃Space, and after ~2.5 s of silence.
- [ ] Escape cancels; nothing is pasted.
- [ ] A dictation of 2–3 minutes (several thousand characters) completes and is cleaned throughout.

**Stability**
- [ ] Connect or disconnect AirPods (or change the input device) *while recording*: recording ends cleanly, text so far is pasted, and the next dictation works.
- [ ] Same with the wake word on: "Hey Murmur" still works after the device change.
- [ ] Close the lid, wake the Mac: hold-to-talk and the wake word work without relaunching.
- [ ] First launch with Wi-Fi off: the HUD shows an error; turn Wi-Fi on; within about a minute Murmur says it is ready by itself.
- [ ] Force a failure (revoke the microphone in System Settings, dictate, restore it, dictate again): no crash.
- [ ] Apple Intelligence off: dictation still works with basic cleanup and the menu explains why.
- [ ] Start a second copy of the app: it quits immediately.
- [ ] Leave it running a day with the wake word on: memory stays flat; `Murmur.log` stays under ~1 MB.

**Safety and privacy**
- [ ] Focus a password field (a website login, System Settings): hold the trigger. Murmur refuses to dictate and pastes nothing.
- [ ] With history off, nothing is written to `~/Library/Application Support/Murmur/history.jsonl`.
- [ ] *Copy Diagnostics* contains no dictated text and no `/Users/<name>` path.
- [ ] With "Log what the wake word hears" off, `Murmur.log` contains `wake: MATCH` lines but not speech.

**Features**
- [ ] Rules: a `vocabulary:` line improves recognition of a name; a snippet expands; a `[Mail]` section applies only in Mail.
- [ ] "new line" and "new paragraph" insert breaks; turning *Spoken commands* off disables them.
- [ ] History (turned on): entries appear in the menu, click copies, *Clear History* empties it.
- [ ] Live text (turned on): the pill shows words while speaking; the final pasted text has no duplicated words.
- [ ] Edit by voice: select a sentence, press ⌃⌥Space, say "make this shorter", press ⌃⌥Space again: the selection is replaced. With nothing selected it says so and changes nothing.
- [ ] Setup window: reflects live permission status; Settings window toggles take effect immediately.
- [ ] *Check for Updates…* reports the current version when up to date.

**Release artifact**
- [ ] `spctl --assess --type open --context context:primary-signature -v build/Murmur-<version>.dmg` accepts it.
- [ ] On a second Mac (or a fresh user account) the DMG opens without a Gatekeeper warning, and permissions persist after updating to the next build.
