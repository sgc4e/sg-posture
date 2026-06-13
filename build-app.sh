#!/bin/bash
# Builds SGPosture and assembles a signed, double-clickable .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP="SGPosture"
DISP="SG Posture"
BUNDLE="$APP.app"
BUNDLE_ID="in.c4e.sgposture"

echo "[1/5] Building (release)…"
swift build -c release

BIN=".build/release/$APP"
[ -f "$BIN" ] || { echo "ERROR: no binary at $BIN"; exit 1; }

echo "[2/5] Assembling $BUNDLE…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$BIN" "$BUNDLE/Contents/MacOS/$APP"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleDisplayName</key><string>$DISP</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMotionUsageDescription</key>
  <string>SG Posture reads AirPods head-motion to estimate your neck posture and nudge you when you slouch.</string>
</dict>
</plist>
PLIST

echo "[3/5] Ad-hoc code signing…"
codesign --force --sign - "$BUNDLE"

echo "[4/5] Built: $(pwd)/$BUNDLE"

# Install the fresh build into /Applications (skip with: INSTALL=0 bash build-app.sh)
DEST="/Applications/$BUNDLE"
if [ "${INSTALL:-1}" = "1" ]; then
  echo "[5/5] Installing to $DEST…"
  pkill -f "$BUNDLE/Contents/MacOS/$APP" 2>/dev/null || true
  rm -rf "$DEST"
  if ditto "$BUNDLE" "$DEST" 2>/dev/null; then
    xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
    open -n "$DEST" 2>/dev/null || open -n "$DEST" 2>/dev/null || true
    echo "      Installed and launched: $DEST"
  else
    echo "      WARN: no write access to /Applications. Install by hand:"
    echo "      rm -rf \"$DEST\" && ditto \"$(pwd)/$BUNDLE\" \"$DEST\" && open \"$DEST\""
  fi
else
  echo "[5/5] Skipped install (INSTALL=0). Bundle: $(pwd)/$BUNDLE"
fi
