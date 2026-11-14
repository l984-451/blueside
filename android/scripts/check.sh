#!/bin/bash
# Bridge tests (which write the golden JSON), native build, JVM unit tests and debug APK.
set -euo pipefail
cd "$(dirname "$0")/.."
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"

"$HOME/.swiftly/bin/swift" test --package-path swift
scripts/build-native.sh
# Foundation proper drags in ICU (about 56 MB); the bridge must stay on FoundationEssentials.
! ls app/src/main/jniLibs/arm64-v8a | grep -q ICU || { echo "ICU linked into the Android build" >&2; exit 1; }
# Device tests are compiled here and run on an emulator by ui-test.sh.
./gradlew --console=plain testDebugUnitTest assembleDebug assembleDebugAndroidTest

APK=app/build/outputs/apk/debug/app-debug.apk
echo "APK $(du -h "$APK" | cut -f1), native libs $(du -sh app/src/main/jniLibs/arm64-v8a | cut -f1)"
echo "android: checks pass"
