#!/bin/bash
# Fails when views gain raw colors, fixed font sizes, numeric layout or banned hues.
set -euo pipefail
cd "$(dirname "$0")/.."
BASELINE=${BASELINE:-7}
hits=$(grep -rnE --include='*.swift' \
  -e '(UI)?Color\((red|white|hue|rgb):' -e 'UIColor\(rgb:' \
  -e '\.font\(\.(system|custom)\(' \
  -e '\.(white|black|cyan|teal)\b' -e 'TabView' \
  -e 'cornerRadius: *[0-9]' \
  -e '(spacing: *|\.padding\((\.[a-z]+, *)?)[1-9]' \
  -e 'frame\((width|height|minWidth|minHeight): *[0-9]' \
  App Downloads Layers Live Map Nav Position Widgets \
  | grep -v '^Map/PanelGlass.swift:' | grep -v 'design-lint: allow' || true)
n=$(printf '%s' "$hits" | grep -c . || true)
if [ "$n" -gt "$BASELINE" ]; then echo "Design lint: $n hits, baseline $BASELINE"; echo "$hits"; exit 1; fi
echo "Design lint: $n hits, baseline $BASELINE"
