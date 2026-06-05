#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/FrontCameraContinuation"
PROJECT_PATH="$PROJECT_DIR/FrontCameraContinuation.xcodeproj"
SCHEME="${SCHEME:-FrontCameraContinuation}"
CONFIGURATION="${CONFIGURATION:-Release}"
BUNDLE_IDENTIFIER="${APP_BUNDLE_ID:-by.sy.FrontCameraContinuation}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/.build/ios-release}"
BUILD_LOG_PATH="${BUILD_LOG_PATH:-$DERIVED_DATA_PATH/xcodebuild.log}"
JSON_OUTPUT_PATH="${JSON_OUTPUT_PATH:-$DERIVED_DATA_PATH/devicectl-list.json}"
DEVICE_QUERY="${1:-${DEVICE_IDENTIFIER:-}}"
LAUNCH_AFTER_INSTALL="${LAUNCH_AFTER_INSTALL:-1}"
ALLOW_PROVISIONING_UPDATES="${ALLOW_PROVISIONING_UPDATES:-0}"

mkdir -p "$DERIVED_DATA_PATH"

resolve_device_identifier() {
  local query="${1:-}"

  if [[ -n "$query" ]]; then
    printf '%s\n' "$query"
    return 0
  fi

  xcrun devicectl list devices --json-output "$JSON_OUTPUT_PATH" >/dev/null

  /usr/bin/python3 - "$JSON_OUTPUT_PATH" <<'PY'
import json
import sys

json_path = sys.argv[1]

with open(json_path, "r", encoding="utf-8") as fh:
    payload = json.load(fh)

candidates = []
seen = set()

def lower_joined(value):
    if isinstance(value, dict):
        return " ".join(lower_joined(v) for v in value.values())
    if isinstance(value, list):
        return " ".join(lower_joined(v) for v in value)
    return str(value).lower()

def maybe_append(node):
    if not isinstance(node, dict):
        return

    identifier = None
    for key in ("identifier", "udid", "deviceIdentifier", "serialNumber"):
        value = node.get(key)
        if isinstance(value, str) and value.strip():
            identifier = value.strip()
            break

    if not identifier:
        return

    name = None
    for key in ("name", "deviceName", "udid"):
        value = node.get(key)
        if isinstance(value, str) and value.strip():
            name = value.strip()
            break

    text = lower_joined(node)
    score = 0
    if "iphone" in text:
        score += 4
    if "ios" in text:
        score += 2
    if "connected" in text:
        score += 2
    if "available" in text or "paired" in text:
        score += 1
    if "simulator" in text:
        score -= 5
    if "macbook" in text or "imac" in text or "mac mini" in text or "mac studio" in text:
        score -= 5
    if "watch" in text or "appletv" in text or "tvos" in text or "vision" in text:
        score -= 4

    if score <= 0:
        return

    dedupe_key = (identifier, name or "")
    if dedupe_key in seen:
        return

    seen.add(dedupe_key)
    candidates.append({
        "identifier": identifier,
        "name": name or identifier,
        "score": score,
    })

def walk(node):
    if isinstance(node, dict):
        maybe_append(node)
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for item in node:
            walk(item)

walk(payload)
candidates.sort(key=lambda item: (-item["score"], item["name"].lower(), item["identifier"].lower()))

if len(candidates) == 1:
    print(candidates[0]["identifier"])
    raise SystemExit(0)

if not candidates:
    print("No connected iPhone could be inferred from devicectl output.", file=sys.stderr)
    print("Pass a device identifier or name explicitly:", file=sys.stderr)
    print("  /bin/zsh scripts/deploy_ios_release_to_iphone.sh '<device-udid-or-name>'", file=sys.stderr)
    raise SystemExit(1)

print("Multiple possible iPhone devices were found. Pass one explicitly:", file=sys.stderr)
for candidate in candidates:
    print(f"  {candidate['name']} [{candidate['identifier']}]", file=sys.stderr)
raise SystemExit(1)
PY
}

DEVICE_IDENTIFIER_RESOLVED="$(resolve_device_identifier "$DEVICE_QUERY")"

BUILD_ARGS=(
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "id=$DEVICE_IDENTIFIER_RESOLVED"
  -derivedDataPath "$DERIVED_DATA_PATH"
  build
)

if [[ "$ALLOW_PROVISIONING_UPDATES" == "1" ]]; then
  BUILD_ARGS=(-allowProvisioningUpdates "${BUILD_ARGS[@]}")
fi

echo "Building scheme '$SCHEME' ($CONFIGURATION) for iPhone..."
xcodebuild "${BUILD_ARGS[@]}" >"$BUILD_LOG_PATH"

APP_PATH="$DERIVED_DATA_PATH/Build/Products/${CONFIGURATION}-iphoneos/${SCHEME}.app"
if [[ ! -d "$APP_PATH" ]]; then
  APP_PATH="$(
    find "$DERIVED_DATA_PATH/Build/Products" \
      -path "*/${CONFIGURATION}-iphoneos/*.app" \
      -maxdepth 3 \
      -print \
      | sort \
      | head -1
  )"
fi

if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "Could not find the built iPhone app bundle."
  echo "Build log: $BUILD_LOG_PATH"
  exit 1
fi

echo "Installing '$APP_PATH' on device '$DEVICE_IDENTIFIER_RESOLVED'..."
xcrun devicectl device install app --device "$DEVICE_IDENTIFIER_RESOLVED" "$APP_PATH"

if [[ "$LAUNCH_AFTER_INSTALL" == "1" ]]; then
  echo "Launching '$BUNDLE_IDENTIFIER'..."
  xcrun devicectl device process launch --device "$DEVICE_IDENTIFIER_RESOLVED" "$BUNDLE_IDENTIFIER"
fi

echo "Deployed $SCHEME ($CONFIGURATION) to $DEVICE_IDENTIFIER_RESOLVED"
