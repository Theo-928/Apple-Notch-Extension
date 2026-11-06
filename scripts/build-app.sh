#!/bin/bash
# Builds Notchling.app into ./build. Needs only the Xcode Command Line Tools.
#   ./scripts/build-app.sh            # build
#   ./scripts/build-app.sh --install  # build and copy to ~/Applications (no admin rights needed)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Notchling.app"
VERSION="1.0.0"

echo "→ Compiling (release)…"
swift build -c release --arch arm64 --arch x86_64 2>/dev/null \
  || swift build -c release   # fall back to native-only if universal build isn't available
BIN="$(swift build -c release --show-bin-path)/Notchling"
[ -f "$BIN" ] || BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Notchling"

echo "→ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Notchling"

# Optional "Now Playing from any app" helper (only used if enabled in Settings).
echo "→ Compiling MediaBridge helper…"
clang -dynamiclib -fobjc-arc -framework Foundation -arch arm64 -arch x86_64 \
  -mmacosx-version-min=13.0 -O2 Bridge/MediaBridge.m \
  -o "$APP/Contents/Resources/libMediaBridge.dylib"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Notchling</string>
  <key>CFBundleDisplayName</key><string>Notchling</string>
  <key>CFBundleIdentifier</key><string>dev.notchling.app</string>
  <key>CFBundleExecutable</key><string>Notchling</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: no developer account needed. Builds made on this Mac are
# not quarantined, so Gatekeeper lets them run.
codesign --force --deep --sign - "$APP" >/dev/null
echo "✓ Built ${APP}"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  pkill -x Notchling 2>/dev/null || true
  rm -rf "$HOME/Applications/Notchling.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "✓ Installed to ~/Applications/Notchling.app"
  open "$HOME/Applications/Notchling.app"
fi
