#!/bin/bash
# Phone diagnostic log (once "Me -> Diagnostic log" is on, the phone sends events to /state/diag.jsonl in the api container)
# Usage: bash tools/diag.sh          follow the latest log (Ctrl-C to quit)
#        bash tools/diag.sh last 200 print the last 200 lines
#        bash tools/diag.sh clear    clear it (including the rotated diag.jsonl.1)
cd "$(dirname "$0")/.." || exit 1
F=/state/diag.jsonl
case "${1:-}" in
  "") exec docker compose exec api tail -F -n 20 "$F" ;;
  last) exec docker compose exec -T api tail -n "${2:-100}" "$F" ;;
  clear) docker compose exec -T api sh -c ": > $F; rm -f $F.1" && echo "cleared" ;;
  *) echo "usage: bash tools/diag.sh [last N | clear]" >&2; exit 2 ;;
esac
