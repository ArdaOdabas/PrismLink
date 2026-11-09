#!/bin/bash
# Builds PrismLink.app and PrismLink.dmg. Compiles outside iCloud, because the
# extended attributes iCloud adds make codesign fail.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${PRISMLINK_BUILD_DIR:-${TMPDIR:-/tmp}PrismLink-build}"
APP="$BUILD/PrismLink.app"
STAGE="$BUILD/dmg"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$STAGE" "$ROOT/dist"

swiftc -O -target arm64-apple-macos13.0 \
  -framework AppKit -framework ApplicationServices -framework ServiceManagement \
  -o "$APP/Contents/MacOS/PrismLink" "$ROOT/Sources/main.swift"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

ICONSET="$BUILD/AppIcon.iconset"
mkdir -p "$ICONSET" "$APP/Contents/Resources"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"

# A stable identity keeps the Accessibility grant valid across rebuilds.
# Public releases set PRISMLINK_SIGN_IDENTITY=- because a developer certificate
# embeds its owner's name and email in the signature.
IDENTITY="${PRISMLINK_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk 'NR==1 && /[0-9A-F]{40}/ {print $2}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/Resources/INSTALL.txt" "$STAGE/READ ME FIRST.txt"
rm -f "$ROOT/dist/PrismLink.dmg"
hdiutil create -quiet -volname PrismLink -srcfolder "$STAGE" -format UDZO "$ROOT/dist/PrismLink.dmg"

echo "app: $APP"
echo "dmg: $ROOT/dist/PrismLink.dmg"
