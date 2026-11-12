#!/bin/bash
# Builds CallBridge.app (macOS companion client) into callbridge/apple/build/.
#   ./build_mac_app.sh            release build for this Mac's architecture
#   ./build_mac_app.sh --install  also copy it to /Applications
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/CallBridgeMac"
APP=build/CallBridge.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CallBridge"
VERSION="$(git log -1 --format=%cd --date=format:%Y.%m.%d 2>/dev/null || echo 1.0)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.imbine.callbridge.mac</string>
    <key>CFBundleName</key><string>CallBridge</string>
    <key>CFBundleDisplayName</key><string>CallBridge</string>
    <key>CFBundleExecutable</key><string>CallBridge</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>CallBridge sends your voice to the person you are calling through the OnePlus 8.</string>
    <key>NSLocalNetworkUsageDescription</key><string>CallBridge connects to the CallBridge gateway on the OnePlus 8 over your local network.</string>
</dict>
</plist>
PLIST

# Sign with a stable identity when there is one, so macOS remembers the microphone grant
# across rebuilds; an ad-hoc signature works too but re-asks after every build.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"
echo "Built $(pwd)/$APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/CallBridge.app
    cp -R "$APP" /Applications/
    echo "Installed /Applications/CallBridge.app"
fi
