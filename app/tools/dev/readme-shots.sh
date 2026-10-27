#!/bin/bash
# README pictures on the made-up crowd (--demo-crowd and its listed pets).
# usage: tools/dev/readme-shots.sh <output folder> <lang: en|zh-Hans|zh-Hant> [pets folder] [--build] [--only name,name]
#   Writes hero-seaview seaview-seats seaview-queue seaview-desk seaview-blaze seaview-orca seaview-beach seaview-visit
#   seaview-desk-menu office duty-room spotlight jump (.png) into <output folder>.
#   pets folder: where tools/dev/install-demo-pets.sh put them (default: <app>/tmp/demo-pets or $SOULGENT_DEMO_PETS).
#   --build compiles the checks' binary first (tools/dev/run-tests.sh --demo-only, which also runs the demo checks); it needs no Soulgent.app and starts no panel: nothing real is read.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:?output folder}"; LANGCODE="${2:?language}"; shift 2
PETS="${SOULGENT_DEMO_PETS:-$(pwd)/tmp/demo-pets}"
EXTRA=()
BUILD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) BUILD=1 ;;
    --only) EXTRA+=(--only "$2"); shift ;;
    *) PETS="$1" ;;
  esac
  shift
done
if [[ $BUILD == 1 || ! -x build/SoulgentTests ]]; then tools/dev/run-tests.sh --demo-only > /dev/null; fi
[[ -d "$PETS" ]] || { echo "no pets folder: $PETS" >&2; exit 1; }
mkdir -p "$OUT"
./build/SoulgentTests --demo-stills "$OUT" --lang "$LANGCODE" --pets-dir "$PETS" ${EXTRA[@]+"${EXTRA[@]}"} | /usr/bin/grep -a "^demo stills"
sleep 2; rm -f "$HOME/Library/Preferences/SoulgentTests.plist"
