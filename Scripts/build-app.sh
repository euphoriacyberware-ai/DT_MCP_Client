#!/bin/bash
# Builds DTMCPClient.app from the SwiftPM executable, then signs it with the App Sandbox
# entitlements. Usage: Scripts/build-app.sh [debug|release]
# Set SIGN_IDENTITY to a "Developer ID Application: ..." identity for distribution
# (then notarize with `xcrun notarytool` and staple). Defaults to ad-hoc signing ("-"),
# or pass an "Apple Development: ..." identity for local runs.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${SIGN_IDENTITY:--}"
APP="$ROOT/.build/DTMCPClient.app"

cd "$ROOT"
swift build -c "$CONFIG" --product DTMCPClient
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DTMCPClient" "$APP/Contents/MacOS/DTMCPClient"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/Icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM resource bundles (library model specs, etc.)
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done

# Distribution identities need a secure timestamp for notarization.
TS="--timestamp=none"; [[ "$IDENTITY" == Developer\ ID* ]] && TS="--timestamp"
codesign --force --options runtime $TS \
    --entitlements "$ROOT/Resources/DTMCPClient.entitlements" \
    --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Built $APP"
