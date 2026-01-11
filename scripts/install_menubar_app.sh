#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SplitrouteMenuBar"
APP_SRC="$ROOT_DIR/build/$APP_NAME.app"
DEST_DIR="/Applications"
DEST_APP="$DEST_DIR/$APP_NAME.app"

if [ ! -d "$APP_SRC" ]; then
  echo "Error: build not found at $APP_SRC" >&2
  echo "Run:   bash \"$ROOT_DIR/scripts/build_menubar_app.sh\"" >&2
  exit 1
fi

if [ ! -w "$DEST_DIR" ]; then
  echo "Error: no write access to $DEST_DIR." >&2
  echo "Run:   sudo \"$ROOT_DIR/scripts/install_menubar_app.sh\"" >&2
  exit 1
fi

rm -rf "$DEST_APP"
cp -R "$APP_SRC" "$DEST_DIR/"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$DEST_APP" >/dev/null 2>&1 || true
fi

echo "Installed: $DEST_APP"
