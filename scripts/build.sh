#!/bin/zsh
# Builds "PeriPage Bridge.app" (universal arm64 + x86_64) into ./build.
#
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)"   code-signing identity
#                                                             (default "-" = ad-hoc, local use only)
#   BUNDLE_DRIVER=1   also bundle the official PeriPage driver inside the app for
#                     offline installs (it's otherwise downloaded at setup time).
#                     The driver is proprietary to Xiamen iLeadtek: don't redistribute it.
set -e
cd "$(dirname "$0")/.."
SIGN_ID=${SIGN_ID:--}
APP="build/PeriPage Bridge.app"
DRIVER_URL="https://cdn.ileadtek.com/resource/www/drive/cn/p81/Mac_P81_PC_Driver_V1.2.1.66.zip"

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

for arch in arm64 x86_64; do
  swiftc -O -target $arch-apple-macos13 Sources/*.swift -o build/PeriPageBridge-$arch
done
lipo -create build/PeriPageBridge-arm64 build/PeriPageBridge-x86_64 -output "$APP/Contents/MacOS/PeriPageBridge"
rm build/PeriPageBridge-*

if [[ "$BUNDLE_DRIVER" == 1 ]]; then
  tmp=$(mktemp -d)
  curl -fsSL "$DRIVER_URL" -o "$tmp/driver.zip"
  ditto -x -k "$tmp/driver.zip" "$tmp/x"
  pkg=$(find "$tmp/x" -name '*.pkg' | head -1)
  pkgutil --check-signature "$pkg" | grep -q "(DHXV3VSRNJ)" || { echo "driver signature mismatch"; exit 1; }
  cp "$pkg" "$APP/Contents/Resources/PeriPage-P81-Driver.pkg"
  rm -rf "$tmp"
fi

if [[ "$SIGN_ID" == "-" ]]; then
  codesign --force -s - "$APP"
else
  codesign --force --options runtime --timestamp -s "$SIGN_ID" "$APP"
fi
codesign --verify --strict "$APP"
echo "built $APP"
