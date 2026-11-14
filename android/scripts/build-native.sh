#!/bin/bash
# Builds the Swift library for Android arm64 and copies it, with the runtime libraries it links, into the app.
# STATIC=1 links the Swift runtime into the one library instead.
set -euo pipefail
cd "$(dirname "$0")/.."
SWIFT="$HOME/.swiftly/bin/swift"
SDK=swift-6.4.0-RELEASE_android
BUNDLE="$HOME/Library/org.swift.swiftpm/swift-sdks/$SDK.artifactbundle/swift-android"
RUNTIME="$BUNDLE/swift-resources/usr/lib/swift-aarch64/android"
CXX="$BUNDLE/ndk-sysroot/usr/lib/aarch64-linux-android/libc++_shared.so"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$HOME/Library/Android/sdk/ndk/30.0.16248370}"
NDK="$ANDROID_NDK_HOME"
READELF="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-readelf"
OUT=app/src/main/jniLibs/arm64-v8a

SCRATCH=swift/.build/dynamic
FLAGS=""
if [ "${STATIC:-0}" = 1 ]; then
  SCRATCH=swift/.build/static
  FLAGS="--build-system native -Xswiftc -static-stdlib -Xswiftc -resource-dir -Xswiftc $BUNDLE/swift-resources/usr/lib/swift_static-aarch64"
fi

"$SWIFT" build --package-path swift --scratch-path "$SCRATCH" -c release --product BluesideJNI \
  --swift-sdk "$SDK" --triple aarch64-unknown-linux-android23 $FLAGS

LIB="$(find "$SCRATCH" -name libBluesideJNI.so -type f -print -quit)"
[ -n "$LIB" ] || { echo "libBluesideJNI.so was not produced" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"
cp "$LIB" "$OUT/"

# Copies every library the given one links against, then theirs. Stops on a name it cannot place.
copy_needed() {
  local name built
  for name in $("$READELF" -d "$1" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
    [ -e "$OUT/$name" ] && continue
    case "$name" in libc.so | libm.so | libdl.so | liblog.so | libandroid.so) continue ;; esac
    built="$(find "$SCRATCH" -name "$name" -type f -print -quit)"
    if [ -e "$RUNTIME/$name" ]; then
      cp "$RUNTIME/$name" "$OUT/$name"
    elif [ "$name" = "libc++_shared.so" ]; then
      cp "$CXX" "$OUT/$name"
    elif [ -n "$built" ]; then
      cp "$built" "$OUT/$name"
    else
      echo "no source for $name, needed by $1" >&2
      exit 1
    fi
    copy_needed "$OUT/$name"
  done
}
copy_needed "$OUT/libBluesideJNI.so"

ls -l "$OUT"
du -sh "$OUT"
