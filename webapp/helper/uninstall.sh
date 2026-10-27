#!/bin/bash
# Stop and uninstall the helper. Same label as install.sh (SOULGENT_HELPER_LABEL from the environment or webapp/.env,
# default io.github.ericcc0321.soulgent.helper).
WEBAPP="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "$SOULGENT_HELPER_LABEL" ] || SOULGENT_HELPER_LABEL="$(sed -n 's/^SOULGENT_HELPER_LABEL=//p' "$WEBAPP/.env" 2>/dev/null | tail -n 1 | tr -d "\"' ")"
LABEL="${SOULGENT_HELPER_LABEL:-io.github.ericcc0321.soulgent.helper}"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
echo "Uninstalled $LABEL"
