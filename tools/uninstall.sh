#!/bin/bash
# Stops Soulgent's launchd jobs and removes their plists from ~/Library/LaunchAgents/.
# Leaves the app, its settings and any Finder tags already written untouched
# (tools/finder/finder_sessions.py --restore puts folders' original tags and comments back).
set -euo pipefail

AGENTS="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"

for label in io.github.ericcc0321.soulgent io.github.ericcc0321.soulgent.finder; do
    launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
    if [[ -f "$AGENTS/$label.plist" ]]; then
        rm -f "$AGENTS/$label.plist"
        echo "removed $label"
    fi
done
