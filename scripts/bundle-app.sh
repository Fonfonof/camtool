#!/bin/sh
# Builds CamTool.app from the CamToolApp executable (Apple Silicon only).
# Usage: scripts/bundle-app.sh [output directory, default: build]
set -eu

cd "$(dirname "$0")/.."
OUT="${1:-build}"
APP="$OUT/CamTool.app"

swift build -c release --product CamToolApp
BIN="$(swift build -c release --show-bin-path)/CamToolApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CamToolApp"
# Debug symbols embed the build machine's paths (and so the user name): drop them.
strip -S -x "$APP/Contents/MacOS/CamToolApp" 2>/dev/null
cp Packaging/Info.plist "$APP/Contents/Info.plist"
cp -R Packaging/en.lproj Packaging/fr.lproj "$APP/Contents/Resources/"
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: enough to run locally. Distribution needs a Developer ID and notarization.
codesign --force --sign - --timestamp=none "$APP"

echo "$APP"
