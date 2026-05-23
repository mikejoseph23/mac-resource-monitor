#!/usr/bin/env bash
# Build a release .app bundle and pack it into a polished drag-to-Applications
# DMG.
#
# Signing modes:
#   default      ad-hoc signed (Gatekeeper will warn on download)
#   SIGN_ID=...  sign with the given codesign identity (e.g. "Developer ID
#                Application: NAME (TEAMID)"). Adds hardened runtime + secure
#                timestamp so the artifact is notarization-ready.
#   NOTARIZE_PROFILE=... after signing, submits the DMG to Apple's notary
#                service using the named keychain credential profile (created
#                via `xcrun notarytool store-credentials <name>`), waits for
#                approval, and staples the ticket. Requires SIGN_ID.
#
# Output: dist/Mac Resource Monitor.app, dist/Mac Resource Monitor.dmg,
#         dist/Mac Resource Monitor.zip
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Mac Resource Monitor"
BIN_NAME="MacResourceMonitor"
BUNDLE_ID="com.mikejoseph.mac-resource-monitor"
VOL_NAME="$APP_NAME"
DIST="dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME.dmg"
ZIP="$DIST/$APP_NAME.zip"
SCRATCH="$DIST/.dmg-scratch"
RW_DMG="$DIST/.rw.dmg"
ENTITLEMENTS="src/MacResourceMonitor.entitlements"

SIGN_ID="${SIGN_ID:-}"
NOTARIZE_PROFILE="${NOTARIZE_PROFILE:-}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' src/Info.plist 2>/dev/null || echo 0.1.0)"

echo "==> Cleaning $DIST"
rm -rf "$APP" "$DMG" "$ZIP" "$SCRATCH" "$RW_DMG"
mkdir -p "$DIST"

echo "==> swift build -c release"
swift build -c release >/dev/null

echo "==> Assembling .app bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/arm64-apple-macosx/release/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"
cp src/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundleExecutable</key>
	<string>$BIN_NAME</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
</dict>
</plist>
PLIST

if [ -n "$SIGN_ID" ]; then
    echo "==> Signing .app with $SIGN_ID"
    codesign --force --deep --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_ID" "$APP"
else
    echo "==> Ad-hoc signing .app"
    codesign --force --deep --sign - "$APP" >/dev/null
fi
codesign --verify --deep --strict "$APP"

echo "==> Building zip"
(cd "$DIST" && ditto -c -k --keepParent "$APP_NAME.app" "$APP_NAME.zip")

echo "==> Building DMG"
mkdir -p "$SCRATCH"
cp -R "$APP" "$SCRATCH/"
ln -s /Applications "$SCRATCH/Applications"

# Generate background image with the drag-to-install arrow and hide it
# inside .background/ so it never shows up in the DMG window.
mkdir -p "$SCRATCH/.background"
swift scripts/draw-dmg-background.swift "$SCRATCH/.background/background.png"

# Create a writable DMG, mount it, set view options via Finder, then convert
# to a compressed read-only DMG. The intermediate RW image lets us persist
# .DS_Store with our icon positions and view settings.
hdiutil create -volname "$VOL_NAME" -srcfolder "$SCRATCH" -ov \
  -fs HFS+ -format UDRW "$RW_DMG" >/dev/null

# Defensively detach any stale mounts of a previous run before re-attaching,
# otherwise hdiutil will mount as "$VOL_NAME 1" and the scripted positioning
# will target the wrong window.
for stale in "/Volumes/$VOL_NAME" "/Volumes/$VOL_NAME 1" "/Volumes/$VOL_NAME 2"; do
    [ -d "$stale" ] && hdiutil detach "$stale" -force -quiet 2>/dev/null || true
done

# Mount at the standard /Volumes path so Finder registers the volume and
# indexes its items — using -mountpoint can suppress this and cause AppleScript
# position commands to fail with -10006.
hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen >/dev/null
MOUNT="/Volumes/$VOL_NAME"

# Give Finder a moment to mount and index items before scripting it.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$MOUNT/$APP_NAME.app" ] && [ -e "$MOUNT/Applications" ] && break
    sleep 0.5
done

BG_POSIX="$MOUNT/.background/background.png"

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
            set the bounds to {200, 120, 800, 500}
        end tell
        delay 1
        set theViewOptions to the icon view options of theWindow
        set icon size of theViewOptions to 160
        set text size of theViewOptions to 13
        set background picture of theViewOptions to POSIX file "$BG_POSIX"
        delay 1
        repeat with anItem in (get items of theWindow)
            set n to name of anItem
            try
                if n ends with ".app" then
                    set position of anItem to {160, 180}
                else if n is "Applications" then
                    set position of anItem to {440, 180}
                end if
            end try
        end repeat
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
    xcrun notarytool submit "$DMG" \
        --keychain-profile "$NOTARIZE_PROFILE" \
        --wait
    echo "==> Stapling notarization ticket to DMG and .app"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    # Staple the .app too so users who download the zip get an offline-verifiable
    # bundle. Without this, Gatekeeper has to fetch the ticket online on first
    # launch from the unzipped app.
    xcrun stapler staple "$APP"
    echo "==> Rebuilding zip with stapled .app"
    rm -f "$ZIP"
    (cd "$DIST" && ditto -c -k --keepParent "$APP_NAME.app" "$APP_NAME.zip")
fi

echo "==> Done"
ls -lh "$APP" "$DMG" "$ZIP" 2>/dev/null | awk '{print "    " $0}'
