#!/bin/bash
# Replays a track on one simulator, and starts or clears it when a request file appears in a folder.
# usage: sim_location.sh <udid> <folder> [seconds to keep running]
set -u
UDID="$1"
DIR="$2"
END=$(( $(date +%s) + ${3:-900} ))
while [ "$(date +%s)" -lt "$END" ]; do
  if [ -e "$DIR/request-gps-start" ]; then
    # Eastbound from DFW at 100 m/s, so track-up turns the chart a quarter turn.
    xcrun simctl location "$UDID" clear
    xcrun simctl location "$UDID" start --speed=100 --interval=1 \
      32.8968,-97.0380 32.8968,-96.40 33.30,-96.40
    rm -f "$DIR/request-gps-start"
  fi
  if [ -e "$DIR/request-gps-fixed" ]; then
    # Parked at DFW: one position that never changes.
    xcrun simctl location "$UDID" clear
    xcrun simctl location "$UDID" set 32.8968,-97.0380
    rm -f "$DIR/request-gps-fixed"
  fi
  if [ -e "$DIR/request-gps-clear" ]; then
    xcrun simctl location "$UDID" clear
    rm -f "$DIR/request-gps-clear"
  fi
  sleep 0.5
done
xcrun simctl location "$UDID" clear
