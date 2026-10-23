# Murmur — Architecture

> **Audience:** developers working on Murmur (new contributors and future-you).
> **Scope:** how the app is put together, how a dictation flows end to end, and why it is built this way.
> **Source of truth:** the code in `Sources/`. File and symbol names below are real; if you rename one, update this doc.
> Diagrams are [Mermaid](https://mermaid.js.org) — they render on GitHub, in VS Code (Markdown Preview Mermaid Support) and in most Markdown viewers.

---

## 1. What Murmur is

Murmur is a macOS **menu-bar dictation app**. You trigger it, speak, and the cleaned-up text is pasted into whatever app has focus.

| Property | Value |
|---|---|
| Language / UI | Swift 5 mode, AppKit, no storyboard, no Xcode project, no SwiftPM |
| Platform | macOS 26+, Apple Silicon (`-target arm64-apple-macosx26.0`) |
| Speech-to-text | `SpeechAnalyzer` / `SpeechTranscriber`, **on-device** |
| Text cleanup | Apple Intelligence (`FoundationModels`), **on-device**, with a regex fallback |
| Privacy | Audio never leaves the Mac; there is no network code |
| Presence | `LSUIElement` — menu-bar icon only, no Dock icon |

**Three ways to start dictating**

1. **Hold** the trigger key (default Right ⌥) — push-to-talk, release to finish.
2. **Double-tap** the trigger key, or press **⌃Space**, or say **"Hey Murmur"** — *hands-free* ("latched") mode; ends on a tap, ⌃Space, or ~2.5 s of silence.
3. **Menu** → *Start Dictation*.

---

## 2. System context

```mermaid
flowchart LR
    User(["User"])
    subgraph Mac["Your Mac - everything stays local"]
        Murmur["Murmur.app<br/>menu-bar agent"]
        Mic["Microphone"]
        Speech["Apple SpeechAnalyzer<br/>on-device model"]
        AI["Apple Intelligence<br/>FoundationModels"]
        Target["Focused app<br/>any text field"]
        Rules[("rules.md<br/>~/Library/Application Support/Murmur")]
        Log[("Murmur.log<br/>~/Library/Logs")]
    end
    User -- "key / hotkey / voice" --> Murmur
    Mic -- "audio buffers" --> Murmur
    Murmur <--> Speech
    Murmur <--> AI
    Murmur -- "reads" --> Rules
    Murmur -- "writes" --> Log
    Murmur -- "pasteboard + synthetic Cmd-V" --> Target
```

---

## 3. Component map

`AppDelegate` is the only coordinator. Every other type is a focused helper that knows nothing about the others; they communicate through closures that `AppDelegate` wires up in `applicationDidFinishLaunching`.

```mermaid
flowchart TB
    main["main.swift<br/>boots NSApplication, accessory policy"] --> AD

    subgraph Input["Trigger input"]
        KM["KeyMonitor<br/>CGEventTap, listen-only<br/>modifier-only trigger"]
        HK["HotKey<br/>Carbon RegisterEventHotKey<br/>Ctrl+Space, Escape"]
        WW["WakeWordListener + WakePhrase<br/>always-on recognizer<br/>fuzzy match Hey Murmur"]
    end

    subgraph Core["Coordinator"]
        AD["AppDelegate<br/>MainActor, state machine<br/>gestures, menu, settings"]
    end

    subgraph Pipeline["Dictation pipeline"]
        DI["Dictation<br/>AVAudioEngine to AVAudioConverter<br/>to SpeechAnalyzer"]
        CL["Cleaner<br/>LanguageModelSession<br/>or basicCleanup"]
        RU["Rules<br/>parses rules.md"]
        PA["Paster<br/>pasteboard + Cmd-V"]
    end

    subgraph UI["Feedback"]
        HUD["HUD<br/>floating non-activating panel"]
        GL["Glyph<br/>menu-bar icon"]
    end

    LOG["Log<br/>Murmur.log"]

    KM -- "onDown / onUp / onOtherKey" --> AD
    HK -- "handler" --> AD
    WW -- "onWake" --> AD
    AD -- "start / stop / cancel" --> DI
    DI -- "onLevel" --> AD
    AD -- "raw text" --> CL
    CL -- "uses" --> RU
    AD -- "final text" --> PA
    AD --> HUD
    AD --> GL
    WW -. "log" .-> LOG
    AD -. "log" .-> LOG
```

### Responsibilities at a glance

| File | Type | Owns | Notes |
|---|---|---|---|
| `main.swift` | — | App bootstrap | Sets `.accessory` activation policy, installs `AppDelegate`. |
| `AppDelegate.swift` | `AppDelegate` | State machine, gesture logic, settings, status-bar menu | `@MainActor`. Menu is rebuilt from scratch on every open (`menuNeedsUpdate`). |
| `KeyMonitor.swift` | `KeyMonitor`, `TriggerKey` | Modifier-only trigger detection | Listen-only `CGEventTap`; needs **Input Monitoring**. Re-enables itself if macOS disables the tap. |
| `HotKey.swift` | `HotKey` | Global key combos | Carbon `RegisterEventHotKey`; no permission, swallows the combo. `init?` returns `nil` if the combo is taken. |
| `Dictation.swift` | `Dictation` | Mic capture + transcription | Per-utterance `start()/stop()/cancel()`; one-time `prepare()`. |
| `WakeWord.swift` | `WakeWordListener`, `WakePhrase` | Hands-free activation | Separate recognizer session recycled every 120 s. |
| `Cleaner.swift` | `Cleaner`, `withTimeout` | Transcript polishing | 20 s timeout, length sanity check, regex fallback. |
| `Rules.swift` | `Rules` | User rules file | Parses instructions + literal replacements. |
| `Paster.swift` | `Paster` | Text insertion | Pasteboard swap, synthetic ⌘V, clipboard restore. |
| `HUD.swift` | `HUD`, `BarsView` | On-screen status pill | Never takes focus. |
| `Glyph.swift` | `Glyph` | Menu-bar icon drawing | Switches image while recording. |
| `Log.swift` | `Log` | Diagnostics | Appends to `~/Library/Logs/Murmur.log`. |

---

## 4. The state machine

`AppDelegate.state` has four values. Its `didSet` calls `refreshIcon()` (icon changes while recording) and `syncWakeListener()` (the wake listener only runs in `.idle`).

```mermaid
stateDiagram-v2
    [*] --> preparing: launch
    preparing --> idle: speech model ready
    preparing --> idle: prepare failed - HUD shows error
    idle --> recording: hold / double-tap / Ctrl+Space / wake word / menu
    recording --> processing: stop - release, tap, silence, Ctrl+Space
    recording --> idle: Escape cancel, 12 s no speech, start failure
    processing --> idle: pasted, copied, empty transcript, or error
    idle --> preparing: language changed
```

What each state allows:

| State | Trigger gestures | ⌃Space (`toggle()`) | Wake listener |
|---|---|---|---|
| `preparing` | ignored (`guard state == .idle`) | HUD shows current status | off |
| `idle` | start | start (latched) | **on** if enabled |
| `recording` | tap stops if latched | stop | off (mic belongs to `Dictation`) |
| `processing` | ignored | system beep | off |

---

## 5. Startup sequence

```mermaid
sequenceDiagram
    autonumber
    participant OS as macOS
    participant AD as AppDelegate
    participant KM as KeyMonitor
    participant HK as HotKey
    participant DI as Dictation

    OS->>AD: applicationDidFinishLaunching
    AD->>AD: Rules.ensureFileExists, build status item
    AD->>KM: set trigger, wire onDown/onUp/onOtherKey
    AD->>KM: start()
    alt Input Monitoring not granted
        KM-->>AD: false
        AD->>OS: request permission - once only
        loop every 2 s
            AD->>KM: start()
        end
        Note over AD,KM: Succeeds as soon as the user grants it, no relaunch needed
    end
    AD->>HK: register Ctrl+Space
    alt combo already taken
        HK-->>AD: nil
        AD->>AD: HUD warns about the macOS input-source shortcut
    end
    AD->>DI: requestMicrophone
    AD->>DI: prepare(locale)
    DI->>OS: resolve locale, download speech asset if needed
    DI-->>AD: analyzerFormat cached
    AD->>AD: state = idle, HUD hides
```

Accessibility is **not** requested at launch. It is requested from the menu, or the first time a paste cannot be performed (once, tracked by `askedAccessibility`).

---

## 6. Trigger gestures

Two independent input paths feed the same `startRecording()` / `stopRecording()` logic.

### 6.1 Raw key events → gestures

`KeyMonitor` turns `flagsChanged`/`keyDown` events into three callbacks. `AppDelegate` interprets them:

| Constant | Value | Meaning |
|---|---|---|
| `holdDelay` | 250 ms | Held longer than this = push-to-talk |
| `doubleTapWindow` | 0.45 s | Second tap within this = latched hands-free |

```mermaid
flowchart TD
    D(["triggerDown"]) --> A{"state == recording<br/>and latched?"}
    A -- yes --> A1["latched = false<br/>ignoreNextUp = true<br/>stopRecording"]
    A -- no --> B{"state == idle?"}
    B -- no --> X1(["ignore"])
    B -- yes --> C{"previous tap-up<br/>less than 0.45 s ago?"}
    C -- yes --> C1["latched = true<br/>ignoreNextUp = true<br/>startRecording"]
    C -- no --> E["start 250 ms hold timer"]
    E --> F{"timer fires and<br/>trigger still held<br/>and still idle?"}
    F -- yes --> F1["startedByHold = true<br/>startRecording"]
    F -- no --> X2(["cancelled by up<br/>or other key"])

    U(["triggerUp"]) --> U1{"ignoreNextUp?"}
    U1 -- yes --> U2["clear flag, return"]
    U1 -- no --> U3{"startedByHold?"}
    U3 -- yes --> U4["stopRecording"]
    U3 -- no --> U5["lastTapUp = now<br/>arms double-tap"]

    O(["otherKeyPressed"]) --> O1{"trigger held and<br/>not startedByHold?"}
    O1 -- yes --> O2["cancel hold timer<br/>lastTapUp = nil<br/>so Opt-E etc. still work"]
    O1 -- no --> O3(["ignore"])
```

`ignoreNextUp` exists because the key-up that follows the *second* tap (or the tap that ends a latched session) must not be mistaken for a fresh single tap.

### 6.2 Ending a hands-free session

While `latched`, every audio level callback runs `handleLevel`:

```mermaid
flowchart TD
    L(["handleLevel(level)"]) --> H["hud.updateLevel"]
    H --> R{"state == recording?"}
    R -- no --> Z(["return"])
    R -- yes --> V{"level > 0.12?"}
    V -- yes --> V1["heardSpeech = true<br/>lastVoice = now"]
    V -- no --> M
    V1 --> M{"latched?"}
    M -- no --> Z
    M -- yes --> S{"heardSpeech and<br/>silent for more than 2.5 s?"}
    S -- yes --> STOP["stopRecording"]
    S -- no --> T{"never heard speech and<br/>more than 12 s elapsed?"}
    T -- yes --> CANCEL["cancelRecording"]
    T -- no --> Z
```

`level` is the RMS of each buffer × 9, clamped to 1 (`Dictation.level(of:)`).

Other ways to end a session: tap the trigger, press ⌃Space, or press **Escape** (cancel — the Escape `HotKey` is registered only while recording so it never steals Escape from other apps).

---

## 7. The dictation pipeline

This is the path every utterance takes, regardless of how it was started.

```mermaid
sequenceDiagram
    autonumber
    participant AD as AppDelegate
    participant DI as Dictation
    participant SA as SpeechAnalyzer
    participant CL as Cleaner
    participant PA as Paster
    participant APP as Focused app

    AD->>AD: startRecording - state = recording, show HUD, register Escape
    AD->>DI: start() in startTask
    DI->>SA: new SpeechTranscriber + SpeechAnalyzer, begin consuming results
    DI->>DI: AVAudioEngine tap, convert to analyzer format
    loop every ~4096-frame buffer
        DI-->>AD: onLevel(rms) - hops to main
        DI->>SA: AnalyzerInput(buffer)
    end
    Note over AD: user releases / taps / pauses
    AD->>AD: stopRecording - state = processing, HUD Transcribing
    AD->>DI: stop()
    DI->>SA: finish input, finalizeAndFinishThroughEndOfInput
    SA-->>DI: results joined with spaces
    DI-->>AD: raw transcript
    alt transcript empty
        AD->>AD: HUD Didnt catch that, state = idle
    else
        AD->>CL: clean(raw, rules, useModel)
        CL-->>AD: cleaned text
        AD->>PA: paste(text)
        PA->>APP: pasteboard + synthetic Cmd-V
        PA-->>AD: true if pasted, false if clipboard only
        AD->>AD: state = idle, HUD hide or hint
    end
```

Design notes:

- **`startTask` is awaited by both `stopRecording` and `cancelRecording`.** `start()` is async (it requests mic access and starts the analyzer), so a quick release can arrive before it finishes. Awaiting the task guarantees we never `stop()` a session that is still starting.
- **A new `SpeechTranscriber`/`SpeechAnalyzer` is created per utterance**; only the locale and audio format are cached by `prepare()`.
- **Audio format conversion:** the mic's native format is converted per buffer with `AVAudioConverter` into `analyzerFormat` (`SpeechAnalyzer.bestAvailableAudioFormat`).
- **Threading:** the audio tap runs on a realtime audio thread and calls `onLevel` there; `AppDelegate` hops to main with `DispatchQueue.main.async`.

---

## 8. Wake word ("Hey Murmur")

`Dictation` and `WakeWordListener` each own an `AVAudioEngine` but share **one microphone**, so they must never run together. `AppDelegate.syncWakeListener()` enforces that — it runs on every `state` change and whenever the setting toggles.

```mermaid
flowchart TD
    S(["syncWakeListener()"]) --> Q{"wakeWordEnabled and<br/>state == idle and<br/>locale + format ready?"}
    Q -- no --> STOP["wake.stop()<br/>cancel loop, release mic"]
    Q -- yes --> BEGIN["wake.begin(locale, format)"]

    BEGIN --> LOOP{"loop already running?"}
    LOOP -- yes --> NOOP(["no-op"])
    LOOP -- no --> SESS["runSession: new transcriber<br/>volatile results + contextual strings<br/>Murmur, Hey Murmur"]
    SESS --> RACE{"first to finish"}
    RACE -- "result text matches<br/>WakePhrase.matches" --> WOKE["release mic<br/>onWake"]
    RACE -- "120 s timer" --> RECYCLE["release mic,<br/>start a fresh session"]
    RECYCLE --> SESS
    WOKE --> WH["AppDelegate.wakeHeard<br/>Tink sound, latched = true<br/>startRecording"]
    SESS -- "dies in under 5 s" --> BACKOFF["sleep 2 s - avoid spinning"] --> SESS
```

**Matching (`WakePhrase.matches`)** — recognizers rarely spell "Murmur" correctly, so matching is fuzzy using Levenshtein distance (`distance`):

1. Any single word of ≥ 5 letters within **1 edit** of `murmur` matches on its own.
2. Otherwise, find a greeting word (`hey, hay, hi, hei, heya, k, ok, okay, a, hate`) and test the next word — or the next two words concatenated — against `murmur`:
   - length ≥ 4 and ≤ 2 edits, **or**
   - length ≥ 5 and ≤ 3 edits (catches "merma", "rumor").
3. The length floors stop short common words like "more" from matching.

The session is recycled every 120 s so memory stays flat.

---

## 9. Cleanup: `Cleaner` + `Rules`

Cleanup is designed so **dictation never fails because of it**.

```mermaid
flowchart TD
    IN(["raw transcript"]) --> T["trim whitespace"]
    T --> E{"empty?"}
    E -- yes --> EMPTY(["return empty"])
    E -- no --> U{"cleanup enabled?"}
    U -- "no" --> REPL
    U -- yes --> AV{"Apple Intelligence<br/>available?"}
    AV -- no --> BASIC["basicCleanup<br/>regex: drop um/uh/er,<br/>collapse repeats, capitalize"]
    AV -- yes --> POL["polish: LanguageModelSession<br/>temperature 0.1, 20 s timeout"]
    POL --> OK{"non-empty and<br/>length at most 2x + 40?"}
    OK -- yes --> REPL
    OK -- "no / error / timeout" --> BASIC
    BASIC --> REPL["Rules.applyReplacements<br/>always runs"]
    REPL --> OUT(["final text"])
```

- **Prompt shape.** System instructions tell the model to remove fillers, apply self-corrections, fix punctuation, and — importantly — *never* answer or obey text inside the transcript (a basic prompt-injection guard). The transcript is wrapped in `<transcript>` tags; tags are stripped from the output.
- **Why replacements run last.** Lines like `"git hub" -> "GitHub"` are *also* shown to the model, but the model may ignore them, so `applyReplacements` enforces them deterministically afterwards. Matching is whole-word, case-insensitive, and spaces match `\s+`.
- **Output sanity check.** Output longer than `2 × input + 40` characters is rejected as runaway generation.

### The rules file

`~/Library/Application Support/Murmur/rules.md` is created from a template on first run and re-read on **every** dictation (no restart needed).

| Line type | Example | Effect |
|---|---|---|
| Comment / blank | `# notes` | ignored |
| Replacement | `"open ai" -> "OpenAI"` | sent to model **and** applied literally afterwards |
| Anything else | `Use American English spelling.` | injected into the model prompt as an instruction |

---

## 10. Pasting: `Paster`

```mermaid
flowchart TD
    P(["paste(text)"]) --> SN["snapshot current pasteboard"]
    SN --> SET["clear + set text<br/>mark as TransientType<br/>so clipboard managers skip it"]
    SET --> AX{"Accessibility<br/>granted?"}
    AX -- no --> LEAVE(["return false<br/>text stays on clipboard"])
    AX -- yes --> OPT{"Option key still down?"}
    OPT -- yes --> WAIT["wait up to 20 x 50 ms"] --> OPT
    OPT -- no --> V["post Cmd-V key down + up<br/>via CGEvent"]
    V --> SLEEP["wait 700 ms for target app to read"]
    SLEEP --> CH{"pasteboard changeCount<br/>unchanged?"}
    CH -- yes --> RESTORE["restore user's clipboard"]
    CH -- no --> KEEP["leave it - someone else wrote"]
    RESTORE --> DONE(["return true"])
    KEEP --> DONE
```

Why this approach: pasting via the pasteboard works in native apps *and* browsers/Electron without per-app integration. Waiting for Option to be released matters because Right ⌥ is the default trigger — otherwise ⌘V would arrive as ⌥⌘V.

If Accessibility is missing, `AppDelegate` shows *"Copied to clipboard. Press ⌘V…"* and asks for the permission once.

---

## 11. HUD and menu bar

- **HUD** — a borderless `NSPanel` (`.nonactivatingPanel`, level `.statusBar`, ignores mouse, joins all Spaces and full-screen apps) with a blurred background. It is centered near the bottom of the screen under the mouse. Four calls: `showListening` (animated level bars + hint), `showBusy` (label only, stays until replaced), `flash` (label, auto-hides), `hide` (fade out). Because it is non-activating, the field you are dictating into keeps focus.
- **Menu bar icon** — `Glyph.menuBarImage(recording:)`; updated from `state.didSet`.
- **Menu** — rebuilt in `menuNeedsUpdate` each time it opens, so it always reflects live state (permissions, model availability, selected trigger/language). *Start Dictation* waits 150 ms so the previously focused app is frontmost again before recording begins.

---

## 12. Threading model

| Context | What runs there | How it reaches `AppDelegate` |
|---|---|---|
| Main actor | `AppDelegate`, `HUD`, all state | — |
| CGEventTap callback (main run loop) | `KeyMonitor.handle` | `Task { @MainActor in … }` |
| Carbon hotkey event | `HotKey` dispatcher | `DispatchQueue.main.async` |
| Realtime audio thread | `Dictation` tap, level calculation | `onLevel` → `DispatchQueue.main.async` |
| Swift concurrency tasks | speech results, `Cleaner`, `Paster`, wake loop | `await` back onto the main actor |

**Convention:** any new callback coming from an audio / CGEvent / Carbon thread must hop to main with one of the two patterns above.

---

## 13. Permissions

| Permission | Needed for | Requested | If missing |
|---|---|---|---|
| Microphone | Recording | At launch (`Dictation.requestMicrophone`) and in `start()` | `DictationError.microphoneDenied` HUD message |
| Speech Recognition | On-device transcription | System prompt (usage string in `Info.plist`) | `prepare()` fails; HUD shows error |
| Input Monitoring | Trigger-key `CGEventTap` | Once at launch, then menu item; retried every 2 s | Trigger key inactive; ⌃Space and menu still work |
| Accessibility | Synthetic ⌘V | Menu item, or once on first failed paste | Text left on clipboard; HUD tells user to press ⌘V |

⌃Space (`HotKey`) needs **no** permission.

> Ad-hoc code signing means macOS can reset TCC permissions after a rebuild. `build.sh` pins the identifier to `com.vinoth.murmur` to reduce this.

---

## 14. Persistent state

**`UserDefaults` keys** (all on `AppDelegate`):

| Key | Type | Default | Purpose |
|---|---|---|---|
| `cleanup` | Bool | `true` | Use Apple Intelligence cleanup |
| `locale` | String | `Locale.current.identifier` | Dictation language |
| `wakeWord` | Bool | `false` | Always-on "Hey Murmur" |
| `trigger` | String (`TriggerKey` raw) | `rightOption` | Push-to-talk key |
| `askedAccessibility` | Bool | `false` | Prompt only once |
| `askedInputMonitoring` | Bool | `false` | Prompt only once |

**Files**

| Path | Purpose |
|---|---|
| `~/Library/Application Support/Murmur/rules.md` | User cleanup rules |
| `~/Library/Logs/Murmur.log` | Diagnostics via `Log.write` |

Nothing else is persisted — transcripts are kept in memory only (`lastText`, for *Copy Last Dictation*).

---

## 15. Build and packaging

```mermaid
flowchart LR
    SRC["Sources/*.swift"] --> SWIFTC["swiftc -O<br/>swift 5 mode, arm64, macOS 26<br/>frameworks listed in build.sh"]
    SWIFTC --> BIN["Murmur.app/Contents/MacOS/Murmur"]
    PL["Info.plist"] --> APP
    ICON["Tools/make_icon.swift"] --> ICONSET["AppIcon.iconset"] --> ICNS["iconutil to AppIcon.icns"] --> APP
    BIN --> APP["build/Murmur.app"]
    APP --> SIGN["codesign ad-hoc<br/>identifier com.vinoth.murmur"]
    SIGN --> INSTALL{"--install?"}
    INSTALL -- yes --> INST["pkill Murmur<br/>copy to /Applications"]
    INSTALL -- no --> END(["done"])
```

```bash
./build.sh              # build/Murmur.app (wipes build/ first)
./build.sh --install    # also replaces /Applications/Murmur.app
```

- New `.swift` files in `Sources/` are picked up by the glob automatically.
- New system frameworks must be added to the `-framework` list in `build.sh`.
- There is no test suite or linter. Verification is manual: run the app and watch `~/Library/Logs/Murmur.log`.

---

## 16. Key design decisions

| Decision | Why | Trade-off |
|---|---|---|
| Modifier-only trigger key via `CGEventTap` | Never collides with other apps' shortcuts | Requires Input Monitoring; listen-only so it can't block input |
| Also offer ⌃Space via Carbon hotkey | Works with zero permissions; fallback while Input Monitoring is pending | macOS may already own the combo (input-source switching) |
| Paste via pasteboard + ⌘V | Works everywhere (native, browser, Electron) | Needs Accessibility; briefly touches the clipboard (mitigated by transient flag + restore) |
| Regex fallback + literal replacements after the model | Dictation must never fail due to cleanup; user rules must be guaranteed | Fallback is less capable than the model |
| Wake listener only runs while idle | The mic is a single shared resource | Brief gap between a recording ending and the listener resuming |
| New analyzer per utterance, cached locale/format | Simple lifecycle, no stale session state | Small setup cost per dictation |
| Single `@MainActor` coordinator | One place owns all state; avoids locking | `AppDelegate` is large (~440 lines) — gesture logic, menu and flow all live there |
| No network code, on-device models only | Privacy promise | Requires macOS 26 + Apple Silicon; language list limited to what the OS supports |

---

## 17. Troubleshooting map

| Symptom | Look at | Likely cause |
|---|---|---|
| Hold-to-talk does nothing | Menu shows "Allow Input Monitoring…" | Input Monitoring not granted (`KeyMonitor.isRunning == false`) |
| ⌃Space does nothing / HUD warning at launch | `Murmur.log`: "⌃Space hotkey NOT registered" | macOS "Select the previous input source" shortcut owns it |
| Text lands on clipboard but is not pasted | HUD hint; menu "Grant Accessibility…" | Accessibility missing (also reset by ad-hoc re-signing) |
| "Hey Murmur" never triggers | `Murmur.log` lines starting `wake:` show what was heard | Mishearing outside the fuzzy thresholds; wake toggle off; state not idle |
| Cleanup seems basic | Menu warning under *Clean Up…* | Apple Intelligence off / not ready / unsupported Mac, or the 20 s timeout hit |
| Fn trigger conflicts | Trigger submenu note | Set *Press 🌐 key to → Do Nothing* in Keyboard settings |
| Language greyed or unsupported | HUD error after picking a language | Locale not supported by on-device `SpeechTranscriber` |

---

## 18. Extending Murmur

- **Add a trigger key:** add a case to `TriggerKey` (`title`, `shortName`, `keyCode`, `flagMask`). The menu picks it up through `allCases`.
- **Add a setting:** add a computed property backed by `UserDefaults` on `AppDelegate`, then a menu item + `@objc` handler in `menuNeedsUpdate`.
- **Add a global shortcut:** create a `HotKey(keyCode:modifiers:)` and hop to main in its handler; handle the `nil` (taken) case.
- **Change cleanup behaviour:** edit the prompt in `Cleaner.polish`, or add a regex step to `Cleaner.basicCleanup`. User-specific tweaks belong in `rules.md`, not code.
- **Add a new source file / framework:** drop the file in `Sources/`; add any framework to `build.sh`.

---

## 19. Glossary

| Term | Meaning |
|---|---|
| **Latched** | Hands-free recording (double-tap, ⌃Space, wake word); ends on tap, ⌃Space or silence |
| **Push-to-talk** | Recording only while the trigger is held (> 250 ms) |
| **Trigger key** | A modifier-only key (Right ⌥ default) watched by `KeyMonitor` |
| **Analyzer format** | Audio format `SpeechAnalyzer` wants; mic audio is converted into it |
| **Transient pasteboard type** | `org.nspasteboard.TransientType` — tells clipboard managers to ignore the entry |
| **TCC** | macOS privacy-permission database (Microphone, Input Monitoring, Accessibility…) |
