#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SplitrouteMenuBar"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

APP_BUILD="$ROOT_DIR/build/$APP_NAME.app"
APP_INSTALLED="/Applications/$APP_NAME.app"
BUILD_PLIST="$APP_BUILD/Contents/Info.plist"
INSTALLED_PLIST="$APP_INSTALLED/Contents/Info.plist"
BUILD_BIN="$APP_BUILD/Contents/MacOS/$APP_NAME"
INSTALLED_BIN="$APP_INSTALLED/Contents/MacOS/$APP_NAME"

fail() {
  echo "Error: $1" >&2
  exit 1
}

read_plist_value() {
  local plist="$1"
  local key="$2"
  "$PLIST_BUDDY" -c "Print :$key" "$plist" 2>/dev/null
}

if [ ! -x "$PLIST_BUDDY" ]; then
  fail "PlistBuddy not found at $PLIST_BUDDY"
fi

[ -d "$APP_BUILD" ] || fail "Build app missing: $APP_BUILD"
[ -d "$APP_INSTALLED" ] || fail "Installed app missing: $APP_INSTALLED"
[ -f "$BUILD_PLIST" ] || fail "Build Info.plist missing: $BUILD_PLIST"
[ -f "$INSTALLED_PLIST" ] || fail "Installed Info.plist missing: $INSTALLED_PLIST"
[ -f "$BUILD_BIN" ] || fail "Build binary missing: $BUILD_BIN"
[ -f "$INSTALLED_BIN" ] || fail "Installed binary missing: $INSTALLED_BIN"

BUILD_VERSION="$(read_plist_value "$BUILD_PLIST" "CFBundleShortVersionString")"
BUILD_NUMBER="$(read_plist_value "$BUILD_PLIST" "CFBundleVersion")"
INSTALLED_VERSION="$(read_plist_value "$INSTALLED_PLIST" "CFBundleShortVersionString")"
INSTALLED_NUMBER="$(read_plist_value "$INSTALLED_PLIST" "CFBundleVersion")"

BUILD_SHA="$(shasum -a 256 "$BUILD_BIN" | awk '{print $1}')"
INSTALLED_SHA="$(shasum -a 256 "$INSTALLED_BIN" | awk '{print $1}')"

echo "Build:     $APP_BUILD"
echo "Installed: $APP_INSTALLED"
echo "Version:   build=$BUILD_VERSION ($BUILD_NUMBER) | installed=$INSTALLED_VERSION ($INSTALLED_NUMBER)"
echo "Binary:    build=$BUILD_SHA | installed=$INSTALLED_SHA"

if [ "$BUILD_VERSION" != "$INSTALLED_VERSION" ]; then
  fail "CFBundleShortVersionString mismatch (build=$BUILD_VERSION, installed=$INSTALLED_VERSION)"
fi

if [ "$BUILD_NUMBER" != "$INSTALLED_NUMBER" ]; then
  fail "CFBundleVersion mismatch (build=$BUILD_NUMBER, installed=$INSTALLED_NUMBER)"
fi

if [ "$BUILD_SHA" != "$INSTALLED_SHA" ]; then
  fail "Binary SHA mismatch between build and installed app"
fi

DOCK_PLIST="$HOME/Library/Preferences/com.apple.dock.plist"
if [ -f "$DOCK_PLIST" ]; then
  if plutil -convert xml1 -o - "$DOCK_PLIST" 2>/dev/null | grep -q "file:///Applications/$APP_NAME.app/"; then
    echo "Dock target: /Applications/$APP_NAME.app"
  else
    echo "Warning: Dock does not currently reference /Applications/$APP_NAME.app"
  fi
fi

echo "OK: installed app is up to date with local build."
