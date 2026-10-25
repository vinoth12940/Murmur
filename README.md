# Murmur

A macOS menu-bar **dictation app**. Hold a key (or say "Hey Murmur"), speak, and the text is transcribed on your Mac, tidied up by Apple Intelligence, and pasted into whatever app you're using.

- **Private by design:** speech recognition and text cleanup both run on-device. No account, no telemetry.
- **Fast to use:** hold **Right ⌥** to talk, double-tap for hands-free, or press **⌃Space**.
- **Cleans up after you:** removes "um"/"uh", stutters and false starts, fixes punctuation, and applies your own rules, snippets and per-app tone.
- **Works in any app:** native apps, browsers, Electron. It pastes into the focused field, and refuses to dictate into password fields.
- **Edit by voice:** select text, press **⌃⌥Space**, and say "make this shorter".

> Murmur is built with plain `swiftc`: no Xcode project, no dependencies.
> For how it works inside, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

---

## Requirements

| Requirement | Why |
|---|---|
| **macOS 26 (Tahoe) or later** | Uses `SpeechAnalyzer` and `FoundationModels`, which first shipped in macOS 26 |
| **Apple Silicon Mac** (M-series) | Build target is `arm64` |
| **Xcode 26 or the Xcode Command Line Tools** | Provides `swiftc`, `codesign`, `iconutil` (only to build from source) |
| *Optional:* **Apple Intelligence** turned on | Enables the smart cleanup and voice editing. Without it Murmur falls back to a simpler regex cleanup |

Check your tooling:

```bash
swiftc --version
xcode-select -p
```

If either command fails, install the command line tools with `xcode-select --install`.

---

## Install

### Download (easiest)

