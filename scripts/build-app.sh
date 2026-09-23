#!/bin/bash
# Assembles the .app bundle and ad-hoc signs it.
# Usage: scripts/build-app.sh
# Output: .build/release/AutoBlackout.app
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="AutoBlackout"
BUILD_DIR=".build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "==> swift build -c release"
swift build -c release

echo "==> assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> done: $APP_BUNDLE"
echo ""
echo "To install it to /Applications:"
echo "  cp -R \"$APP_BUNDLE\" /Applications/"
