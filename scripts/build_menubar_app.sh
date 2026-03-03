#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$ROOT_DIR/macos/SplitrouteMenuBar"
BUILD_DIR="$ROOT_DIR/build"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

APP_NAME="SplitrouteMenuBar"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
CACHE_DIR="$BUILD_DIR/.swift-module-cache"

SOURCE_VERSION="$("$PLIST_BUDDY" -c "Print :CFBundleShortVersionString" "$SRC_DIR/Info.plist" 2>/dev/null || echo "0.1.0")"
TAG_VERSION=""
if command -v git >/dev/null 2>&1; then
  TAG="$(git -C "$ROOT_DIR" describe --tags --exact-match 2>/dev/null || true)"
  if [[ "$TAG" =~ ^v([0-9]+(\.[0-9]+){1,2})$ ]]; then
    TAG_VERSION="${BASH_REMATCH[1]}"
  fi
fi

APP_VERSION="${APP_VERSION:-${TAG_VERSION:-$SOURCE_VERSION}}"
APP_BUILD="${APP_BUILD:-$(date +%Y%m%d%H%M%S)}"

if [[ ! "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "Error: invalid APP_VERSION '$APP_VERSION' (expected x.y or x.y.z)." >&2
  exit 1
fi

if [[ ! "$APP_BUILD" =~ ^[0-9]+$ ]]; then
  echo "Error: invalid APP_BUILD '$APP_BUILD' (expected numeric build number)." >&2
  exit 1
fi

set_plist_value() {
  local plist="$1"
  local key="$2"
  local value="$3"
  if ! "$PLIST_BUDDY" -c "Set :$key $value" "$plist" >/dev/null 2>&1; then
    "$PLIST_BUDDY" -c "Add :$key string $value" "$plist"
  fi
}

mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
mkdir -p "$CACHE_DIR"

if ! command -v xcrun >/dev/null 2>&1; then
  echo "Error: xcrun not found. Install Xcode Command Line Tools:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

if [ ! -x "$PLIST_BUDDY" ]; then
  echo "Error: PlistBuddy not found at $PLIST_BUDDY" >&2
  exit 1
fi

echo "Building ${APP_NAME}..."

xcrun --sdk macosx swiftc \
  -module-cache-path "$CACHE_DIR" \
  -parse-as-library \
  -O \
  -framework Cocoa \
  -framework Network \
  -framework UserNotifications \
  "$SRC_DIR/SplitrouteMenuBar.swift" \
  -o "$MACOS_DIR/$APP_NAME"

cp "$SRC_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$SRC_DIR/SplitrouteMenuBar.icns" "$RESOURCES_DIR/SplitrouteMenuBar.icns"
set_plist_value "$CONTENTS_DIR/Info.plist" "CFBundleShortVersionString" "$APP_VERSION"
set_plist_value "$CONTENTS_DIR/Info.plist" "CFBundleVersion" "$APP_BUILD"

# Ad-hoc sign to reduce Gatekeeper friction for local builds (best-effort).
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "Built: $APP_DIR"
echo "Version: $APP_VERSION ($APP_BUILD)"
echo "Run:   open \"$APP_DIR\""
