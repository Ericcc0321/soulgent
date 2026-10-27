#!/bin/bash
# Runs the checks in Tests.swift against Panel.swift. Nothing built here ships in the app.
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build
ln -sfn ../themes/seaview/assets build/zone3d
# The optional extension point (see build.sh) adds its own sources and checks: its test.inc.sh lists them in
# EXTENSION_SOURCES, links its art beside the checks (`extension_links`) and runs its own rounds first (`extension_rounds`).
# It is used only when named: SOULGENT_EXTENSION_DIR, or else the first line of app/.extension-dir (not in git; a
# relative path is from app/). Neither set, the checks run against the panel as it is here.
EXTENSION_DIR="${SOULGENT_EXTENSION_DIR:-}"
if [[ -z "$EXTENSION_DIR" && -f .extension-dir ]]; then IFS= read -r EXTENSION_DIR < .extension-dir || true; fi
EXTENSION_SOURCES=(NoExtensions.swift)
extension_links() { :; }
extension_rounds() { :; }
# Links an earlier run's extension left would point at nothing, or somewhere else, now: every link in build/ but the
# seaview art's goes first.
for link in build/*; do if [[ -L "$link" && "$link" != build/zone3d ]]; then rm -f "$link"; fi; done
if [[ -n "$EXTENSION_DIR" && -d "$EXTENSION_DIR" ]]; then
    EXTENSION_DIR="$(cd "$EXTENSION_DIR" && pwd)"
    source "$EXTENSION_DIR/test.inc.sh"
    echo "extension: $EXTENSION_DIR"
    extension_links
elif [[ -n "$EXTENSION_DIR" ]]; then
    echo "extension: $EXTENSION_DIR is not a folder; going on without it" >&2
fi
# The localization tables beside the checks' binary (L10n looks for build/i18n); after the links above are cleared.
ln -sfn ../i18n build/i18n
swiftc -parse-as-library -target arm64-apple-macos14.0 -D TESTING Panel.swift Data/Session.swift Data/Dump.swift Data/Loader.swift Adapters/ClaudeCode.swift Adapters/Codex.swift Adapters/WorkBuddy.swift Adapters/Orca.swift Office.swift Extensions.swift ZoneModel.swift ZoneView.swift ZoneFX.swift SessionSearch.swift JumpMark.swift Settings.swift L10n.swift DemoCrowd.swift ZoneTests.swift ZoneFXTests.swift JumpMarkTests.swift WalkFacingTests.swift MenuBarTests.swift BoardSweepTests.swift SeaviewSweepTests.swift FocusHoldTests.swift SceneExtensionTests.swift SummaryCodeTests.swift BackgroundFieldTests.swift BackgroundRenderTests.swift ErrorRenderTests.swift ErrorFieldTests.swift DeskCoverTests.swift I18nTests.swift FlameTests.swift NudgeTests.swift DumpLogTests.swift FormatWarningTests.swift VisitTests.swift DemoTests.swift FixTests.swift Tests.swift "${EXTENSION_SOURCES[@]}" -o build/SoulgentTests
# The checks keep their unread marks and pins in a defaults domain of their own; leave none
# behind. The system writes that domain's file a moment after the checks exit, hence the wait.
trap 'sleep 2; rm -f "$HOME/Library/Preferences/SoulgentTests.plist"' EXIT
extension_rounds
build/SoulgentTests
