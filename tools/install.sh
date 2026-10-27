#!/bin/bash
# Installs Soulgent's launchd jobs for the current user:
#   io.github.ericcc0321.soulgent         opens app/Soulgent.app at login and reopens it after a crash
#   io.github.ericcc0321.soulgent.finder  runs tools/finder/finder_sessions.py every 60 s (only with --finder; it retags your project folders)
#     --root <folder> (repeat for more): the folders whose subfolders are your projects; none, those of ~/Projects,
#     ~/Developer and ~/code that exist.
# The plists are generated from launchd/*.plist.template into ~/Library/LaunchAgents/.
# Running it again replaces the jobs. tools/uninstall.sh removes them.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"
APP="$REPO/app/Soulgent.app"

with_finder=0
roots=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --finder) with_finder=1 ;;
        --root)
            [[ $# -ge 2 && -d "$2" ]] || { echo "--root needs an existing folder" >&2; exit 2; }
            roots+=("$(cd "$2" && pwd)")
            shift ;;
        -h|--help) echo "usage: tools/install.sh [--finder [--root <folder>]...]"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

if [[ ! -x "$APP/Contents/MacOS/Soulgent" ]]; then
    echo "Soulgent.app is not built yet. Run app/build.sh first." >&2
    exit 1
fi

# A path goes into the plist as XML text (& < > escaped), then into sed's replacement (\\ | & escaped); spaces and
# non-ASCII are fine as they are.
xml() { local s="${1//&/&amp;}"; s="${s//</&lt;}"; printf '%s' "${s//>/&gt;}"; }
escape() { printf '%s' "$(xml "$1")" | sed -e 's/[\\|&]/\\&/g'; }
repo_esc="$(escape "$REPO")"
home_esc="$(escape "$HOME")"
# The Finder tags' language follows the system's first preferred language, as the app does: zh-Hant for Traditional
# Chinese (by its script when it names one, so zh-Hans-HK is simplified; else zh-TW, zh-HK, zh-MO), zh-Hans for any other
# Chinese, en for everything else.
# No AppleLanguages (a new account may not have it yet) means English, not a failed install.
first_lang="$( (defaults read -g AppleLanguages 2>/dev/null || true) | sed -n '2s/[[:space:]",]//gp')"
case "$first_lang" in
    zh-Hans*) tag_lang=zh-Hans ;;
    zh-Hant*|zh-TW*|zh-HK*|zh-MO*|zh_TW*|zh_HK*|zh_MO*) tag_lang=zh-Hant ;;
    zh*) tag_lang=zh-Hans ;;
    *) tag_lang=en ;;
esac

# launchd will not start a job whose log file's folder is missing. Soulgent's data and logs live here (an older checkout
# kept them in state/ beside the code; the app and finder_sessions.py copy them over once).
mkdir -p "$HOME/Library/Application Support/Soulgent" "$AGENTS"

install_job() {
    local label="$1" template="$2"
    local plist="$AGENTS/$label.plist"
    sed -e "s|__REPO__|$repo_esc|g" -e "s|__HOME__|$home_esc|g" -e "s|__LANG__|$tag_lang|g" "$template" | while IFS= read -r line; do
        if [[ "$line" == *"<!--"* || "$line" != *__ROOTS__* ]]; then
            printf '%s\n' "$line"
            continue
        fi
        # The roots, a pair of lines each (& < > as XML wants them); none, no line.
        for root in ${roots[@]+"${roots[@]}"}; do
            printf '        <string>--root</string>\n        <string>%s</string>\n' "$(xml "$root")"
        done
    done > "$plist"
    plutil -lint "$plist" > /dev/null
    launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
    # bootout returns before the job is gone; bootstrapping it again too soon fails ("5: Input/output error").
    local waited=0
    while launchctl print "$DOMAIN/$label" > /dev/null 2>&1 && (( waited < 100 )); do
        sleep 0.1
        waited=$((waited + 1))
    done
    launchctl bootstrap "$DOMAIN" "$plist"
    echo "installed $label -> $plist"
    if [[ "$label" == *.finder ]]; then
        echo "  Finder tags in $tag_lang (the system's first language: ${first_lang:-unknown})"
    fi
}

install_job io.github.ericcc0321.soulgent "$REPO/launchd/io.github.ericcc0321.soulgent.plist.template"
if [[ "$with_finder" == 1 ]]; then
    install_job io.github.ericcc0321.soulgent.finder "$REPO/launchd/io.github.ericcc0321.soulgent.finder.plist.template"
    # Without --root the tagger looks in ~/Projects, ~/Developer and ~/code; with none of them there it tags nothing.
    if [[ ${#roots[@]} -eq 0 && ! -d "$HOME/Projects" && ! -d "$HOME/Developer" && ! -d "$HOME/code" ]]; then
        echo "  No ~/Projects, ~/Developer or ~/code here, so no folders will be tagged: run this again with --root <your projects folder>."
    fi
fi

echo
echo "Soulgent is running. Quit it from the menu-bar icon; launchd brings it back at the next login."
echo "Turning on the spotlight will ask for Accessibility access in System Settings > Privacy & Security."
