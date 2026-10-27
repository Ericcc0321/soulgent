#!/bin/bash
# Performance floor: the panel stays running and must not slow the Mac. Three numbers:
#   CPU < 5% while the panel is idle; < 15% with the Seaview scene open (it animates); one --dump < 0.6 s.
#   Another animated theme (an extension's scene, say) gives its CPU floor with PERF_CPU_LIMIT=<percent>.
# Usage: tools/dev/perf-check.sh [sample seconds, default 60]. Measures the running board process; restarts and changes nothing.
# CPU is the CPU time the process used in that span divided by wall-clock time (not the instantaneous ps value); the system load is printed too, and a high load inflates the numbers.
set -uo pipefail
cd "$(dirname "$0")/../.."
seconds="${1:-60}"
app="$PWD/Soulgent.app/Contents/MacOS/Soulgent"
domain=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" Soulgent.app/Contents/Info.plist 2>/dev/null)
pid=$(pgrep -f "Soulgent.app/Contents/MacOS/Soulgent$" | head -1)
[[ -n "$pid" ]] || { echo "perf: the board is not running"; exit 2; }

cputime() {  # cumulative CPU seconds of the process (ps TIME, format [[dd-]hh:]mm:ss.cc)
    ps -o time= -p "$1" | python3 -c '
import sys
t = sys.stdin.read().strip()
days, _, t = t.rpartition("-")
s = 0.0
for part in t.split(":"): s = s * 60 + float(part)
print("%.2f" % (s + (int(days) * 86400 if days else 0)))'
}
now() { python3 -c 'import time; print("%.3f" % time.time())'; }
theme=$(defaults read "$domain" officeTheme 2>/dev/null || echo "?")
limit=5
case "$theme" in *seaview*|*海景*) limit=15 ;; esac
limit="${PERF_CPU_LIMIT:-$limit}"

c0=$(cputime "$pid"); t0=$(date +%s)
sleep "$seconds"
c1=$(cputime "$pid"); t1=$(date +%s)
cpu=$(awk -v a="$c0" -v b="$c1" -v s="$((t1 - t0))" 'BEGIN { printf "%.1f", (b - a) / s * 100 }')

dumps=()
for i in 1 2 3; do
    s=$(now)
    "$app" --dump > /dev/null
    e=$(now)
    dumps+=("$(awk -v a="$s" -v b="$e" 'BEGIN { printf "%.2f", b - a }')")
done
dump=$(printf '%s\n' "${dumps[@]:1}" | sort -n | tail -1)  # the first run may be rescanning the cache; take the slower of the last two

load=$(sysctl -n vm.loadavg | tr -d '{}' | awk '{print $1}')
ok=1
awk -v c="$cpu" -v l="$limit" 'BEGIN { exit !(c < l) }' || ok=0
awk -v d="$dump" 'BEGIN { exit !(d < 0.6) }' || ok=0
echo "perf: theme ${theme}; board CPU ${cpu}% (floor ${limit}%, sampled ${seconds} s); --dump ${dump} s (three runs ${dumps[*]}, floor 0.6); system load ${load}"
if [[ $ok == 1 ]]; then echo "perf: pass"; else echo "perf: fail"; exit 1; fi
