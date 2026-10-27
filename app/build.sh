#!/bin/bash
# Builds Soulgent.app from Panel.swift. The Command Line Tools are enough, no Xcode needed.
set -euo pipefail
cd "$(dirname "$0")"

# A second copy of the app can be built under its own path, bundle id and name.
APP="${SOULGENT_APP_PATH:-Soulgent.app}"
BUNDLE_ID="${SOULGENT_BUNDLE_ID:-io.github.ericcc0321.soulgent}"
APP_NAME="${SOULGENT_APP_NAME:-Soulgent}"
# Optional extension point, for extra scenes that are not part of this repository: a directory holding build.inc.sh,
# which lists its Swift files in EXTENSION_SOURCES and copies its art in `extension_resources`. It is used only when
# named: SOULGENT_EXTENSION_DIR, or else the first line of app/.extension-dir (not in git; a relative path is from
# app/). Neither set, nothing extra is built.
EXTENSION_DIR="${SOULGENT_EXTENSION_DIR:-}"
if [[ -z "$EXTENSION_DIR" && -f .extension-dir ]]; then IFS= read -r EXTENSION_DIR < .extension-dir || true; fi
EXTENSION_SOURCES=(NoExtensions.swift)
extension_resources() { :; }
if [[ -n "$EXTENSION_DIR" && -d "$EXTENSION_DIR" ]]; then
    EXTENSION_DIR="$(cd "$EXTENSION_DIR" && pwd)"
    source "$EXTENSION_DIR/build.inc.sh"
    echo "extension: $EXTENSION_DIR"
elif [[ -n "$EXTENSION_DIR" ]]; then
    echo "extension: $EXTENSION_DIR is not a folder; going on without it" >&2
