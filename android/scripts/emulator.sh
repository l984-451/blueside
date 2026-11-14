#!/bin/bash
# Runs the headless test emulator. Usage: emulator.sh start|wait|stop|launch [extras...]|shot <file>
set -euo pipefail
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
NAME=blueside-android
IMAGE="system-images;android-35;default;arm64-v8a"
PORT=5584
ADB="$SDK/platform-tools/adb -s emulator-$PORT"
AVDMANAGER="$SDK/cmdline-tools/latest/bin/avdmanager"
LOG="${EMULATOR_LOG:-${TMPDIR:-/tmp}/$NAME.log}"

case "${1:-}" in
  start)
    if [ ! -d "$HOME/.android/avd/$NAME.avd" ]; then
      echo no | "$AVDMANAGER" create avd -n "$NAME" -k "$IMAGE" -d pixel_6
    fi
    nohup "$SDK/emulator/emulator" -avd "$NAME" -port "$PORT" -no-window -no-audio -no-boot-anim \
      -no-snapshot -cores 4 -memory 3072 -gpu swiftshader_indirect < /dev/null > "$LOG" 2>&1 &
    echo "started, log at $LOG"
    ;;
  wait)
    # Polls for up to 100 seconds; run it again if it prints "not yet".
    for _ in $(seq 1 50); do
      if [ "$($ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then
        echo booted
        exit 0
      fi
      sleep 2
    done
    echo "not yet"
    exit 1
    ;;
  stop)
    # Safe to repeat and safe mid-boot: asks politely, then kills after 30 seconds.
    if pgrep -f -- "-avd $NAME( |$)" > /dev/null; then
      $ADB emu kill > /dev/null 2>&1 &
      for _ in $(seq 1 15); do
        pgrep -f -- "-avd $NAME( |$)" > /dev/null || break
        sleep 2
      done
      pkill -9 -f -- "-avd $NAME( |$)" || true
    fi
    if [ -d "$HOME/.android/avd/$NAME.avd" ]; then
      "$AVDMANAGER" delete avd -n "$NAME"
    fi
    echo stopped
    ;;
  launch)
    shift
    $ADB shell am start -W -n com.gstudios.blueside/.MainActivity "$@"
    ;;
  shot)
    $ADB exec-out screencap -p > "${2:?usage: $0 shot <file>}"
    ;;
  *)
    echo "usage: $0 start|wait|stop|launch [extras...]|shot <file>" >&2
    exit 2
    ;;
esac
