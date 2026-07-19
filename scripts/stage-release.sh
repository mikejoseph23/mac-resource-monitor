#!/usr/bin/env bash
# Prepare a Mac Resource Monitor release for upload to iadev.net.
#
# Given a notarized DMG (built by scripts/make-dmg.sh), this:
#   1. renames/copies it to the versioned convention MacResourceMonitor-vX.Y.Z.dmg
#   2. computes its size and EdDSA-signs it with Sparkle's sign_update (private
#      key from the login Keychain — the same "ed25519" key SUPublicEDKey pins)
#   3. rewrites deploy/updates/appcast.xml: enclosure url, sparkle:version
#      (CFBundleVersion), sparkle:shortVersionString, length, edSignature, pubDate
#   4. stages the versioned DMG + appcast.xml + web.config into dist/upload/
#
# Then upload EVERYTHING in dist/upload/ to iadev.net/mac-resource-monitor/ and
# purge the Cloudflare cache for appcast.xml (same URL, new content).
#
# Usage:
#   scripts/stage-release.sh [path/to/Some.dmg]
# Defaults to "dist/Mac Resource Monitor.dmg" (make-dmg.sh's output).
set -euo pipefail

cd "$(dirname "$0")/.."

SRC_DMG="${1:-dist/Mac Resource Monitor.dmg}"
[ -f "$SRC_DMG" ] || { echo "!! DMG not found: $SRC_DMG" >&2; exit 1; }

APPCAST="deploy/updates/appcast.xml"
UPLOAD="dist/upload"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' src/Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' src/Info.plist)"
DMG_NAME="MacResourceMonitor-v$VERSION.dmg"
VERSIONED_DMG="dist/$DMG_NAME"
FEED_URL="https://iadev.net/mac-resource-monitor/$DMG_NAME"

echo "==> Staging release v$VERSION (build $BUILD)"
cp "$SRC_DMG" "$VERSIONED_DMG"

SIZE="$(stat -f%z "$VERSIONED_DMG")"

# Locate Sparkle's sign_update (bundled in the SwiftPM artifacts).
SIGN_TOOL="$(find .build/artifacts -name sign_update -not -path '*/old_dsa_scripts/*' 2>/dev/null | head -1)"
[ -n "$SIGN_TOOL" ] || { echo "!! sign_update not found — run 'swift build' first" >&2; exit 1; }

SIGN_OUT="$("$SIGN_TOOL" "$VERSIONED_DMG")"
ED_SIG="$(echo "$SIGN_OUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
[ -n "$ED_SIG" ] || { echo "!! could not extract edSignature from: $SIGN_OUT" >&2; exit 1; }

PUBDATE="$(date -u +'%a, %d %b %Y %H:%M:%S +0000')"

echo "==> Rewriting $APPCAST"
#   size:            $SIZE
#   ed signature:    $ED_SIG
python3 - "$APPCAST" "$FEED_URL" "$BUILD" "$VERSION" "$ED_SIG" "$SIZE" "$PUBDATE" <<'PY'
import sys, re
path, url, build, short, sig, size, pubdate = sys.argv[1:8]
x = open(path).read()
x = re.sub(r'url="[^"]*"',                      f'url="{url}"', x)
x = re.sub(r'sparkle:version="[^"]*"',          f'sparkle:version="{build}"', x)
x = re.sub(r'sparkle:shortVersionString="[^"]*"', f'sparkle:shortVersionString="{short}"', x)
x = re.sub(r'sparkle:edSignature="[^"]*"',      f'sparkle:edSignature="{sig}"', x)
x = re.sub(r'length="[^"]*"',                   f'length="{size}"', x)
x = re.sub(r'<pubDate>[^<]*</pubDate>',         f'<pubDate>{pubdate}</pubDate>', x)
open(path, 'w').write(x)
PY

echo "==> Staging upload folder: $UPLOAD"
rm -rf "$UPLOAD"; mkdir -p "$UPLOAD"
cp "$VERSIONED_DMG" "$UPLOAD/"
cp "$APPCAST" "$UPLOAD/"
cp deploy/updates/web.config "$UPLOAD/"
cp deploy/updates/screenshot.png "$UPLOAD/"
# Landing page: rewrite the DMG filename + version labels to this release so the
# download button and version text track the release without a manual edit.
sed -e "s|MacResourceMonitor-v[0-9][0-9.]*\.dmg|$DMG_NAME|g" \
    -e "s|v[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}|v$VERSION|g" \
    deploy/updates/index.html > "$UPLOAD/index.html"

echo ""
echo "Done. Upload EVERYTHING in $UPLOAD/ to iadev.net/mac-resource-monitor/ :"
ls -lh "$UPLOAD/" | awk 'NR>1{print "    " $9 "  (" $5 ")"}'
echo ""
echo "Then purge Cloudflare cache for appcast.xml (same URL, new content)."
echo "Verify the DMG's EdDSA signature is what shipped:"
echo "    \"$SIGN_TOOL\" \"$VERSIONED_DMG\""
