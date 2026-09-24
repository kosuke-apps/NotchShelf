#!/bin/bash
# Builds NotchShelf.app. Xcode is not required — SwiftPM plus a hand-assembled bundle.
#
# Signing follows the mac-utilities policy (../AGENTS.md, "Code signing"): every app is signed
# with the one shared self-signed certificate "Mac Utilities Code Signing". macOS remembers
# privacy permissions by the app's designated requirement; with that certificate the
# requirement is the certificate plus the bundle identifier, so Screen Recording and
# Accessibility survive rebuilds. Without it the build falls back to ad-hoc signing, whose
# requirement is the binary's hash, and the permissions have to be granted again after every
# rebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/NotchShelf.app"
SIGNING_IDENTITY="Mac Utilities Code Signing"

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/NotchShelf"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NotchShelf"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$ROOT/Resources/Info.plist")"

# Look the certificate up by name among all code-signing identities, not only the ones macOS
# considers valid: a self-signed certificate is not trusted by default, and codesign signs with
# it regardless. Only this one certificate is used — never whichever identity happens to come
# first, which could be the Apple Development certificate meant for iPhone builds.
if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$SIGNING_IDENTITY\""; then
  if ! codesign --force --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID" \
       --timestamp=none "$APP"; then
    echo "error: \"$SIGNING_IDENTITY\" exists but codesign could not use it." >&2
    echo "       If Keychain Access asked for permission, allow codesign to use the key." >&2
    exit 1
  fi
  SIGNED_WITH="$SIGNING_IDENTITY"
else
  # Plain ad-hoc: the designated requirement stays the binary's hash. It is never narrowed to
  # the bundle identifier alone, which would let any binary claiming that identifier inherit
  # the permissions without anyone noticing.
  codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP"
  SIGNED_WITH="ad-hoc"
  echo "warning: signing certificate \"$SIGNING_IDENTITY\" not found; signed ad-hoc instead." >&2
  echo "         Screen Recording and Accessibility will have to be granted again after" >&2
  echo "         every rebuild. See \"Code signing\" in ../AGENTS.md." >&2
fi

codesign --verify --strict --verbose=1 "$APP" 2>&1 | sed 's/^/  /'
# An ad-hoc signature's requirement is implicit and printed with a leading "#".
echo "  designated requirement: $(codesign -d -r- "$APP" 2>&1 | sed -n 's/^#* *designated => //p')"
echo "built: $APP  (signed with: $SIGNED_WITH)"
