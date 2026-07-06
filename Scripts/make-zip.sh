#!/usr/bin/env bash
# Package Dashi.app into a Sparkle-friendly .zip (ditto --keepParent) with a SHA-256 sidecar.
#
# The .zip is the format Sparkle's appcast serves (see Scripts/generate-appcast.sh) and a convenient
# alternative to the .dmg for Homebrew casks. Like make-dmg.sh it ad-hoc signs by default so the
# bundle has a stable identity; a Developer ID + notarized release runs Scripts/sign-and-notarize.sh
# first and sets DASHI_ADHOC=0 so this script leaves the real signature intact. See RELEASING.md.
set -euo pipefail

DERIVED="${DERIVED:-.build/xcode}"
APP="$DERIVED/Build/Products/Release/Dashi.app"
OUT_DIR="${OUT_DIR:-dist}"

# Build the app bundle if it isn't there yet (build-app.sh is unsigned by default).
if [ ! -d "$APP" ]; then
    echo "==> $APP not found — building it"
    bash Scripts/build-app.sh
fi

# Artifact version comes from project.yml's MARKETING_VERSION.
VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' project.yml)"
VERSION="${VERSION:-0.0.0}"
ZIP="$OUT_DIR/Dashi-$VERSION.zip"

# Ad-hoc sign unless explicitly disabled (the notarized path sets DASHI_ADHOC=0 to keep its own sig).
if [ "${DASHI_ADHOC:-1}" = "1" ]; then
    echo "==> codesign (ad-hoc)"
    codesign --force --deep --sign - "$APP"
    codesign --verify --verbose "$APP"
fi

mkdir -p "$OUT_DIR"
rm -f "$ZIP"
echo "==> ditto -c -k --keepParent $ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# Publish a checksum alongside so downloaders (and Homebrew casks) can verify the artifact.
( cd "$OUT_DIR" && shasum -a 256 "$(basename "$ZIP")" | tee "$(basename "$ZIP").sha256" )

echo
echo "Built: $ZIP"
