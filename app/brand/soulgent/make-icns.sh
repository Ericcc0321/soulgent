#!/bin/bash
# Makes the app's icon (Soulgent.icns, 16 to 1024 with @2x) from app-icon-macos-1024.png, and the menu-bar icon
# (flame-mono.pdf, vector, cropped to the flame) from flame-mono.svg. Only sips, iconutil and swiftc, all on macOS.
# The 1024 already has macOS's margin, rounded corners and shadow (Soulgent final-v1), so it is only scaled here.
# Run it again after either source changes, and commit Soulgent.icns and flame-mono.pdf.
set -euo pipefail
cd "$(dirname "$0")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

set_dir="$work/Soulgent.iconset"
mkdir "$set_dir"
for pt in 16 32 128 256 512; do
    sips -z "$pt" "$pt" app-icon-macos-1024.png --out "$set_dir/icon_${pt}x${pt}.png" >/dev/null
    px=$((pt * 2))
    if [[ $px -eq 1024 ]]; then
        cp app-icon-macos-1024.png "$set_dir/icon_${pt}x${pt}@2x.png"
    else
        sips -z "$px" "$px" app-icon-macos-1024.png --out "$set_dir/icon_${pt}x${pt}@2x.png" >/dev/null
    fi
done
iconutil -c icns "$set_dir" -o Soulgent.icns
echo "Soulgent.icns"

# The menu-bar flame: NSImage reads the SVG (macOS 14+) and draws it into a PDF whose box is the flame's own bounds,
# so the picture is the glyph edge to edge. A PDF, not the SVG, ships: the app's target is macOS 14.
swiftc -target arm64-apple-macos14.0 make-menubar-pdf.swift -o "$work/make-menubar-pdf"
"$work/make-menubar-pdf" flame-mono.svg flame-mono.pdf