Get **Murmur-1.0.0.dmg** from the [Releases page](https://github.com/vinoth12940/Murmur/releases/latest), open it, and drag Murmur to Applications. It is signed with a Developer ID and notarized by Apple, so it opens without a warning.

### Or build from source

Building takes a few seconds.

```bash
git clone https://github.com/vinoth12940/Murmur.git
cd Murmur
./build.sh --install
```

`--install` builds the app, then copies it to `/Applications/Murmur.app`. Open it from Spotlight or Finder; an icon appears in the menu bar (there is no Dock icon).

Prefer not to install? Run `./build.sh` and open `build/Murmur.app` directly.

### First launch

A **Setup & Permissions** window opens the first time and shows what Murmur needs, with live status and a button for each item (reopen it from the menu any time):

1. **Microphone**: Murmur listens only while you dictate.
2. **Input Monitoring**: lets Murmur notice the trigger key. It is listen-only and never records what you type.
3. **Accessibility**: lets Murmur paste the text for you (and notice password fields). Without it, text is left on the clipboard and you paste with ⌘V yourself.
4. **Speech model**: Murmur downloads the on-device model for your language once (macOS may also ask for Speech Recognition access). If you are offline, it keeps retrying by itself.

---

## Using Murmur

| Gesture | What happens |
|---|---|
| **Hold Right ⌥** (> ¼ second) | Push-to-talk. Release to finish |
| **Double-tap Right ⌥** | Hands-free. Tap again to finish, or just pause (~2.5 s) |
| **⌃Space** | Start; press again to stop |
| **Say "Hey Murmur"** | Hands-free (turn on in the menu or Settings) |
| **⌃⌥Space** | Edit selected text by voice (see below) |
| **Esc** (while recording) | Cancel |
| Menu → *Start Dictation* | Same as ⌃Space |

Pressing another key while holding the trigger (like ⌥E) cancels the gesture, so your normal shortcuts keep working.

### Edit by voice

Select some text in any app, press **⌃⌥Space**, say what you want ("make this friendlier", "fix the grammar", "translate to Spanish"), then pause or press ⌃⌥Space again. The selection is replaced with the result. It needs Apple Intelligence; if the edit fails, your text is left unchanged.

### Menu and Settings

The menu bar icon has quick toggles; **Settings…** (⌘,) has everything:

- **Trigger key**: Right ⌥ (default), Fn/Globe, Right ⌘, or Right ⌃. For Fn, set *System Settings → Keyboard → "Press 🌐 key to" → Do Nothing*.
- **Language**: any language supported by on-device speech recognition.
- **Clean up with Apple Intelligence**, **Wake word** (keeps the mic open while idle; audio is never saved), **Spoken commands** (off by default), **Launch at login**.
- **Live text while speaking** *(experimental, off by default)*.
- **Save dictation history** *(off by default)*: lists your recent dictations in the menu; click to copy; *Clear* removes them.
- **Copy Last Dictation**, **Check for Updates…**, **Copy Diagnostics**, **Setup & Permissions…**.

With **Spoken commands** turned on in Settings (off by default), saying **"new line"** or **"new paragraph"** inserts them. Leave it off if you often write those words literally.

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

# Snippets: say the phrase, get the text (\n = new line):
"my email" => "me@example.com"
"sign off" => "Best regards,\nYour Name"

# Words the recognizer should expect (names, products, jargon):
vocabulary: Murmur, Kubernetes, Sriram

# Per-app rules: lines under [App Name] or [bundle.id] apply only in that app.
[Mail]
Use a formal, polite tone.
[Slack]
Keep it short and casual.
[default]
```

Replacements are applied literally after cleanup, so they always take effect. Replacement targets and `vocabulary:` words are also given to the speech recognizer, which helps with unusual names.

---

## Privacy

- Audio is captured only while you are dictating (or while the optional wake word is enabled), and is transcribed by Apple's on-device speech model. It is never uploaded or saved.
- Cleanup and voice editing use Apple's on-device language model. No text is sent to a server.
- The **only** network request Murmur makes is *Check for Updates…*, and only when you click it (it asks GitHub for the latest release). macOS itself downloads the speech model the first time you use a language.
- Your last dictation is kept in memory only. A history file exists only if you turn on *Save dictation history* (private to your user, newest 200 entries).
- While pasting, Murmur temporarily replaces your clipboard with the dictated text, marks it transient so clipboard managers skip it, and restores your previous clipboard afterwards.
- Murmur will not dictate into, or paste into, password fields.
- **Diagnostic log:** `~/Library/Logs/Murmur.log` stays on your Mac, is capped at about 512 KB, and records app events only. What the wake word hears is logged **only** if you turn on "Log what the wake word hears" in Settings.

See [SECURITY.md](SECURITY.md) for reporting a problem.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Holding the key does nothing | Grant **Input Monitoring** (Setup & Permissions…). ⌃Space works without it |
| ⌃Space doesn't work; HUD warns at launch | macOS owns it. Disable *System Settings → Keyboard → Keyboard Shortcuts → Input Sources → "Select the previous input source"* |
| Text is copied but not pasted | Grant **Accessibility** |
| "Murmur won't dictate into password fields" | Intended. Click into a normal text field |
| Permissions were lost after rebuilding | Source builds are ad-hoc signed, so macOS may treat each rebuild as a new app. Re-enable Murmur in *Privacy & Security*; if it still misbehaves, remove the old entry with **−** and add it again. Signed releases do not have this problem |
| Cleanup seems basic | The menu shows why (Apple Intelligence off, still downloading, or unsupported Mac) |
| Language is unsupported | Pick another in Settings; availability depends on macOS |
| Nothing works after sleep | Murmur rebuilds its listeners on wake; if it did not, quit and reopen it and send *Copy Diagnostics* in an issue |
| "Hey Murmur" misfires or never fires | Turn on "Log what the wake word hears" in Settings, try again, and read the `wake:` lines in `~/Library/Logs/Murmur.log` |

For a bug report, use **Copy Diagnostics** from the menu and paste it into the issue. It has no dictated text and no personal paths.

---

## Building, developing, uninstalling

```bash
./build.sh              # build/Murmur.app (wipes build/ first)
./build.sh --install    # also replaces /Applications/Murmur.app
./test.sh               # unit tests
./release.sh            # signed + notarized DMG (needs a Developer ID; see docs/RELEASING.md)
```

- Sources live in `Sources/*.swift`; new files are picked up automatically. New system frameworks must be added to the `-framework` list in `build.sh`.
- Tests are in `Tests/main.swift`; manual checks for audio, hotkeys and pasting are in [docs/TESTING.md](docs/TESTING.md).
- Architecture, diagrams and design decisions: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Contributing: [CONTRIBUTING.md](CONTRIBUTING.md).

**Uninstall:** quit Murmur from its menu, then:

```bash
rm -rf /Applications/Murmur.app
rm -rf ~/Library/Application\ Support/Murmur ~/Library/Logs/Murmur.log*
defaults delete com.vinoth.murmur
```

Finally remove Murmur from *Privacy & Security* (Microphone, Input Monitoring, Accessibility) if listed.

---

## License

[MIT](LICENSE)
