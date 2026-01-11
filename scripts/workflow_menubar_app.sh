#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SplitrouteMenuBar"
APP_BUILD="$ROOT_DIR/build/$APP_NAME.app"
APP_INSTALLED="/Applications/$APP_NAME.app"

run_as_user() {
  if [ -n "${SUDO_USER:-}" ]; then
    sudo -u "$SUDO_USER" "$@"
  else
    "$@"
  fi
}

# Stop the running app so new builds actually load.
run_as_user osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true

bash "$ROOT_DIR/scripts/build_menubar_app.sh"

if [ -w "/Applications" ]; then
  bash "$ROOT_DIR/scripts/install_menubar_app.sh"
else
  echo "Info: /Applications not writable. Re-run with sudo to install there."
fi

if [ -d "$APP_INSTALLED" ]; then
  run_as_user open "$APP_INSTALLED" >/dev/null 2>&1 || true
else
  run_as_user open "$APP_BUILD" >/dev/null 2>&1 || true
fi

bash "$ROOT_DIR/scripts/package_menubar_app.sh" --skip-build
