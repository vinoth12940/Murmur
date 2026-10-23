#!/bin/zsh
# Builds build/Murmur.app. With --install, also copies it to /Applications and relaunches it.
set -euo pipefail
cd "${0:A:h}"

APP=build/Murmur.app
rm -rf build && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources

swiftc -O -swift-version 5 -target arm64-apple-macosx26.0 \
  -framework AppKit -framework AVFoundation -framework Speech -framework FoundationModels \
  -framework Carbon -framework ServiceManagement -framework ApplicationServices \
  Sources/*.swift -o $APP/Contents/MacOS/Murmur

cp Info.plist $APP/Contents/Info.plist

swift Tools/make_icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o $APP/Contents/Resources/AppIcon.icns

codesign --force --sign - --identifier com.vinoth.murmur $APP
codesign --verify --strict $APP
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Murmur 2>/dev/null || true
  rm -rf /Applications/Murmur.app
  cp -R $APP /Applications/Murmur.app
  echo "Installed /Applications/Murmur.app"
fi
