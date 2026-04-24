#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${1:-Cam2Mac}"
INSTALL_DIR="${APP_INSTALL_DIR:-/Applications}"
APP_PATH="${INSTALL_DIR}/${APP_NAME}.app"

"$ROOT_DIR/scripts/install_cam2mac_app.sh" "$APP_NAME"

echo "Launching $APP_PATH..."
if [[ ${EUID} -eq 0 && -n "${SUDO_USER:-}" ]]; then
  sudo -u "$SUDO_USER" open "$APP_PATH"
else
  open "$APP_PATH"
fi

echo "If this is the first install, macOS may still ask you to approve the system extension."
