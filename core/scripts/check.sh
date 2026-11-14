#!/bin/bash
# Runs the core tests on macOS, then compiles the core for Android.
set -euo pipefail
cd "$(dirname "$0")/.."
SWIFT="$HOME/.swiftly/bin/swift"
# Foundation comes in through Platform.swift only, so Android links FoundationEssentials without ICU.
if grep -rnE '^\s*(@_exported )?import (Foundation|FoundationInternationalization)\b' Sources --include='*.swift' \
    | grep -v '^Sources/FlightCore/Platform.swift:'; then
  echo "core: import Foundation only in Platform.swift" >&2
  exit 1
fi
"$SWIFT" test
"$SWIFT" build --swift-sdk swift-6.4.0-RELEASE_android --triple aarch64-unknown-linux-android23
echo "core: tests pass and Android build succeeds"
