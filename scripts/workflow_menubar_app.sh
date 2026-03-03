#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SplitrouteMenuBar"
APP_INSTALLED="/Applications/$APP_NAME.app"
APP_BINARY="$APP_INSTALLED/Contents/MacOS/$APP_NAME"

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

if [ ! -w "/Applications" ]; then
  echo "Error: /Applications is the only supported install target." >&2
  echo "Run:   sudo bash \"$ROOT_DIR/scripts/workflow_menubar_app.sh\"" >&2
  exit 1
fi

bash "$ROOT_DIR/scripts/install_menubar_app.sh"
bash "$ROOT_DIR/scripts/verify_menubar_install.sh"

run_as_user open "$APP_INSTALLED" >/dev/null 2>&1 || true

RUNNING_LINE=""
for _ in {1..10}; do
  RUNNING_LINE="$(pgrep -af "$APP_BINARY" | head -n 1 || true)"
  if [ -n "$RUNNING_LINE" ]; then
    break
  fi
  sleep 0.5
done

if [ -z "$RUNNING_LINE" ]; then
  echo "Error: app did not start from $APP_BINARY" >&2
  exit 1
fi

echo "Running: $RUNNING_LINE"

bash "$ROOT_DIR/scripts/package_menubar_app.sh" --skip-build
