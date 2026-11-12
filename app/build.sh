#!/usr/bin/env bash
# Builds CallRec.app (menu bar app) and a zip to share. Needs only the Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
OUT="$ROOT/build"
APP="$OUT/CallRec.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/engine"

echo "→ Compiling"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.2 \
  CallRec.swift Library.swift -o "$APP/Contents/MacOS/CallRec"

echo "→ Icon"
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift icon.swift "$OUT/icon.png" >/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s "$OUT/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$OUT/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" "$OUT/icon.png"

cp Info.plist "$APP/Contents/Info.plist"
cp "$ROOT/callrec" "$ROOT/setup.sh" "$APP/Contents/Resources/engine/"
chmod +x "$APP/Contents/Resources/engine/"*

echo "→ Signing (ad hoc)"
codesign --force --deep --sign - "$APP"

ditto -c -k --keepParent "$APP" "$OUT/CallRec.zip"
echo "✔ $APP"
echo "✔ $OUT/CallRec.zip (to share)"
