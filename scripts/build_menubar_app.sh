#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$ROOT_DIR/macos/SplitrouteMenuBar"
BUILD_DIR="$ROOT_DIR/build"

APP_NAME="SplitrouteMenuBar"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
CACHE_DIR="$BUILD_DIR/.swift-module-cache"

mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
mkdir -p "$CACHE_DIR"

if ! command -v xcrun >/dev/null 2>&1; then
  echo "Error: xcrun not found. Install Xcode Command Line Tools:" >&2
  echo "  xcode-select --install" >&2
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

# Ad-hoc sign to reduce Gatekeeper friction for local builds (best-effort).
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "Built: $APP_DIR"
echo "Run:   open \"$APP_DIR\""
