#!/usr/bin/env bash
# Developer ID sign (with Hardened Runtime) + notarize + staple Dashi.app.
#
# Requires a paid Apple Developer Program membership. This is the trusted release path (Option B in
# RELEASING.md); the free ad-hoc path (make-dmg.sh / make-zip.sh) needs none of this. Dashi currently
# ships ad-hoc, so this script is here ready-to-go for when a Developer ID is available.
#
# Reads:
#   DEVELOPER_ID   — signing identity, e.g. "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE — a notarytool keychain profile created once with:
#                      xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#                        --apple-id you@example.com --team-id TEAMID --password app-specific-pw
set -euo pipefail

DERIVED="${DERIVED:-.build/xcode}"
APP="$DERIVED/Build/Products/Release/Dashi.app"

: "${DEVELOPER_ID:?set DEVELOPER_ID to your 'Developer ID Application: Name (TEAMID)' identity}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to your notarytool keychain profile name}"

[ -d "$APP" ] || {
    echo "$APP not found — build a signed app first: DASHI_SIGN=1 bash Scripts/build-app.sh" >&2
    exit 1
}

echo "==> codesign (Developer ID, Hardened Runtime)"
codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> notarize (this can take a few minutes)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ZIP="$WORK/Dashi.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> staple"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=4 "$APP"

echo
echo "Signed + notarized + stapled: $APP"
echo "Now package it: DASHI_ADHOC=0 bash Scripts/make-zip.sh   (and/or make-dmg.sh)"
