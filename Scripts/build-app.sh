#!/usr/bin/env bash
# Generate the Xcode project from project.yml and build Dashi.app (Release).
#
# By default signing is disabled so it builds anywhere. For a distributable build, set
# DASHI_SIGN=1 (and a DEVELOPMENT_TEAM in project.yml / via Xcode), then sign + notarize per
# RELEASING.md.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DERIVED="${DERIVED:-.build/xcode}"

command -v xcodegen >/dev/null || {
    echo "xcodegen not found — install with: brew install xcodegen" >&2
    exit 1
}

echo "==> xcodegen generate"
xcodegen generate

SIGN_ARGS="CODE_SIGNING_ALLOWED=NO"
if [ "${DASHI_SIGN:-0}" = "1" ]; then SIGN_ARGS=""; fi

echo "==> xcodebuild (Release)"
xcodebuild -project Dashi.xcodeproj -scheme DashiApp -configuration Release \
    -derivedDataPath "$DERIVED" -destination 'platform=macOS' \
    $SIGN_ARGS build

echo "Built: $DERIVED/Build/Products/Release/Dashi.app"
