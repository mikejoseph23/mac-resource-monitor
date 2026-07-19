#!/usr/bin/env bash
# Build a release .app bundle (with embedded Sparkle auto-updater) and pack it
# into a polished drag-to-Applications DMG modelled on the LymeScribe installer.
#
# Signing modes:
#   default      ad-hoc signed (Gatekeeper will warn on download; fine for local)
#   SIGN_ID=...  sign with the given codesign identity (e.g. "Developer ID
#                Application: NAME (TEAMID)"). Adds hardened runtime + secure
#                timestamp so the artifact is notarization-ready.
#   NOTARIZE_PROFILE=... after signing, submits the DMG to Apple's notary
#                service using the named keychain credential profile (created
#                via `xcrun notarytool store-credentials <name>`), waits for
#                approval, and staples the ticket. Requires SIGN_ID.
#
# Sparkle: Sparkle.framework is embedded in Contents/Frameworks and signed
# inside-out (XPC services → Autoupdate → Updater.app → framework → app) before
# the app itself, as Sparkle requires. After building the notarized DMG, run
# scripts/stage-release.sh to EdDSA-sign it and refresh the appcast.
#
# Output: dist/Mac Resource Monitor.app, dist/Mac Resource Monitor.dmg,
#         dist/Mac Resource Monitor.zip
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Mac Resource Monitor"
BIN_NAME="MacResourceMonitor"
VOL_NAME="$APP_NAME"
DIST="dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME.dmg"
ZIP="$DIST/$APP_NAME.zip"
SCRATCH="$DIST/.dmg-scratch"
RW_DMG="$DIST/.rw.dmg"
ENTITLEMENTS="src/MacResourceMonitor.entitlements"
SRC_PLIST="src/Info.plist"

SIGN_ID="${SIGN_ID:-}"
NOTARIZE_PROFILE="${NOTARIZE_PROFILE:-}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC_PLIST")"

# Codesign identity + hardening flags. Ad-hoc ("-") for local runs; a real
# Developer ID adds hardened runtime + a secure timestamp (needed to notarize).
if [ -n "$SIGN_ID" ]; then
    IDENT="$SIGN_ID"
    HARDEN=(--options runtime --timestamp)
else
    IDENT="-"
    HARDEN=()
fi

# Locate the Sparkle.framework that SwiftPM downloaded (the xcframework slice
# with the real binary + XPC services + Updater.app).
SPARKLE_FW="$(find .build/artifacts -type d -path '*Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework' 2>/dev/null | head -1)"
if [ -z "$SPARKLE_FW" ]; then
    echo "!! Sparkle.framework not found under .build/artifacts — run 'swift build' first" >&2
    exit 1
fi
FW_VER="$(readlink "$SPARKLE_FW/Versions/Current")"   # e.g. "B"

echo "==> Cleaning $DIST"
rm -rf "$APP" "$DMG" "$ZIP" "$SCRATCH" "$RW_DMG"
mkdir -p "$DIST"

echo "==> swift build -c release"
swift build -c release >/dev/null

echo "==> Assembling .app bundle (v$VERSION)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp ".build/arm64-apple-macosx/release/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"
cp src/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# src/Info.plist is the single source of truth (version, Sparkle SU* keys,
# CFBundleExecutable/IconFile) — copy it rather than regenerating inline.
cp "$SRC_PLIST" "$APP/Contents/Info.plist"

echo "==> Embedding Sparkle.framework"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
# The SwiftPM-built binary references @rpath/Sparkle.framework but only has an
# @loader_path rpath; add the Frameworks dir so it resolves inside the bundle.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$BIN_NAME" 2>/dev/null || true

echo "==> Signing Sparkle components inside-out (identity: $IDENT)"
FWV="$APP/Contents/Frameworks/Sparkle.framework/Versions/$FW_VER"
# XPC services first — preserve their shipped entitlements (Downloader.xpc is
# sandboxed; Installer.xpc is not).
codesign --force ${HARDEN[@]+"${HARDEN[@]}"} --preserve-metadata=entitlements --sign "$IDENT" "$FWV/XPCServices/Downloader.xpc"
codesign --force ${HARDEN[@]+"${HARDEN[@]}"} --preserve-metadata=entitlements --sign "$IDENT" "$FWV/XPCServices/Installer.xpc"
codesign --force ${HARDEN[@]+"${HARDEN[@]}"} --sign "$IDENT" "$FWV/Autoupdate"
codesign --force ${HARDEN[@]+"${HARDEN[@]}"} --sign "$IDENT" "$FWV/Updater.app"
codesign --force ${HARDEN[@]+"${HARDEN[@]}"} --sign "$IDENT" "$APP/Contents/Frameworks/Sparkle.framework"

