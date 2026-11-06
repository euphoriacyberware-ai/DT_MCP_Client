#!/bin/bash
# Builds a signed, notarized, stapled DMG of DT MCP Client for direct distribution.
#
# One-time setup:
#   1. Install a "Developer ID Application" certificate in your login keychain.
#   2. Store notarization credentials (app-specific password from appleid.apple.com):
#        xcrun notarytool store-credentials dtmcp-notary --apple-id YOU@EXAMPLE.COM --team-id TEAMID
#
# Usage:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" Scripts/release.sh
# Optional: NOTARY_PROFILE (default dtmcp-notary), SKIP_NOTARIZE=1 to stop after signing the DMG.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to your 'Developer ID Application: ...' identity}"
[[ "$SIGN_IDENTITY" == Developer\ ID\ Application* ]] || { echo "SIGN_IDENTITY must be a Developer ID Application identity"; exit 1; }
PROFILE="${NOTARY_PROFILE:-dtmcp-notary}"

APP="$ROOT/.build/DTMCPClient.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
DIST="$ROOT/dist"
DMG="$DIST/DT-MCP-Client-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

SIGN_IDENTITY="$SIGN_IDENTITY" "$ROOT/Scripts/build-app.sh" release

# Hardened runtime + sandbox entitlements must survive signing.
codesign --verify --deep --strict "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "com.apple.security.app-sandbox" \
    || { echo "App is not sandboxed"; exit 1; }

mkdir -p "$DIST"; rm -f "$DMG"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "DT MCP Client" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

if [ -z "${SKIP_NOTARIZE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
fi
echo "Release ready: $DMG"
