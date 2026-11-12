#!/bin/bash
# Builds the CallBridge iPhone app and installs it on a paired iPhone.
#   ./build_ios_app.sh                    build only (signed for development)
#   ./build_ios_app.sh --install          build, install on the first paired iPhone and launch it
#   KEY=PAIRINGKEY ./build_ios_app.sh --install
#                                         also hand the app the gateway's pairing key
# Signing uses the team in ios/CallBridge.xcodeproj (automatic signing; Xcode must be signed
# in to that Apple account). Set DEVICE=<CoreDevice id or name> to pick an iPhone.
set -euo pipefail
cd "$(dirname "$0")"

xcodebuild -project ios/CallBridge.xcodeproj -scheme CallBridge -configuration Debug \
    -destination generic/platform=iOS -derivedDataPath build/ios-dd -allowProvisioningUpdates \
    -quiet build
APP="$(pwd)/build/ios-dd/Build/Products/Debug-iphoneos/CallBridge.app"
echo "Built $APP"

[[ "${1:-}" == "--install" ]] || exit 0
DEVICE="${DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /available/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F-]{36}$/) {print $i; exit}}')}"
[[ -n "$DEVICE" ]] || { echo "No paired iPhone found (xcrun devicectl list devices)"; exit 1; }
xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null
echo "Installed on $DEVICE"
ARGS=()
[[ -n "${KEY:-}" ]] && ARGS+=(-key "$KEY")
[[ -n "${HOST:-}" ]] && ARGS+=(-host "$HOST")
if xcrun devicectl device process launch --terminate-existing --device "$DEVICE" com.imbine.callbridge.ios "${ARGS[@]+"${ARGS[@]}"}" >/dev/null 2>&1; then
    echo "Launched"
else
    echo "Could not launch it (is the iPhone locked?). Unlock it and run this again to pass KEY/HOST, or open CallBridge yourself."
fi
