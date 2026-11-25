#!/bin/bash
# Builds a signed Release archive of Slate for macOS and installs it in /Applications.
# Your library is kept: it lives in the App Group container, not inside the app.
#
# Usage: scripts/install-mac.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ARCHIVE=build/Slate.xcarchive
DEST=/Applications/Slate.app
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

echo "==> Archiving Release build"
rm -rf "$ARCHIVE"
xcodebuild archive \
    -project SlideshowApp.xcodeproj \
    -scheme SlideshowApp \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    -quiet

APP="$ARCHIVE/Products/Applications/Slate.app"
codesign --verify --deep --strict "$APP"

echo "==> Installing to $DEST"
osascript -e 'tell application id "com.garvinchanderia.slate" to quit' 2>/dev/null || true
sleep 1
rm -rf "$DEST"
ditto "$APP" "$DEST"

echo "==> Registering $DEST as the only Mac copy"
# Xcode's build folders also contain Slate.app copies (including the iPhone build, which
# Apple-silicon Macs can run). If they stay registered, the Dock may show a blank icon.
shopt -s nullglob
for copy in ~/Library/Developer/Xcode/DerivedData/SlideshowApp-*/Build/Products/*/Slate.app "$APP"; do
    "$LSREGISTER" -u "$copy" 2>/dev/null || true
done
"$LSREGISTER" -f "$DEST"

echo "==> Launching"
open "$DEST"
killall Dock 2>/dev/null || true
echo "Done: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DEST/Contents/Info.plist")) installed."
