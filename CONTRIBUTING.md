# Contributing to Murmur

Thanks for helping. Murmur is a small, dependency-free Swift app, and the aim is to keep it that way: easy to read, easy to build, and private.

## Setup

You need macOS 26, Apple Silicon, and Xcode 26 or the command line tools.

```bash
git clone https://github.com/vinoth12940/Murmur.git
cd Murmur
./test.sh       # unit tests, about 30 seconds
./build.sh      # build/Murmur.app
```

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first; it explains where things live.

## Ground rules

- **Privacy is the product.** No telemetry, no analytics, no network access except the user-initiated update check. Do not log what the user said unless they opt in.
- **No third-party dependencies.** Everything builds with `swiftc`.
- **Put logic in pure, testable types** and add checks to `Tests/main.swift` (see `SilenceDetector`, `Rules`, `Cleaner.chunks` for the pattern). Bug fixes should come with a test that failed before the fix.
- **Threading:** callbacks from audio, CGEvent or Carbon threads must hop to the main actor (`Task { @MainActor in … }` or `DispatchQueue.main.async`). The audio tap must not touch `self`.
- Keep new behaviour off by default unless it is clearly safe for everyone.

## Pull requests

Keep them small and focused. Say which macOS version you tested on and what you tried by hand; anything touching audio, hotkeys, pasting or permissions needs a manual check (see [docs/TESTING.md](docs/TESTING.md)).

## Releases

See [docs/RELEASING.md](docs/RELEASING.md).
