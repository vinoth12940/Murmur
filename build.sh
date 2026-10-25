#!/bin/zsh
# Builds build/Murmur.app. With --install, also copies it to /Applications and relaunches it.
#
# Signing is ad-hoc by default. For a distributable build set MURMUR_SIGN_IDENTITY to a
# "Developer ID Application: Your Name (TEAMID)" identity; the app is then signed with the
# hardened runtime, which notarization requires (see release.sh and docs/RELEASING.md).
set -euo pipefail
cd "${0:A:h}"

APP=build/Murmur.app
VERSION=$(<VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
IDENTITY=${MURMUR_SIGN_IDENTITY:--}
MODULES=${TMPDIR:-/tmp}/murmur-modules

rm -rf build && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources

swiftc -O -swift-version 5 -target arm64-apple-macosx26.0 -module-cache-path "$MODULES" \
  -framework AppKit -framework AVFoundation -framework Speech -framework FoundationModels \
  -framework Carbon -framework ServiceManagement -framework ApplicationServices \
  Sources/*.swift -o $APP/Contents/MacOS/Murmur

cp Info.plist $APP/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" $APP/Contents/Info.plist

swift -module-cache-path "$MODULES" Tools/make_icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o $APP/Contents/Resources/AppIcon.icns

if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - --identifier com.vinoth.murmur $APP
else
  codesign --force --sign "$IDENTITY" --options runtime --timestamp \
    --entitlements Murmur.entitlements --identifier com.vinoth.murmur $APP
fi
codesign --verify --strict $APP
echo "Built $APP (version $VERSION, build $BUILD, signed as ${IDENTITY/#-/ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Murmur 2>/dev/null || true
  rm -rf /Applications/Murmur.app
  cp -R $APP /Applications/Murmur.app
  echo "Installed /Applications/Murmur.app"
fi
