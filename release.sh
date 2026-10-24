#!/bin/zsh
# Builds build/Murmur-<version>.dmg, signed and notarized. See docs/RELEASING.md for one-time setup.
#
#   MURMUR_SIGN_IDENTITY   "Developer ID Application: Your Name (TEAMID)"   required (unless --unsigned)
#   MURMUR_NOTARY_PROFILE  a `notarytool store-credentials` profile name     optional: without it the
#                          build is signed but NOT notarized, and says so
#
#   ./release.sh --unsigned   ad-hoc DMG for testing the packaging only; Gatekeeper will warn on other Macs
set -euo pipefail
cd "${0:A:h}"

VERSION=$(<VERSION)
DMG=build/Murmur-$VERSION.dmg
UNSIGNED=0
[[ "${1:-}" == "--unsigned" ]] && UNSIGNED=1

if (( UNSIGNED )); then
  unset MURMUR_SIGN_IDENTITY
else
  if [[ -z "${MURMUR_SIGN_IDENTITY:-}" ]]; then
    echo "Set MURMUR_SIGN_IDENTITY to your \"Developer ID Application: …\" identity (or pass --unsigned)." >&2
    exit 1
  fi
  if [[ "$MURMUR_SIGN_IDENTITY" != "Developer ID Application:"* ]]; then
    echo "MURMUR_SIGN_IDENTITY must be a \"Developer ID Application\" certificate; Apple Development and" >&2
    echo "Apple Distribution certificates cannot be notarized for distribution outside the App Store." >&2
    exit 1
  fi
  if ! security find-identity -v -p codesigning | grep -qF "$MURMUR_SIGN_IDENTITY"; then
    echo "No such signing identity in your keychain: $MURMUR_SIGN_IDENTITY" >&2
    exit 1
  fi
fi

./build.sh
APP=build/Murmur.app

NOTARIZE=0
if (( ! UNSIGNED )) && [[ -n "${MURMUR_NOTARY_PROFILE:-}" ]]; then NOTARIZE=1; fi

if (( NOTARIZE )); then
  ditto -c -k --keepParent $APP build/Murmur-notarize.zip
  xcrun notarytool submit build/Murmur-notarize.zip --keychain-profile "$MURMUR_NOTARY_PROFILE" --wait
  xcrun stapler staple $APP
  rm build/Murmur-notarize.zip
fi

STAGE=$(mktemp -d)
cp -R $APP "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Murmur" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

if (( ! UNSIGNED )); then codesign --force --sign "$MURMUR_SIGN_IDENTITY" --timestamp "$DMG"; fi
if (( NOTARIZE )); then
  xcrun notarytool submit "$DMG" --keychain-profile "$MURMUR_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

(cd build && shasum -a 256 "Murmur-$VERSION.dmg") | tee "$DMG.sha256"
if (( UNSIGNED )); then
  echo "Built $DMG (UNSIGNED: for local testing only)"
elif (( NOTARIZE )); then
  echo "Built $DMG (signed and notarized)"
else
  echo "Built $DMG (signed but NOT notarized: set MURMUR_NOTARY_PROFILE to notarize)"
fi
