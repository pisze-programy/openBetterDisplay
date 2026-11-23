#!/bin/zsh
set -euo pipefail

# Build, sign and install openBetterDisplay.app into /Applications, then launch it.

APP_NAME="openBetterDisplay"
BUNDLE_ID="com.piszeprogramy.openbetterdisplay"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="/Applications/$APP_NAME.app"
LOG_DIR="/Library/Logs/openBetterDisplay"

# Build as the regular user so codesign can read the user's login keychain even
# if the user accidentally ran `sudo ./scripts/install.sh`.
if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
  echo "==> fixing .derived ownership and building as $SUDO_USER (so codesign can access login keychain)"
  /usr/sbin/chown -R "$SUDO_USER" "$ROOT_DIR/.derived" 2>/dev/null || true
  BUILT="$(sudo -u "$SUDO_USER" "$ROOT_DIR/scripts/build-app.sh" | /usr/bin/tail -1)"
else
  echo "==> building signed app"
  BUILT="$("$ROOT_DIR/scripts/build-app.sh" | /usr/bin/tail -1)"
fi

echo "==> stopping running instance (so the new binary is the one that starts)"
/usr/bin/pkill -x "$APP_NAME" 2>/dev/null || true

echo "==> installing to /Applications"
sudo /bin/mkdir -p "$LOG_DIR"
sudo /bin/rm -rf "$APP_BUNDLE"
sudo /usr/bin/ditto "$BUILT" "$APP_BUNDLE"
sudo /usr/sbin/chown -R root:wheel "$APP_BUNDLE" "$LOG_DIR"
/usr/bin/xattr -dr com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true

echo "==> launching"
if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
  sudo -u "$SUDO_USER" /usr/bin/open "$APP_BUNDLE"
else
  /usr/bin/open "$APP_BUNDLE"
fi

echo "Installed $APP_NAME. The menu bar icon should now be visible."
