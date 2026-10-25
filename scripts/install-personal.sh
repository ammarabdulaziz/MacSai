#!/bin/bash
# Build and test this checkout on the user's Mac. No downloaded executable,
# sudo, quarantine removal, Gatekeeper changes, or upstream identity reuse.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
if [ "$(uname -s)" != Darwin ]; then
    echo "This installer requires macOS 14 or later and Xcode 16 or later."
    exit 1
fi
if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 14 ]; then
    echo "macOS 14 or later is required."
    exit 1
fi
xcrun --find swift >/dev/null
echo "Testing the current source checkout..."
swift test
BUILD_ARCHS="--arch $(uname -m)" bash scripts/build-dmg.sh --app-only
APP_BUNDLE=".build/dmg/Mac Sai Personal.app"
codesign --verify --deep --strict "$APP_BUNDLE"
IDENTIFIER=$(codesign -dv "$APP_BUNDLE" 2>&1 | sed -n 's/^Identifier=//p')
if [ "$IDENTIFIER" != com.ammarabdulaziz.macsai.app ]; then
    echo "Unexpected application identity. Nothing was installed."
    exit 1
fi
DEST_PARENT="$HOME/Applications"
DEST="$DEST_PARENT/Mac Sai Personal.app"
mkdir -p "$DEST_PARENT"
STAGE=$(mktemp -d "$DEST_PARENT/.macsai-install.XXXXXX")
cleanup() {
    if [ -d "$STAGE/previous.app" ] && [ ! -e "$DEST" ]; then
        mv "$STAGE/previous.app" "$DEST"
    fi
    # Retain previous versions for recovery, including after unexpected errors.
    if [ ! -e "$STAGE/previous.app" ]; then rm -rf "$STAGE"; fi
}
trap cleanup EXIT
ditto "$APP_BUNDLE" "$STAGE/new.app"
codesign --verify --deep --strict "$STAGE/new.app"
if [ -e "$DEST" ]; then
    if pgrep -f "$DEST/Contents/MacOS/MacClean" >/dev/null; then
        echo "The personal app is running. Quit it and run this script again."
        exit 1
    fi
    mv "$DEST" "$STAGE/previous.app"
fi
mv "$STAGE/new.app" "$DEST"
if [ -d "$STAGE/previous.app" ]; then
    echo "Previous version retained at: $STAGE/previous.app"
fi
echo "Installed: $DEST"
echo "This is a local, ad-hoc-signed build, not an Apple-notarized upstream release."
echo "Full Disk Access, automatic update checks, and the menu-bar login widget are not enabled by this installer."
echo "Open the app from your Applications folder when ready."
