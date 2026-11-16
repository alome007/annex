#!/bin/bash
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
APP="${ANNEX_APP_PATH:-$HOME/Desktop/Annex.app}"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

echo "==> building"
swift build -c release --package-path "$SRC"
BIN="$(swift build -c release --package-path "$SRC" --show-bin-path)/HAOSRunner"

echo "==> bundling"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES/Fonts"
cp "$BIN" "$MACOS/Annex"
cp "$SRC/AppIcon.icns" "$RES/AppIcon.icns"
# The interface typefaces. ATSApplicationFontsPath below makes macOS load them
# for this app only, so nothing is installed on the system.
cp "$SRC/Resources/Fonts/"*.ttf "$SRC/Resources/Fonts/OFL.txt" "$RES/Fonts/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Annex</string>
  <key>CFBundleDisplayName</key><string>Annex</string>
  <key>CFBundleIdentifier</key><string>casa.astrohome.haosrunner</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleExecutable</key><string>Annex</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

echo "==> signing"
codesign --force --sign - --entitlements "$SRC/haosrunner.entitlements" "$APP" 2>&1 | sed 's/^/    /'

echo "==> verifying"
codesign -d --entitlements - "$APP" 2>&1 | grep -i virtualization | sed 's/^/    /'
echo
echo "Built: $APP"
