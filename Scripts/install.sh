#!/bin/bash
# Builds NotchShelf and installs it as a real, double-clickable app.
#
# Locally built bundles carry no com.apple.quarantine attribute, so Gatekeeper does not show
# the "unidentified developer" warning — that only applies to bundles downloaded by a browser.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/Scripts/build-app.sh" release

if [ -w /Applications ]; then DEST=/Applications; else DEST="$HOME/Applications"; fi
mkdir -p "$DEST"

pkill -f "NotchShelf.app/Contents/MacOS/NotchShelf" 2>/dev/null || true
sleep 0.5
rm -rf "$DEST/NotchShelf.app"
cp -R "$ROOT/build/NotchShelf.app" "$DEST/NotchShelf.app"
xattr -dr com.apple.quarantine "$DEST/NotchShelf.app" 2>/dev/null || true

echo "installed: $DEST/NotchShelf.app"
