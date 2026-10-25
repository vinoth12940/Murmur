# Security and privacy

Murmur is built so that your voice and your words stay on your Mac: speech recognition and cleanup run on-device, there are no accounts, no telemetry, and no automatic crash reporting. The only network request Murmur ever makes is the **Check for Updates…** menu item, which asks GitHub for the latest release when you click it.

## Reporting a vulnerability

Please do **not** open a public issue for a security problem. Use GitHub's private reporting: the repository's **Security** tab → **Report a vulnerability**. Include what you found, how to reproduce it and the macOS version. You will get a reply as soon as the maintainer can; this is a small project, so please allow a few days.

## What counts

- Anything that makes Murmur send audio or text off the Mac.
- Pasting dictated text where the user did not intend, such as into a password field.
- Reading or writing files outside Murmur's own folders (`~/Library/Application Support/Murmur`, `~/Library/Logs/Murmur.log`).
- Problems in the release or signing process.

## What Murmur stores

| What | Where | Notes |
|---|---|---|
| Settings | `UserDefaults` (`com.vinoth.murmur`) | Toggles, language, trigger key |
| Rules | `~/Library/Application Support/Murmur/rules.md` | Edited by the user |
| Dictation history | `~/Library/Application Support/Murmur/history.jsonl` | **Off by default.** Mode 0600, newest 200 entries |
| Diagnostic log | `~/Library/Logs/Murmur.log` (+ `.1`) | App events only; capped at ~512 KB. Speech heard by the wake word is logged only if you enable verbose logging |

## Permissions Murmur asks for, and why

Microphone (to record while you dictate), Input Monitoring (to notice the trigger key; the event tap is listen-only and does not record keystrokes), Accessibility (to paste with ⌘V and to detect password fields).
