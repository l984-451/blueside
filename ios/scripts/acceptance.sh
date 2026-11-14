#!/bin/bash
# Runs the acceptance UI tests on one simulator, with the pack server and the track replay beside them.
# usage: acceptance.sh <simulator name> <device type> [extra xcodebuild arguments]
set -euo pipefail
cd "$(dirname "$0")/.."

SIM_NAME="$1"
DEVICE_TYPE="$2"
shift 2
PACKS="${BLUESIDE_ACCEPTANCE_PACKS:-$HOME/.cache/blueside/acceptance}"
OUT="${BLUESIDE_BUILD_DIR:-$PWD/.build-xcode}"
PYTHON="${BLUESIDE_PYTHON:-/opt/homebrew/bin/python3.14}"
PORT=8765
mkdir -p "$OUT/shots"

UDID="$(xcrun simctl list devices available | grep -F " $SIM_NAME (" \
  | grep -o -E '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' | head -1 || true)"
if [ -z "$UDID" ]; then
  UDID="$(xcrun simctl create "$SIM_NAME" "$DEVICE_TYPE" com.apple.CoreSimulator.SimRuntime.iOS-27-0)"
fi
xcrun simctl bootstatus "$UDID" -b > /dev/null
# Packs left by an earlier run would turn the first download into nothing to do.
xcrun simctl uninstall "$UDID" "$(awk '/APP_BUNDLE_ID:/ {print $2}' project.yml)" || true
rm -f "$OUT/shots/request-gps-start" "$OUT/shots/request-gps-fixed" "$OUT/shots/request-gps-clear"

"$PYTHON" scripts/acceptance_manifest.py "$PACKS" --prefix slow/
"$PYTHON" scripts/nav_manifest.py "$PACKS"
"$PYTHON" scripts/range_server.py "$PORT" "$PACKS" --rate 4 --log "$OUT/range.log" &
SERVER_PID=$!
bash scripts/sim_location.sh "$UDID" "$OUT/shots" 800 > "$OUT/location.log" 2>&1 &
DRIVER_PID=$!
# Both helpers stop and the simulated track is cleared however this script ends.
trap 'kill "$SERVER_PID" "$DRIVER_PID" 2> /dev/null || true; xcrun simctl location "$UDID" clear || true' EXIT
# A server that could not bind would leave the tests reading whatever already holds the port.
sleep 1
kill -0 "$SERVER_PID" 2> /dev/null || { echo "acceptance.sh: FAILED (pack server did not start; is port $PORT in use?)" >&2; exit 1; }

BLUESIDE_SIM="$SIM_NAME" TEST_RUNNER_ACCEPT_SERVER="http://127.0.0.1:$PORT" TEST_RUNNER_LOCATION_DRIVER=1 \
  bash scripts/test.sh -only-testing:BluesideUITests/AcceptanceUITests "$@"

# A test that did not run proves nothing.
if grep -E "Test Case .* skipped" "$OUT/test.log"; then
  echo "acceptance.sh: FAILED (a test was skipped)" >&2
  exit 1
fi
echo "acceptance.sh: passed on $SIM_NAME"
