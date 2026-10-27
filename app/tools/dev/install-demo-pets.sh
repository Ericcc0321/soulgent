#!/bin/bash
# Installs the demonstration pets (19 from Petdex) into a folder of their own, never into ~/.petdex/pets:
# petdex is run with a scratch HOME, its pets folder is moved to <target>, the built-in flame is copied beside them.
# usage: tools/dev/install-demo-pets.sh <target folder, e.g. app/tmp/demo-pets>
set -euo pipefail
cd "$(dirname "$0")/../.."
TARGET="${1:?target folder}"
[[ -e "$TARGET" ]] && { echo "$TARGET exists; move it away first" >&2; exit 1; }
SCRATCH="$(mktemp -d)"
(cd /tmp && HOME="$SCRATCH" npx -y petdex@latest install little-deer blue-boba-axolotl milk-tea-koala whaley byte-bunny boxcat prompt-penguin scarf-hamster octopus penguin-chick terminal-ghost-2 red-panda acorn-squirrel wave-whale cloudlet cream-cat lint-sprout sea-lion cloudy)
mv "$SCRATCH/.petdex/pets" "$TARGET"
cp -R brand/soulgent/pet/soulflame "$TARGET/soulflame"
echo "installed $(ls "$TARGET" | wc -l) pets in $TARGET (scratch HOME $SCRATCH can be deleted)"
