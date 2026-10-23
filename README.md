# Murmur

A macOS menu-bar **dictation app**. Hold a key (or say "Hey Murmur"), speak, and the text is transcribed on your Mac, tidied up by Apple Intelligence, and pasted into whatever app you're using.

- **Private by design:** speech recognition and text cleanup both run on-device. There is no network code and no account.
- **Fast to use:** hold **Right ⌥** to talk, double-tap for hands-free, or press **⌃Space**.
- **Cleans up after you:** removes "um"/"uh", stutters and false starts, fixes punctuation, and applies your own rules (e.g. `"git hub" -> "GitHub"`).
- **Works in any app:** native apps, browsers, Electron — it pastes into the focused field.

> Murmur is built with plain `swiftc` — no Xcode project, no dependencies.
> For how it works inside, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

---

## Requirements

| Requirement | Why |
|---|---|
| **macOS 26 (Tahoe) or later** | Uses `SpeechAnalyzer` and `FoundationModels`, which first shipped in macOS 26 |
| **Apple Silicon Mac** (M-series) | Build target is `arm64` |
| **Xcode 26 or the Xcode Command Line Tools** | Provides `swiftc`, `codesign`, `iconutil` |
| *Optional:* **Apple Intelligence** turned on | Enables the smart cleanup. Without it Murmur falls back to a simpler regex cleanup |

Check your tooling:

```bash
swiftc --version
xcode-select -p
```

If either command fails, install the command line tools with `xcode-select --install`.

---

## Install

Murmur is distributed as source. Building takes a few seconds.

```bash
git clone https://github.com/vinoth12940/Murmur.git
cd Murmur
./build.sh --install
```

`--install` builds the app, then copies it to `/Applications/Murmur.app`. Open it from Spotlight or Finder; an icon appears in the menu bar (there is no Dock icon).

Prefer not to install? Run `./build.sh` and open `build/Murmur.app` directly.

### First launch

1. **Microphone** and **Speech Recognition** — allow when macOS asks.
2. Murmur downloads the on-device speech model for your language (the HUD says "Downloading speech model…"). This happens once per language.
3. **Input Monitoring** — needed for the hold-to-talk key. Click the menu-bar icon → *Allow Input Monitoring…* and enable Murmur in *System Settings → Privacy & Security → Input Monitoring*. It starts working without a relaunch.
4. **Accessibility** — needed so Murmur can press ⌘V for you. Click the icon → *Grant Accessibility (needed to paste)…*. Without it, your text is left on the clipboard and you paste with ⌘V yourself.

Permissions are only requested when needed, never all at once.

---

## Using Murmur

| Gesture | What happens |
|---|---|
| **Hold Right ⌥** (> ¼ second) | Push-to-talk. Release to finish |
| **Double-tap Right ⌥** | Hands-free. Tap again to finish, or just pause (~2.5 s) |
| **⌃Space** | Start; press again to stop |
| **Say "Hey Murmur"** | Hands-free (turn on in the menu — see below) |
| **Esc** (while recording) | Cancel |
| Menu → *Start Dictation* | Same as ⌃Space |

Pressing another key while holding the trigger (like ⌥E) cancels the gesture, so your normal shortcuts keep working.

### Menu options

- **Wake Word: say "Hey Murmur"** — off by default. When on, the microphone stays open while Murmur is idle so it can hear the phrase. Audio is processed on-device and discarded.
- **Clean Up with Apple Intelligence** — toggle smart cleanup. If off, you get the raw transcript (plus your replacement rules).
- **Edit Rules File… / Show Rules in Finder** — see below.
- **Trigger Key** — Right ⌥ (default), Fn/Globe, Right ⌘, or Right ⌃. For Fn, set *System Settings → Keyboard → "Press 🌐 key to" → Do Nothing*.
- **Language** — any language supported by on-device speech recognition.
- **Launch at Login**.
- **Copy Last Dictation**.

### Custom rules

Your rules live in `~/Library/Application Support/Murmur/rules.md` (created on first launch, re-read on every dictation, no restart needed).

```text
# Comments start with #

# Plain-language rules (sent to the on-device model):
Write numbers under ten as words and everything else as digits.
Use American English spelling.

# Exact replacements, "heard" -> "written" (whole words, case-insensitive):
"open ai" -> "OpenAI"
"git hub" -> "GitHub"
```

Replacement lines are applied literally after cleanup, so they always take effect, even if the model ignores them.

---

## Privacy

- Audio is captured only while you are dictating (or while the optional wake word is enabled), and is transcribed by Apple's on-device speech model. It is never uploaded or saved.
- Cleanup uses Apple's on-device language model. No text is sent to a server.
- Murmur makes no network requests of its own. (macOS itself downloads the speech model the first time you use a language.)
- Your last dictation is kept in memory only, for *Copy Last Dictation*.
- While pasting, Murmur temporarily replaces your clipboard with the dictated text, marks it transient so clipboard managers skip it, and restores your previous clipboard afterwards.
- **Diagnostic log:** `~/Library/Logs/Murmur.log` stays on your Mac. It records app events and, **only when the wake word is enabled**, the first ~60 characters of what the recognizer heard while listening. Delete the file any time, or leave the wake word off.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Holding the key does nothing | Grant **Input Monitoring** (menu shows *Allow Input Monitoring…* when it's missing). ⌃Space works without it |
| ⌃Space doesn't work; HUD warns at launch | macOS owns it. Disable *System Settings → Keyboard → Keyboard Shortcuts → Input Sources → "Select the previous input source"* |
| Text is copied but not pasted | Grant **Accessibility** |
| Permissions were lost after rebuilding | Builds are ad-hoc signed, so macOS may treat each rebuild as a new app. Re-enable Murmur in *Privacy & Security*; if it still misbehaves, remove the old entry with **−** and add it again |
| Cleanup seems basic | Menu shows why (Apple Intelligence off, still downloading, or unsupported Mac) |
| Language is unsupported | Pick another in the *Language* menu; availability depends on macOS |
| "Hey Murmur" misfires or never fires | Look at `~/Library/Logs/Murmur.log` lines starting with `wake:` to see what was heard |

---

## Building, developing, uninstalling

```bash
./build.sh              # build/Murmur.app (wipes build/ first)
./build.sh --install    # also replaces /Applications/Murmur.app
```

- Sources live in `Sources/*.swift`; new files are picked up automatically. New system frameworks must be added to the `-framework` list in `build.sh`.
- There is no test suite; check behaviour by running the app and reading `~/Library/Logs/Murmur.log`.
- The app icon is generated at build time by `Tools/make_icon.swift`.
- Architecture, diagrams and design decisions: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

**Uninstall:** quit Murmur from its menu, then:

```bash
rm -rf /Applications/Murmur.app
rm -rf ~/Library/Application\ Support/Murmur ~/Library/Logs/Murmur.log
defaults delete com.vinoth.murmur
```

Finally remove Murmur from *Privacy & Security* (Microphone, Input Monitoring, Accessibility) if listed.

---

## Contributing

Issues and pull requests are welcome. Please keep changes small and focused, follow the existing code style, and note which macOS version you tested on. The architecture doc explains where things live and the threading conventions (callbacks from audio/event threads must hop to the main actor).

## License

[MIT](LICENSE)
