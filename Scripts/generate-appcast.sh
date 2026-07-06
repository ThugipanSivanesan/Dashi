#!/usr/bin/env bash
# Generate/refresh appcast.xml from the signed .zip(s) in dist/ using Sparkle's generate_appcast.
#
# generate_appcast EdDSA-signs each update using the private key in your login Keychain — created
# once with Sparkle's `generate_keys` (the matching public key goes in App/Info.plist's SUPublicEDKey).
# Host the resulting appcast.xml at the SUFeedURL in Info.plist. See RELEASING.md.
#
# Reads (optional):
#   OUT_DIR              — folder holding the release .zip(s) (default: dist)
#   DOWNLOAD_URL_PREFIX  — public URL prefix for the download links, e.g.
#                          https://github.com/ThugipanSivanesan/Dashi/releases/download/v0.2.0/
set -euo pipefail

OUT_DIR="${OUT_DIR:-dist}"

# generate_appcast ships inside the resolved Sparkle SPM artifact; `swift build` fetches it.
TOOL="$(find .build -path '*/Sparkle/bin/generate_appcast' -type f 2>/dev/null | head -1)"
[ -z "$TOOL" ] && TOOL="$(find .build/artifacts -name generate_appcast -type f 2>/dev/null | head -1)"
[ -z "$TOOL" ] && TOOL="$(command -v generate_appcast || true)"
if [ -z "$TOOL" ]; then
    echo "generate_appcast not found." >&2
    echo "Run 'swift build' once to fetch Sparkle's tools, then re-run. (https://sparkle-project.org)" >&2
    exit 1
fi

ARGS=("$OUT_DIR")
if [ -n "${DOWNLOAD_URL_PREFIX:-}" ]; then
    ARGS+=(--download-url-prefix "$DOWNLOAD_URL_PREFIX")
fi

echo "==> $TOOL ${ARGS[*]}"
"$TOOL" "${ARGS[@]}"

# generate_appcast writes <OUT_DIR>/appcast.xml; surface it at the repo root for the raw SUFeedURL.
if [ -f "$OUT_DIR/appcast.xml" ]; then
    cp "$OUT_DIR/appcast.xml" appcast.xml
    echo "Wrote appcast.xml (commit it / host it at the SUFeedURL in App/Info.plist)."
fi
