#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SplitrouteMenuBar"
BUILD_DIR="$ROOT_DIR/build"
APP_SRC="$BUILD_DIR/$APP_NAME.app"
STAGING_DIR="$BUILD_DIR/dmg"
DMG_OUT="$BUILD_DIR/$APP_NAME.dmg"

SKIP_BUILD=false
if [ "${1:-}" = "--skip-build" ]; then
  SKIP_BUILD=true
fi

if [ "$SKIP_BUILD" = false ]; then
  bash "$ROOT_DIR/scripts/build_menubar_app.sh"
fi

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_SRC" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_OUT"
if hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -ov \
  "$DMG_OUT" >/dev/null; then
  echo "Packaged: $DMG_OUT"
else
  ZIP_OUT="$BUILD_DIR/$APP_NAME.zip"
  rm -f "$ZIP_OUT"
  ditto -c -k --sequesterRsrc --keepParent "$APP_SRC" "$ZIP_OUT"
  echo "Warning: hdiutil failed; packaged zip instead."
  echo "Packaged: $ZIP_OUT"
fi
