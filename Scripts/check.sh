#!/usr/bin/env bash
# Single local gate: format-lint, build, and test. Mirrors the CI `test` job.
set -euo pipefail

# `swift test` needs XCTest, which ships with full Xcode rather than the Command Line Tools.
# If the active toolchain lacks it, fall back to a full Xcode install when present.
if ! xcrun --find xctest >/dev/null 2>&1; then
    if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    fi
fi

echo "==> swift format lint --strict"
swift format lint --strict --recursive Sources Tests Package.swift

echo "==> swift build"
swift build

echo "==> swift test"
swift test --enable-code-coverage

echo "All checks passed."
