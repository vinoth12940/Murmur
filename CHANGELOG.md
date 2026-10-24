# Changelog

## Unreleased

### Stability
- A failed microphone start no longer leaves an audio tap behind (which could crash the next dictation).
- Connecting or changing audio devices mid-recording ends the recording cleanly with the text so far; the wake-word listener restarts with the new device.
- Sleep and wake: the trigger key and wake word are rebuilt after the Mac wakes.
- If the speech model cannot be prepared (for example, first launch offline), Murmur retries by itself.
- Long dictations are cleaned in chunks; one slow chunk no longer downgrades the whole text.
- Murmur refuses to dictate into, or paste into, password fields.
- The diagnostic log is capped (~512 KB, one rotated copy), and no longer records what the wake word hears unless verbose logging is on.
- Only one copy of Murmur runs at a time.
- Fixed: replacement rules did not match across extra spaces ("open  ai").

### Release engineering
- Version file, hardened-runtime signing with entitlements, `release.sh` for signed and notarized DMGs, Homebrew cask template.
- Unit tests (`./test.sh`), GitHub Actions CI and release workflows, security, contributing and release documents.
- **Check for Updates…** (only when clicked) and **Copy Diagnostics** menu items.

### Features
- First-run Setup & Permissions window and a Settings window.
- Rules file: `vocabulary:` hints for the recognizer, `"phrase" => "text"` snippets, and `[App]` sections for per-app rules.
- Spoken "new line" / "new paragraph".
- Optional local dictation history (off by default).
- Experimental, off by default: live text while speaking.
- Experimental: edit selected text by voice with ⌃⌥Space ("make this shorter").

These runtime changes were verified by unit tests and a successful build only. They have not yet been exercised with live audio; run the checklist in `docs/TESTING.md` before a release.

## 1.0.0
- Initial release.
