#!/bin/bash
# Runs a single group of checks (test.sh takes no arguments): tools/dev/run-tests.sh --zone-only (others: --focus-only --sync-only --origin-only --jump-mark-only --cards-only --walk-only --aura-only --summary-only --bg-only --error-only --desk-cover-only --i18n-only --flame-only --format-only)
set -euo pipefail
cd "$(dirname "$0")/../.."
line=$(grep -n '^swiftc' test.sh | cut -d: -f1)
bash -c "$(sed -n "6,${line}p" test.sh)"
trap 'sleep 2; rm -f "$HOME/Library/Preferences/SoulgentTests.plist"' EXIT
build/SoulgentTests "$@"
