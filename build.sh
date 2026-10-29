#!/bin/bash
# Build, bundle and (optionally) run the pet.
#
#   ./build.sh            release build -> dist/AINEMATE Pet.app
#   ./build.sh dev        debug build + dev atlases from 02_assets, then run
#   ./build.sh run        run the bundled app
#   ./build.sh test       unit tests
#   ./build.sh install-pets
#                         copy the dev atlases into ~/.aimate/pets so the
#                         bundled app finds them without AIMATE_DEV_PETS_DIR
#
# The OpenAI spritesheets are development fixtures only: they are referenced by
# env var at run time and never copied into a build artifact. `install-pets`
# writes them to the user's own pet directory, which is user data and outside
# any build artifact.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
DIST="$ROOT/dist"
APP="$DIST/AINEMATE Pet.app"
BUNDLE_ID="com.aimate.pet"
DEV_PETS="$ROOT/../02_assets/dev_only_pets"

MODE="${1:-release}"

build_binary() {
    if [[ "$MODE" == "dev" ]]; then
        swift build
        BIN="$(swift build --show-bin-path)"
    else
        swift build -c release
        BIN="$(swift build -c release --show-bin-path)"
    fi
}

assemble_bundle() {
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

    cp "$BIN/AimatePet" "$APP/Contents/MacOS/AimatePet"
    cp "$BIN/pet-cli" "$APP/Contents/MacOS/pet-cli"
    chmod +x "$APP/Contents/MacOS/AimatePet" "$APP/Contents/MacOS/pet-cli"

    cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AimatePet</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>AINEMATE Pet</string>
    <key>CFBundleDisplayName</key><string>AINEMATE Pet</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

    # Ad-hoc signature: no developer identity is installed on this machine.
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
        codesign --force --sign - "$APP"
    echo "built: $APP"
}

install_pets() {
    local dest_root="${AIMATE_HOME:-$HOME/.aimate}/pets"
    [[ -d "$DEV_PETS" ]] || { echo "error: dev fixtures missing at $DEV_PETS" >&2; exit 66; }
    shopt -s nullglob
    local files=("$DEV_PETS"/*-spritesheet-v*.webp)
    shopt -u nullglob
    (( ${#files[@]} )) || { echo "error: no atlases in $DEV_PETS" >&2; exit 66; }

    mkdir -p "$dest_root"
    local src id dest display
    for src in "${files[@]}"; do
        id="$(basename "$src")"
        id="${id%%-spritesheet*}"
        dest="$dest_root/$id"
        mkdir -p "$dest"
        cp "$src" "$dest/spritesheet.webp"
        display="$(pet_display_name "$dest/pet.json" "$id")"
        cat > "$dest/pet.json" <<JSON
{
  "id": "$id",
  "displayName": "$display",
  "description": "Local pet atlas (personal use, not redistributed)",
  "spriteVersionNumber": 2,
  "spritesheetPath": "spritesheet.webp"
}
JSON
        echo "  $id -> $dest"
    done
    echo "installed ${#files[@]} pets into $dest_root"
}

# A name the user may already have picked wins over the derived one, so
# reinstalling never renames a pet out from under them.
pet_display_name() {
    python3 -c '
import json, sys
path, fallback = sys.argv[1], sys.argv[2]
try:
    name = json.load(open(path)).get("displayName")
except Exception:
    name = None
print(name or " ".join(part.capitalize() for part in fallback.split("-")))
' "$1" "$2"
}

case "$MODE" in
    test)
        # swift-testing ships inside the CommandLineTools; XCTest needs a full
        # Xcode install, which this machine does not have.
        # Once any target in the package imports AppKit/SwiftUI, the compiler
        # stops searching the toolchain's plugins/testing directory for the
        # macro implementation, so point at it explicitly.
        TESTING_PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
        swift test -Xswiftc -plugin-path -Xswiftc "$TESTING_PLUGINS"
        ;;
    dev)
        build_binary
        [[ -d "$DEV_PETS" ]] || { echo "warning: dev fixtures missing at $DEV_PETS" >&2; }
        echo "running with dev atlases from $DEV_PETS"
        AIMATE_DEV_PETS_DIR="$DEV_PETS" "$BIN/AimatePet"
        ;;
    run)
        MODE=release
        build_binary
        assemble_bundle
        open "$APP"
        ;;
    release)
        build_binary
        assemble_bundle
        ;;
    install-pets)
        install_pets
        ;;
    *)
        echo "usage: $0 [release|dev|run|test|install-pets]" >&2
        exit 64
        ;;
esac
