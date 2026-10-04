#!/bin/bash
# Builds Scuba.app into the build folder next to this script.
#   ./build.sh            for this Mac
#   ./build.sh --share    the same, plus a test build for someone else's Mac
#                         (Apple silicon), zipped up on your Desktop
set -euo pipefail
cd "$(dirname "$0")"

SHARE=0
[[ "${1:-}" == "--share" ]] && SHARE=1

echo "Building…"
swift build -c release
BIN=".build/release/Scuba"

APP="build/Scuba.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Scuba"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/Scuba.icns "$APP/Contents/Resources/Scuba.icns"

# Sign it so macOS can remember its permissions. With the "Scuba Local"
# certificate (dev/setup-signing.sh) the signature stays the same across
# rebuilds, so permissions are kept; without it, a plain local signature.
if security find-certificate -c "Scuba Local" >/dev/null 2>&1 &&
   codesign --force --sign "Scuba Local" "$APP" 2>/dev/null; then
    echo "Signed with Scuba Local"
else
    codesign --force --sign - "$APP"
fi

if [[ $SHARE == 0 ]]; then
    echo ""
    echo "Done: $(pwd)/$APP"
    echo "Open it with:  open \"$APP\""
    exit 0
fi

# The test build: the app and a Start Here guide, in one zip on the Desktop.
STAGE="build/Scuba Test Build"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Scuba.app"
cp "Share/Start Here.txt" "$STAGE/Start Here.txt"
OUT="$HOME/Desktop/Scuba Test Build.zip"
rm -f "$OUT"
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$OUT"
rm -rf "$STAGE"

echo ""
echo "Test build ready: $OUT"
echo "AirDrop it over. Everything she needs is in Start Here.txt inside."
