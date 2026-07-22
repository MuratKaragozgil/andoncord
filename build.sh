#!/bin/bash
# Builds AndonCord.app.
#
# SPM cannot emit an app bundle, so the executable is assembled into one by
# hand. The hook shim ships inside the same bundle as the app: the launcher in
# ~/.andoncord/bin resolves it there, which is what lets the app be moved or
# updated without rewriting anyone's settings.json.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="AndonCord"
BUNDLE_ID="app.andoncord.mac"
VERSION="0.1.0"

cd "$ROOT"

echo "▸ Building ($CONFIG)…"
if [ "$CONFIG" = "release" ]; then
  swift build -c release --product AndonCordApp
  swift build -c release --product andon-hook
  BIN="$(swift build -c release --show-bin-path)"
else
  swift build --product AndonCordApp
  swift build --product andon-hook
  BIN="$(swift build --show-bin-path)"
fi

APP="$ROOT/build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/AndonCordApp" "$APP/Contents/MacOS/AndonCord"
cp "$BIN/andon-hook"   "$APP/Contents/MacOS/andon-hook"

# The icon is generated from the same palette as the in-app lamps, so it can
# never drift out of sync with the board it represents.
echo "▸ Rendering icon…"
ICONSET="$ROOT/build/AndonCord.iconset"
rm -rf "$ICONSET"
swift "$ROOT/Tools/make-icon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AndonCord.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>AndonCord</string>
  <key>CFBundleIconFile</key><string>AndonCord</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>

  <!-- Menu bar app: no Dock icon, no app menu. -->
  <key>LSUIElement</key><true/>

  <!-- Precise terminal jump drives iTerm2 and Terminal.app via Apple events.
       macOS shows this string in the automation consent prompt. -->
  <key>NSAppleEventsUsageDescription</key>
  <string>AndonCord uses automation to bring the terminal tab running a Claude Code session back to the front when you click it.</string>

  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature. Enough for local use; a real release needs a Developer ID
# signature plus notarisation, or Gatekeeper will refuse to open it.
echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP" 2>/dev/null

echo "▸ Built $APP"
echo
echo "  Run:      open '$APP'"
echo "  Console:  log stream --predicate 'subsystem == \"app.andoncord\"' --level debug"
