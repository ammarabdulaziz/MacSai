#!/bin/bash
# Build and test this checkout on the user's Mac. No downloaded executable,
# sudo, quarantine removal, Gatekeeper changes, or upstream identity reuse.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
if [ "$(uname -s)" != Darwin ]; then
    echo "This installer requires macOS 14 or later and Xcode 16.3 or later."
    exit 1
fi
if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 14 ]; then
    echo "macOS 14 or later is required."
    exit 1
fi
if ! MACSAI_SWIFT=$(xcrun --find swift); then
    echo "Swift was not found. Install Xcode 16.3 or later and open it once to finish setup." >&2
    exit 1
fi
# Use the selected developer toolchain consistently, including child build scripts.
# A different swift earlier in PATH can otherwise mix package-manager components.
export PATH="$(dirname "$MACSAI_SWIFT"):$PATH"
SWIFT_VERSION=$("$MACSAI_SWIFT" --version)
echo "Swift executable: $MACSAI_SWIFT"
echo "$SWIFT_VERSION"
read -r SWIFT_MAJOR SWIFT_MINOR <<< "$(echo "$SWIFT_VERSION" | sed -nE 's/.*Swift version ([0-9]+)\.([0-9]+).*/\1 \2/p')"
if [[ ! "$SWIFT_MAJOR" =~ ^[0-9]+$ || ! "$SWIFT_MINOR" =~ ^[0-9]+$ ]]; then
    echo "Could not determine the Swift version. Use a Swift 6.1 or later toolchain." >&2
    exit 1
fi
if (( SWIFT_MAJOR < 6 || (SWIFT_MAJOR == 6 && SWIFT_MINOR < 1) )); then
    echo "Swift 6.1 or later is required by the locked dependencies. Install Xcode 16.3 or later." >&2
    exit 1
fi
# Detect a broken/mismatched PackageDescription installation before fetching
# dependencies. This checks the actual manifest, not just swift --version.
if ! "$MACSAI_SWIFT" package dump-package >/dev/null; then
    cat >&2 <<'TOOLCHAIN_HELP'
Swift could not load Package.swift. Nothing was installed.
If the error mentions undefined PackageDescription symbols, the selected
Command Line Tools / Swift installation may be incomplete or mismatched.
Install or update Xcode 16.3 or later, then open it once to finish setup.
If Xcode is installed at /Applications/Xcode.app, retry with:
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/install-personal.sh
This selects Xcode for this build only. It does not change xcode-select globally.
If it still fails, share the output of:
  xcode-select -p
  xcrun --find swift
  xcrun swift --version
TOOLCHAIN_HELP
    exit 1
fi
"$MACSAI_SWIFT" package resolve --force-resolved-versions
echo "Testing the current source checkout..."
"$MACSAI_SWIFT" test
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
