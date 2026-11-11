#!/bin/bash
# Builds "E-Rechnung Check.app" into ./build from the Swift package.
#
#   Scripts/build-app.sh            release build, ad-hoc signed (runs on this Mac)
#   CONFIG=debug Scripts/build-app.sh
#
# Ad-hoc signing is enough for local use. A build for other people must be
# signed with a Developer ID and notarized; set SIGN_IDENTITY for that.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP="build/E-Rechnung Check.app"

swift build -c "$CONFIG" --product ERechnungCheck
BIN="$(swift build -c "$CONFIG" --show-bin-path)/ERechnungCheck"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ERechnungCheck"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/en.lproj "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"   # regenerate with Scripts/make-icon.swift

codesign --force --sign "$SIGN_IDENTITY" --options runtime \
  --entitlements Resources/ERechnungCheck.entitlements "$APP"

echo "Built: $APP"
