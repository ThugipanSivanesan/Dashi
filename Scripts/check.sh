#!/usr/bin/env bash
# Single local gate: format-lint, swiftlint, build, test, and a coverage report. Mirrors the CI
# `test` job.
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

echo "==> swiftlint lint --strict"
if command -v swiftlint >/dev/null 2>&1; then
    swiftlint lint --strict
else
    echo "SKIPPED: swiftlint not installed (brew install swiftlint). CI still runs it."
fi

echo "==> swift build"
swift build

echo "==> swift test"
swift test --enable-code-coverage

echo "==> coverage report"
# Report-only: no threshold gates this script. The number covers DashiCore alone, since
# Sources/Dashi is an executable target and is not linked into the test bundle.
BIN="$(swift build --show-bin-path)"
xcrun llvm-cov report \
    "$BIN/DashiPackageTests.xctest/Contents/MacOS/DashiPackageTests" \
    -instr-profile "$BIN/codecov/default.profdata" \
    -ignore-filename-regex='.build|Tests/'

echo "All checks passed."