fi
mkdir -p build
# SwiftUI's @State is a macro: a Command Line Tools install without its plugin fails with "external macro implementation
# type 'SwiftUIMacros.StateMacro' could not be found". Views keep such state on the Store (@Published) instead.
STATE_USES=$(/usr/bin/grep -n -E '^[[:space:]]*@State([[:space:](]|$)' *.swift Data/*.swift Adapters/*.swift "${EXTENSION_SOURCES[@]/#/}" 2>/dev/null || true)
if [[ -n "$STATE_USES" ]]; then
    echo "build: @State needs SwiftUI's macro plugin, which a Command Line Tools install may lack; keep it on the Store:" >&2
    echo "$STATE_USES" >&2
    exit 1
fi
# The localization tables (i18n/<lang>.lproj): a broken one stops the build here, before anything is compiled.
I18N_LANGS=(en zh-Hans zh-Hant)
for lang in "${I18N_LANGS[@]}"; do
    for table in i18n/$lang.lproj/*.strings i18n/$lang.lproj/*.stringsdict; do plutil -lint -s "$table"; done
done
# Without an explicit target swiftc stamps a minimum OS newer than this Mac, and the
# system then refuses to launch the app (LaunchServices error -10825).
swiftc -O -parse-as-library -target arm64-apple-macos14.0 Panel.swift Data/Session.swift Data/Dump.swift Data/Loader.swift Adapters/ClaudeCode.swift Adapters/Codex.swift Adapters/WorkBuddy.swift Adapters/Orca.swift Office.swift Extensions.swift ZoneModel.swift ZoneView.swift ZoneFX.swift SessionSearch.swift JumpMark.swift Settings.swift L10n.swift DemoCrowd.swift "${EXTENSION_SOURCES[@]}" -o build/Soulgent

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp build/Soulgent "$APP/Contents/MacOS/Soulgent"
mkdir -p "$APP/Contents/Resources"
# Which way each pet's sheet runs (pets whose rows 1/2 do not run right/left), read by OfficePets.facingTable.
cp pet-facing.json "$APP/Contents/Resources/"
# The built-in flame, dealt only while no pet is installed (PetSources.builtIn); emptied first so nothing stale lingers.
rm -rf "$APP/Contents/Resources/pets"
mkdir -p "$APP/Contents/Resources/pets/soulflame"
cp brand/soulgent/pet/soulflame/pet.json brand/soulgent/pet/soulflame/spritesheet.webp "$APP/Contents/Resources/pets/soulflame/"
# The three languages' tables, as <lang>.lproj in Resources (L10n reads them; CFBundleLocalizations below names them).
for lang in "${I18N_LANGS[@]}"; do
    rm -rf "$APP/Contents/Resources/$lang.lproj"
    cp -R "i18n/$lang.lproj" "$APP/Contents/Resources/"
done
# The extension's art, if there is one.
extension_resources "$APP/Contents/Resources"
# Seaview: the night render and its points; the lit renders join them when they exist.
mkdir -p "$APP/Contents/Resources/zone3d"
cp themes/seaview/assets/points.json themes/seaview/assets/night_*.png "$APP/Contents/Resources/zone3d/"
# The outdoors: the sea loop (HEVC with alpha), its crab and gull sprites and outdoor.json.
# The sprites are per species (crab_cute/coconut/hermit_NN, gull_herring/blackhead/tern_NN); the folder is emptied
# first so no sprite dropped from the art lingers in the bundle.
rm -rf "$APP/Contents/Resources/zone3d/sprites"
mkdir -p "$APP/Contents/Resources/zone3d/sprites"
cp themes/seaview/assets/outdoor_loop.mov themes/seaview/assets/outdoor.json "$APP/Contents/Resources/zone3d/"
cp themes/seaview/assets/sprites/*.png "$APP/Contents/Resources/zone3d/sprites/"
# Each desk's foreground layers (off, screen lit, LED lit) and desk-layers.json; emptied first so a desk
# re-cut under another name does not linger.
rm -rf "$APP/Contents/Resources/zone3d/desks"
mkdir -p "$APP/Contents/Resources/zone3d/desks"
cp themes/seaview/assets/desks/*.png themes/seaview/assets/desks/desk-layers.json "$APP/Contents/Resources/zone3d/desks/"
# The three orca clips (HEVC with alpha) and orca.json (their boxes, laid over the sea loop from its frame 0).
cp themes/seaview/assets/A.mov themes/seaview/assets/B.mov themes/seaview/assets/C.mov themes/seaview/assets/orca.json "$APP/Contents/Resources/zone3d/"
# The Soulgent flame (the menu-bar icon, a template PDF) and the app icon's 1024 (About); the app icon itself
# (Soulgent.icns, CFBundleIconFile below). All three are made by brand/soulgent/make-icns.sh.
mkdir -p "$APP/Contents/Resources/brand/soulgent"
cp brand/soulgent/flame-mono.pdf brand/soulgent/app-icon-macos-1024.png "$APP/Contents/Resources/brand/soulgent/"
cp brand/soulgent/Soulgent.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
        <string>zh-Hant</string>
    </array>
    <key>CFBundleExecutable</key>
    <string>Soulgent</string>
    <key>CFBundleIconFile</key>
    <string>Soulgent</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF
# A fixed signing identity keeps the app's Accessibility grant across rebuilds: macOS ties the grant to the signer, and an
# ad-hoc signature ("-") changes with every build. The identity is the name of a code-signing certificate in the keychain,
# taken from SOULGENT_SIGNING_IDENTITY, or else the first line of app/.signing-identity (not in git). "-" or empty means
# ad-hoc; a name the keychain does not have also falls back to ad-hoc rather than failing the build.
SIGNING_IDENTITY="${SOULGENT_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" && -f .signing-identity ]]; then IFS= read -r SIGNING_IDENTITY < .signing-identity || true; fi
if [[ -n "$SIGNING_IDENTITY" && "$SIGNING_IDENTITY" != "-" ]] && ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$SIGNING_IDENTITY\""; then
    echo "note: signing identity \"$SIGNING_IDENTITY\" not found in the keychain, using ad-hoc"
    SIGNING_IDENTITY="-"
fi
if [[ -n "$SIGNING_IDENTITY" && "$SIGNING_IDENTITY" != "-" ]]; then
    codesign --force --sign "$SIGNING_IDENTITY" "$APP"
else
    echo "note: signed ad-hoc, which is fine; macOS asks for Accessibility again after each rebuild (set SOULGENT_SIGNING_IDENTITY or app/.signing-identity to keep the grant)"
    codesign --force --sign - "$APP"
fi
echo "built $APP"