echo "==> Signing .app (identity: $IDENT)"
# No --deep: nested Sparkle code is already signed above; --deep would clobber
# the XPC entitlements. Sign the app bundle last (outside-in completion).
codesign --force ${HARDEN[@]+"${HARDEN[@]}"} --entitlements "$ENTITLEMENTS" --sign "$IDENT" "$APP"
codesign --verify --strict "$APP"

echo "==> Building zip"
(cd "$DIST" && ditto -c -k --keepParent "$APP_NAME.app" "$APP_NAME.zip")

echo "==> Building DMG"
mkdir -p "$SCRATCH/.background"
cp -R "$APP" "$SCRATCH/"
ln -s /Applications "$SCRATCH/Applications"

# Brand background: generate 1x + @2x art and fuse into a HiDPI TIFF so Finder
# renders it at the correct point size on Retina (a bare 1200x800 PNG would be
# misread as 1200x800 pt).
swift scripts/draw-dmg-background.swift "$SCRATCH/.background"
tiffutil -cathidpicheck \
    "$SCRATCH/.background/background.png" \
    "$SCRATCH/.background/background@2x.png" \
    -out "$SCRATCH/.background/background.tiff" >/dev/null
rm -f "$SCRATCH/.background/background.png" "$SCRATCH/.background/background@2x.png"

# Window + icon layout (points). Must agree with draw-dmg-background.swift.
WIN_LEFT=200; WIN_TOP=120; WIN_W=600; WIN_H=400
WIN_RIGHT=$(( WIN_LEFT + WIN_W )); WIN_BOTTOM=$(( WIN_TOP + WIN_H ))
ICON_SIZE=128
APP_X=150; APP_Y=185
APPS_X=450; APPS_Y=185

# Create a writable image, mount it, script Finder to persist the layout, then
# convert to a compressed read-only DMG.
hdiutil create -volname "$VOL_NAME" -srcfolder "$SCRATCH" -ov \
  -fs HFS+ -format UDRW "$RW_DMG" >/dev/null

for stale in "/Volumes/$VOL_NAME" "/Volumes/$VOL_NAME 1" "/Volumes/$VOL_NAME 2"; do
    [ -d "$stale" ] && hdiutil detach "$stale" -force -quiet 2>/dev/null || true
done

hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen >/dev/null
MOUNT="/Volumes/$VOL_NAME"
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$MOUNT/$APP_NAME.app" ] && [ -e "$MOUNT/Applications" ] && break
    sleep 0.5
done

osascript <<APPLESCRIPT
tell application "Finder"
    activate
    tell disk "$VOL_NAME"
        open
        delay 2
        set theWindow to container window
        tell theWindow
            set current view to icon view
            set toolbar visible to false
            set statusbar visible to false
            set the bounds to {$WIN_LEFT, $WIN_TOP, $WIN_RIGHT, $WIN_BOTTOM}
        end tell
        delay 1
        set theViewOptions to the icon view options of theWindow
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to $ICON_SIZE
        set text size of theViewOptions to 13
        set background picture of theViewOptions to file ".background:background.tiff"
        delay 1
        set position of item "$APP_NAME.app" of theWindow to {$APP_X, $APP_Y}
        set position of item "Applications" of theWindow to {$APPS_X, $APPS_Y}
        delay 2
        close theWindow
    end tell
    delay 1
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT" -quiet 2>/dev/null || hdiutil detach "$MOUNT" -force -quiet

hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW_DMG"
rm -rf "$SCRATCH"

if [ -n "$SIGN_ID" ]; then
    echo "==> Signing DMG"
    codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
fi

if [ -n "$NOTARIZE_PROFILE" ]; then
    if [ -z "$SIGN_ID" ]; then
        echo "!! NOTARIZE_PROFILE set but SIGN_ID is empty — notarization needs a signed artifact" >&2
        exit 1
    fi
    echo "==> Submitting DMG to Apple notary (profile: $NOTARIZE_PROFILE)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARIZE_PROFILE" --wait
    echo "==> Stapling notarization ticket to DMG and .app"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    xcrun stapler staple "$APP"
    echo "==> Rebuilding zip with stapled .app"
    rm -f "$ZIP"
    (cd "$DIST" && ditto -c -k --keepParent "$APP_NAME.app" "$APP_NAME.zip")
fi

echo "==> Done"
ls -lh "$APP" "$DMG" "$ZIP" 2>/dev/null | awk '{print "    " $0}'
