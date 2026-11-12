#!/bin/bash
# Builds "E-Rechnung Check.app" into ./build from the Swift package.
#
#   Scripts/build-app.sh            release build, ad-hoc signed (runs on this Mac)
#   CONFIG=debug Scripts/build-app.sh
#   UNIVERSAL=1 Scripts/build-app.sh   Apple Silicon + Intel
#
# A build for other people must be signed with a Developer ID and notarized:
#
#   UNIVERSAL=1 SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#     NOTARY_PROFILE=erechnung-notary Scripts/build-app.sh
#
# NOTARY_PROFILE names credentials saved once with
# `xcrun notarytool store-credentials`. The script then submits the app to
# Apple, staples the ticket and writes build/E-Rechnung-Check-<version>.zip.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
APP="build/E-Rechnung Check.app"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-}" == 1 ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

# The ${…+…} form keeps bash 3.2 (macOS) from rejecting an empty array.
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product ERechnungCheck
BIN="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/ERechnungCheck"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ERechnungCheck"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/en.lproj "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"   # regenerate with Scripts/make-icon.swift

# Notarization requires a secure timestamp; ad-hoc signatures cannot have one.
TIMESTAMP=()
if [[ "$SIGN_IDENTITY" != "-" ]]; then TIMESTAMP=(--timestamp); fi

codesign --force --sign "$SIGN_IDENTITY" --options runtime ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} \
  --entitlements Resources/ERechnungCheck.entitlements "$APP"

echo "Built: $APP"

if [[ -n "$NOTARY_PROFILE" ]]; then
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "NOTARY_PROFILE needs a Developer ID SIGN_IDENTITY" >&2
    exit 1
  fi
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
  ZIP="build/E-Rechnung-Check-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  # Zip again so the download carries the stapled ticket and opens offline.
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  spctl --assess --type execute --verbose "$APP"
  echo "Notarized: $ZIP"
fi
