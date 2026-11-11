#!/bin/sh
# Packs build/CamTool.app into a disk image with a shortcut to /Applications.
# Usage: scripts/make-dmg.sh [output directory, default: build]   (run `make app` first, or use `make dmg`)
set -eu

cd "$(dirname "$0")/.."
OUT="${1:-build}"
APP="$OUT/CamTool.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$OUT/CamTool-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/CamTool.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -quiet -volname "CamTool $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"

echo "$DMG"
