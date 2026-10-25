#!/bin/zsh
# Compiles every source file except main.swift together with Tests/main.swift and runs the checks.
# No test framework or package manifest needed. Exits non-zero if any check fails.
set -euo pipefail
cd "${0:A:h}"

OUT=${TMPDIR:-/tmp}/murmur-tests
mkdir -p "$OUT"
SOURCES=(${(f)"$(ls Sources/*.swift | grep -v '/main.swift$')"})

swiftc -swift-version 5 -target arm64-apple-macosx26.0 -module-cache-path "$OUT/modules" \
  -framework AppKit -framework AVFoundation -framework Speech -framework FoundationModels \
  -framework Carbon -framework ServiceManagement -framework ApplicationServices \
  $SOURCES Tests/main.swift -o "$OUT/run"

"$OUT/run"
