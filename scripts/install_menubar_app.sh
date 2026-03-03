#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SplitrouteMenuBar"
APP_SRC="$ROOT_DIR/build/$APP_NAME.app"
DEST_DIR="/Applications"
DEST_APP="$DEST_DIR/$APP_NAME.app"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

run_as_user() {
  if [ -n "${SUDO_USER:-}" ]; then
    sudo -u "$SUDO_USER" "$@"
  else
    "$@"
  fi
}

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

# Ensure we do not keep running an old process from a replaced bundle.
run_as_user osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
sleep 1
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

if [ -e "$DEST_APP" ]; then
  if ! rm -rf "$DEST_APP" 2>/dev/null; then
    echo "Error: cannot replace $DEST_APP (permission denied)." >&2
    echo "Run:   sudo \"$ROOT_DIR/scripts/install_menubar_app.sh\"" >&2
    exit 1
  fi
fi

ditto "$APP_SRC" "$DEST_APP"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$DEST_APP" >/dev/null 2>&1 || true
fi

INSTALLED_VERSION="$("$PLIST_BUDDY" -c "Print :CFBundleShortVersionString" "$DEST_APP/Contents/Info.plist" 2>/dev/null || echo "unknown")"
INSTALLED_BUILD="$("$PLIST_BUDDY" -c "Print :CFBundleVersion" "$DEST_APP/Contents/Info.plist" 2>/dev/null || echo "unknown")"

echo "Installed: $DEST_APP"
echo "Version: $INSTALLED_VERSION ($INSTALLED_BUILD)"
