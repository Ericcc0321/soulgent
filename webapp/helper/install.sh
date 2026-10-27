#!/bin/bash
# Install and start the helper (launchd user agent). Safe to re-run.
# The plist is generated from the template (the actual repo path is filled into __WEBAPP__); no home directory is hard-coded.
#   bash helper/install.sh          generate into ~/Library/LaunchAgents and (re)start
#   bash helper/install.sh --print  only print the generated plist, don't install (for checking)
# The label can be changed with SOULGENT_HELPER_LABEL (environment, or the same field in webapp/.env); the default is
# io.github.ericcc0321.soulgent.helper. If SOULGENT_HELPER_LABEL_LEGACY names an older label that is still loaded, it is
# stopped and its plist removed first, so two helpers never run at once.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
WEBAPP="$(cd "$HERE/.." && pwd)"
# Fall back to the same-named .env field when the env var is unset
env_field() {
  sed -n "s/^$1=//p" "$WEBAPP/.env" 2>/dev/null | tail -n 1 | tr -d "\"' "
}
[ -n "$SOULGENT_HELPER_LABEL" ] || SOULGENT_HELPER_LABEL="$(env_field SOULGENT_HELPER_LABEL)"
[ -n "$SOULGENT_HELPER_LABEL_LEGACY" ] || SOULGENT_HELPER_LABEL_LEGACY="$(env_field SOULGENT_HELPER_LABEL_LEGACY)"
LABEL="${SOULGENT_HELPER_LABEL:-io.github.ericcc0321.soulgent.helper}"
LEGACY="$SOULGENT_HELPER_LABEL_LEGACY"
[ "$LEGACY" != "$LABEL" ] || LEGACY=""
TEMPLATE="$HERE/soulgent-helper.plist.template"
DEST="$HOME/Library/LaunchAgents/$LABEL.plist"

# Escape & < > for XML, then escape \ | & for the sed replacement string
xml_sed() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/[\\|&]/\\&/g'
}
# SOULGENT_* variables set in the install environment are written into the plist EnvironmentVariables, because launchd does not
# inherit the shell that ran the installer. Only the names helper/settings.py reads are persisted. Changing them later needs a
# reinstall (or put the same field in webapp/.env, which the helper reads at start).
ENV_NAMES="SOULGENT_PANEL SOULGENT_PANEL_DOMAIN SOULGENT_PANEL_DOMAIN_LEGACY SOULGENT_CLAUDE_DIR SOULGENT_CLAUDE_BIN SOULGENT_ORCA_BIN SOULGENT_ORCA_STATS_DIR SOULGENT_WORKZONES SOULGENT_ROSTER SOULGENT_LINEAGE SOULGENT_STATUSLINE_DIR SOULGENT_PETDEX_DIR SOULGENT_OFFDUTY SOULGENT_ZONE_STYLE"
# <key>/<string> pairs for each supported variable that is set and non-empty, XML-escaped (& < >)
env_extra() {
  for n in $ENV_NAMES; do
    v="$(printenv "$n" 2>/dev/null || true)"
    [ -n "$v" ] || continue
    printf '        <key>%s</key>\n        <string>%s</string>\n' "$n" "$(printf '%s' "$v" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
  done
}
render() {
  EXTRA="$(env_extra)" awk '{ if ($0 == "__ENV_EXTRA__") { if (ENVIRON["EXTRA"] != "") print ENVIRON["EXTRA"] } else print }' "$TEMPLATE" |
    sed -e "s|__WEBAPP__|$(xml_sed "$WEBAPP")|g" -e "s|__LABEL__|$(xml_sed "$LABEL")|g"
}

if [ "$1" = "--print" ]; then
  render
  # Only print a notice; do not touch launchctl
  [ -z "$LEGACY" ] || echo "(install will first unload the legacy label $LEGACY)" >&2
  exit 0
fi

mkdir -p "$WEBAPP/data" "$HOME/Library/LaunchAgents"
# If the legacy label is still running, stop it and remove its plist so two helpers never run at once
if [ -n "$LEGACY" ]; then
  if launchctl print "gui/$(id -u)/$LEGACY" >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/$LEGACY" 2>/dev/null || true
    echo "Stopped legacy label $LEGACY"
  fi
  rm -f "$HOME/Library/LaunchAgents/$LEGACY.plist"
fi
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
render > "$DEST"
launchctl bootstrap "gui/$(id -u)" "$DEST"
echo "Installed and started $LABEL"
