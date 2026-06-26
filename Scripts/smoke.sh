#!/usr/bin/env bash
# Opt-in live smoke check — NOT part of `swift test` (which stays fully offline).
#
# Runs the app against real provider APIs using a key you place in the Keychain first, e.g.:
#   security add-generic-password -s com.dashi -a anthropic -w "$YOUR_ADMIN_KEY"
# then:
#   DASHI_PROVIDER_MODE=anthropic bash Scripts/smoke.sh
#
# This exists to validate the live path by hand against your own account; it makes real,
# potentially metered API calls, so it is never run in CI or the test suite.
set -euo pipefail

: "${DASHI_PROVIDER_MODE:=anthropic}"
export DASHI_PROVIDER_MODE

echo "Running Dashi live smoke check (mode=${DASHI_PROVIDER_MODE})."
echo "Note: live usage fetch is not implemented yet — this currently exercises the key lookup and"
echo "fail-closed path only. Finish the live provider before relying on this for real numbers."
swift run Dashi
