#!/bin/bash
# Installs characters from Petdex (https://petdex.dev) for Soulgent, all in one run of the Petdex installer.
#   tools/install-pets.sh              the ids in examples/pets.txt
#   tools/install-pets.sh <file>       the ids in <file>: one per line; blank lines and lines starting with # are skipped
# Needs Node.js (npx). The characters go where Petdex puts them (~/.petdex/pets/); Soulgent picks them up within a minute.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# The Petdex version this was checked with; to upgrade, change it here.
PETDEX="petdex@1.4.0"
LIST="${1:-$REPO/examples/pets.txt}"

[[ -f "$LIST" ]] || { echo "No list of pets at $LIST" >&2; exit 1; }
command -v npx >/dev/null || { echo "npx not found: install Node.js first (https://nodejs.org, or: brew install node), then run this again." >&2; exit 1; }

ids=()
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(echo "$line" | tr -d '[:space:]')"
    [[ -n "$line" ]] && ids+=("$line")
done < "$LIST"
[[ ${#ids[@]} -gt 0 ]] || { echo "No pet ids in $LIST" >&2; exit 1; }

echo "Installing ${#ids[@]} pets from $LIST"
npx -y "$PETDEX" install "${ids[@]}"
echo "Installed ${#ids[@]} pets."
