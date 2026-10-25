#!/bin/bash
# Remove only this fork's app. Retain user data and the official Mac Sai app.
set -euo pipefail
DEST="$HOME/Applications/Mac Sai Personal.app"
if [ ! -d "$DEST" ]; then echo "Mac Sai Personal is not installed at $DEST"; exit 0; fi
IDENTIFIER=$(codesign -dv "$DEST" 2>&1 | sed -n 's/^Identifier=//p')
if [ "$IDENTIFIER" != com.ammarabdulaziz.macsai.app ]; then
    echo "Unexpected identity; refusing to remove this app."
    exit 1
fi
if pgrep -f "$DEST/Contents/MacOS/MacClean" >/dev/null; then
    echo "Quit Mac Sai Personal before uninstalling."
    exit 1
fi
rm -rf "$DEST"
echo "Removed Mac Sai Personal. Preferences and logs were retained."
