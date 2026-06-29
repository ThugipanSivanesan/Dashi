#!/usr/bin/env bash
# Package Dashi.app into an unsigned (ad-hoc signed) .dmg for a GitHub community release.
#
# Needs NO Apple Developer account. The result is NOT notarized, so users must approve it once in
# System Settings → Privacy & Security → "Open Anyway". By default the app is ad-hoc signed
# (codesign --sign -, free) so it has a stable code identity and prompts less for Keychain access;
# set DASHI_ADHOC=0 to produce a truly unsigned bundle. For the trusted (Developer ID + notarized)
# path, see RELEASING.md.
#
# The .dmg is laid out with `create-dmg` (brew install create-dmg) so the mounted volume shows the
# familiar drag-the-app-onto-Applications window instead of a bare Finder folder.
set -euo pipefail

DERIVED="${DERIVED:-.build/xcode}"
APP="$DERIVED/Build/Products/Release/Dashi.app"
OUT_DIR="${OUT_DIR:-dist}"

command -v create-dmg >/dev/null || {
    echo "create-dmg not found — install with: brew install create-dmg" >&2
    exit 1
}

# Build the app bundle if it isn't there yet (build-app.sh is unsigned by default).
if [ ! -d "$APP" ]; then
    echo "==> $APP not found — building it"
    bash Scripts/build-app.sh
fi

# Artifact version comes from project.yml's MARKETING_VERSION.
VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' project.yml)"
VERSION="${VERSION:-0.0.0}"
DMG="$OUT_DIR/Dashi-$VERSION.dmg"

# Ad-hoc sign unless explicitly disabled — gives a stable identity (fewer Keychain prompts).
if [ "${DASHI_ADHOC:-1}" = "1" ]; then
    echo "==> codesign (ad-hoc)"
    codesign --force --deep --sign - "$APP"
    codesign --verify --verbose "$APP"
fi

# Stage just the app — create-dmg adds the /Applications drop-link itself.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"

mkdir -p "$OUT_DIR"
rm -f "$DMG"
echo "==> create-dmg $DMG"
# create-dmg lays out an icon-view window (app on the left, Applications alias on the right) and
# converts to a compressed read-only image. It can exit non-zero on a benign AppleScript hiccup,
# so we check the artifact landed rather than trusting the exit code alone.
create-dmg \
    --volname "Dashi" \
    --window-pos 200 120 \
    --window-size 600 380 \
    --icon-size 110 \
    --icon "Dashi.app" 160 185 \
    --app-drop-link 440 185 \
    --no-internet-enable \
    "$DMG" "$STAGE" || true

[ -f "$DMG" ] || {
    echo "create-dmg did not produce $DMG" >&2
    exit 1
}
hdiutil verify "$DMG"

# Publish a checksum alongside so downloaders can verify the artifact.
( cd "$OUT_DIR" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256" )

echo
echo "Built: $DMG"
echo "First launch is Gatekeeper-blocked (not notarized): users approve it once via"
echo "System Settings → Privacy & Security → \"Open Anyway\"."
