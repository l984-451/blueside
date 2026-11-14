#!/bin/bash
# Regenerates the Xcode project, then builds and runs every test on a dedicated simulator.
# Extra arguments go to xcodebuild, for example -only-testing:BluesideTests.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/design-lint.sh

SIM_NAME="${BLUESIDE_SIM:-blueside-main}"
OUT="${BLUESIDE_BUILD_DIR:-$PWD/.build-xcode}"
LIMIT_SECONDS="${BLUESIDE_TEST_LIMIT:-900}"
LOG="$OUT/test.log"
mkdir -p "$OUT/shots"

xcodegen generate --quiet

sim_udid() {
  xcrun simctl list devices available | grep -F " $SIM_NAME (" \
    | grep -o -E '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' | head -1 || true
}
UDID="$(sim_udid)"
if [ -z "$UDID" ]; then
  UDID="$(xcrun simctl create "$SIM_NAME" "iPad (A16)" com.apple.CoreSimulator.SimRuntime.iOS-27-0)"
fi
xcrun simctl bootstatus "$UDID" -b > /dev/null

# Diagnostics collection is off because it keeps xcodebuild alive for minutes after a failed UI test.
rm -rf "$OUT/test.xcresult"
XCODE_ARGS=(-project Blueside.xcodeproj -scheme Blueside
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$OUT/derived")
if ! xcodebuild build-for-testing "${XCODE_ARGS[@]}" "$@" > "$LOG" 2>&1; then
  grep -E 'error:' "$LOG" | sort -u | tail -40 || true
  echo "test.sh: FAILED (build). Log: $LOG" >&2
  exit 1
fi
# The location alert would cover screenshots and swallow taps, so the grant is made before any launch.
BUNDLE_ID="$(awk '/APP_BUNDLE_ID:/ {print $2}' project.yml)"
xcrun simctl install "$UDID" "$OUT/derived/Build/Products/Debug-iphonesimulator/Blueside.app"
xcrun simctl privacy "$UDID" grant location "$BUNDLE_ID"
TEST_RUNNER_SHOT_DIR="$OUT/shots" xcodebuild test-without-building "${XCODE_ARGS[@]}" \
  -resultBundlePath "$OUT/test.xcresult" \
  -parallel-testing-enabled NO -collect-test-diagnostics never -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 120 \
  "$@" >> "$LOG" 2>&1 &
BUILD_PID=$!

# Hard stop: a test host that dies on launch can leave xcodebuild waiting with nothing running.
( sleep "$LIMIT_SECONDS"; kill -9 "$BUILD_PID" ) > /dev/null 2>&1 &
WATCHDOG_PID=$!

STATUS=0
wait "$BUILD_PID" || STATUS=$?
pkill -P "$WATCHDOG_PID" > /dev/null 2>&1 || true
kill "$WATCHDOG_PID" > /dev/null 2>&1 || true

grep -E 'error:|✘|Test Case .* failed|Test run with|Executed [1-9][0-9]* tests?|\*\* TEST' "$LOG" | sort -u | tail -40 || true
if [ "$STATUS" -ne 0 ]; then
  echo "test.sh: FAILED (xcodebuild exit $STATUS; 137 means it ran past the ${LIMIT_SECONDS}s limit). Log: $LOG" >&2
  exit 1
fi
# A run that executed nothing must not count as a pass.
if ! grep -q -E 'Test run with [1-9][0-9]* tests?.* passed|Executed [1-9][0-9]* tests?, with 0 failures' "$LOG"; then
  echo "test.sh: FAILED (no test ran). Log: $LOG" >&2
  exit 1
fi
echo "test.sh: passed. Screenshots: $OUT/shots"
