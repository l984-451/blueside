#!/bin/bash
# Device tests on the test emulator: android/scripts/ui-test.sh [TestClass[#method]]; emulator.sh stop removes it after.
set -euo pipefail
cd "$(dirname "$0")/.."
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
# Only this emulator, never another device that happens to be attached.
export ANDROID_SERIAL=emulator-5584
pgrep -f -- "-avd blueside-android( |$)" > /dev/null || scripts/emulator.sh start
until scripts/emulator.sh wait; do :; done
ls app/src/main/jniLibs/arm64-v8a/*.so > /dev/null 2>&1 || scripts/build-native.sh
FILTER=()
[ -n "${1:-}" ] && FILTER=("-Pandroid.testInstrumentationRunnerArguments.class=com.gstudios.blueside.$1")
./gradlew --console=plain connectedDebugAndroidTest "${FILTER[@]+"${FILTER[@]}"}"
