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
ENTITLEMENTS="$SRC/haosrunner.entitlements"
IDENTITY=-
# Passing USB devices to Home Assistant needs Apple's "Claim USB Accessory"
# entitlement, which macOS honours only in an app signed with a certificate
# and a provisioning profile that grants it. Set both variables to build that
# way; without them the app is signed ad hoc and Settings has no USB section.
if [[ -n "${ANNEX_SIGN_IDENTITY:-}" || -n "${ANNEX_PROFILE:-}" ]]; then
  : "${ANNEX_SIGN_IDENTITY:?set ANNEX_PROFILE and ANNEX_SIGN_IDENTITY together}"
  : "${ANNEX_PROFILE:?set ANNEX_PROFILE and ANNEX_SIGN_IDENTITY together}"
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  security cms -D -i "$ANNEX_PROFILE" > "$WORK/profile.plist"
  granted() { /usr/libexec/PlistBuddy -c "Print :Entitlements:$1" "$WORK/profile.plist" 2>/dev/null; }
  TEAM_ID="$(granted com.apple.developer.team-identifier)"
  APP_ID="$(granted com.apple.application-identifier)"
  if [[ "$APP_ID" != "$TEAM_ID.casa.astrohome.haosrunner" ]]; then
    echo "error: $ANNEX_PROFILE is for '$APP_ID', not casa.astrohome.haosrunner" >&2
    exit 1
  fi
  if [[ "$(granted com.apple.developer.accessory-access.usb)" != "true" ]]; then
    echo "error: $ANNEX_PROFILE does not grant Claim USB Accessory; enable it on the App ID and download the profile again" >&2
    exit 1
  fi
  ENTITLEMENTS="$WORK/annex.entitlements"
  cp "$SRC/haosrunner.entitlements" "$ENTITLEMENTS"
  /usr/libexec/PlistBuddy \
    -c "Add :com.apple.application-identifier string $APP_ID" \
    -c "Add :com.apple.developer.team-identifier string $TEAM_ID" \
    -c "Add :com.apple.developer.accessory-access.usb bool true" \
    "$ENTITLEMENTS"
  cp "$ANNEX_PROFILE" "$APP/Contents/embedded.provisionprofile"
  IDENTITY="$ANNEX_SIGN_IDENTITY"
fi
codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" "$APP" 2>&1 | sed 's/^/    /'

echo "==> verifying"
codesign -d --entitlements - "$APP" 2>&1 | grep -iE "virtualization|accessory-access" | sed 's/^/    /'
echo
echo "Built: $APP"
