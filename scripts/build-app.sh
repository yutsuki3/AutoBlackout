#!/bin/bash
# Assembles the .app bundle and ad-hoc signs it.
# Usage: scripts/build-app.sh            (uses the version in Resources/Info.plist)
#        VERSION=1.2.3 scripts/build-app.sh   (stamps that version into the bundle)
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
# Ship the license notices with the app, since the .app is redistributed on its own.
cp LICENSE THIRD_PARTY_NOTICES.md "$APP_BUNDLE/Contents/Resources/"
for lproj in Resources/*.lproj; do
  cp -R "$lproj" "$APP_BUNDLE/Contents/Resources/"
done

if [ -n "${VERSION:-}" ]; then
  echo "==> stamping version $VERSION"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_BUNDLE/Contents/Info.plist"
fi

echo "==> codesign with Developer ID"
# Use environment variable if set (CI), otherwise use SHA1 fingerprint to uniquely identify
if [ -n "${APPLE_DEVELOPER_ID_APPLICATION:-}" ]; then
  CODESIGN_IDENTITY="$APPLE_DEVELOPER_ID_APPLICATION"
else
  # Use SHA1 fingerprint to avoid ambiguity with multiple certificates
  CODESIGN_IDENTITY="E6D18CCFBAF9523105A61D1BBAFFBBA3B9E5C936"
fi
codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"

echo "==> done: $APP_BUNDLE"
echo ""
echo "To install it to /Applications:"
echo "  cp -R \"$APP_BUNDLE\" /Applications/"
