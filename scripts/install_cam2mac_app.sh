#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/FrontCameraContinuation"
PROJECT_PATH="$PROJECT_DIR/FrontCameraContinuation.xcodeproj"
SCHEME="${1:-Cam2Mac}"
CONFIGURATION="${CONFIGURATION:-Debug}"
INSTALL_DIR="${APP_INSTALL_DIR:-/Applications}"
DESTINATION_APP="${INSTALL_DIR}/${SCHEME}.app"
DESTINATION_EXECUTABLE="${DESTINATION_APP}/Contents/MacOS/${SCHEME}"

if [[ ${EUID} -eq 0 && -n "${SUDO_USER:-}" ]]; then
  BUILD_USER="$SUDO_USER"
  BUILD_HOME="$(dscl . -read "/Users/${BUILD_USER}" NFSHomeDirectory | awk '{print $2}')"
  BUILD_PREFIX=(sudo -u "$BUILD_USER" env HOME="$BUILD_HOME")
else
  BUILD_USER="$(id -un)"
  BUILD_HOME="$HOME"
  BUILD_PREFIX=()
fi

echo "Building scheme '$SCHEME' ($CONFIGURATION)..."
"${BUILD_PREFIX[@]}" xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  build \
  >/tmp/${SCHEME}-install-build.log

APP_PATH="$(
  find "$BUILD_HOME/Library/Developer/Xcode/DerivedData" \
    -path "*/Build/Products/${CONFIGURATION}/${SCHEME}.app" \
    -not -path "*/Index.noindex/*" \
    -not -path "*/Intermediates.noindex/*" \
    -exec stat -f '%m %N' {} + 2>/dev/null \
    | sort -n \
    | tail -1 \
    | cut -d' ' -f2-
)"

if [[ -z "$APP_PATH" ]]; then
  echo "Could not find built app for scheme '$SCHEME'."
  echo "Build log: /tmp/${SCHEME}-install-build.log"
  exit 1
fi

echo "Copying $APP_PATH to $DESTINATION_APP..."
mkdir -p "$INSTALL_DIR"
rm -rf "$DESTINATION_APP"
ditto "$APP_PATH" "$DESTINATION_APP"

if [[ ! -f "$DESTINATION_APP/Contents/Info.plist" || ! -x "$DESTINATION_EXECUTABLE" ]]; then
  echo "Installed app bundle is incomplete at $DESTINATION_APP"
  echo "Expected executable: $DESTINATION_EXECUTABLE"
  echo "If you are installing into /Applications, rerun with sudo:"
  echo "  sudo $0 $SCHEME"
  exit 1
fi

echo "Installed $SCHEME to $DESTINATION_APP"
