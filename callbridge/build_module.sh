#!/usr/bin/env bash
# Builds the gateway APK and packages it as a Magisk module zip (build/callbridge-module.zip).
# Usage: ./build_module.sh [adb-serial]   (serial is used only for the permission safety check)
set -euo pipefail
cd "$(dirname "$0")"
SERIAL="${1:-}"
ADB=(adb); [ -n "$SERIAL" ] && ADB=(adb -s "$SERIAL")
PKG=com.antigravity.callbridge.gateway
XML=magisk/system/etc/permissions/privapp-permissions-callbridge.xml

./gradlew -q :gateway:assembleRelease
APK=gateway/build/outputs/apk/release/gateway-release.apk

# Safety check: a priv-app that requests a privileged permission missing from the whitelist
# makes the system server refuse to boot. Compare manifest against the device's permission table.
AAPT2=$(ls "$HOME"/Library/Android/sdk/build-tools/*/aapt2 | sort -V | tail -1)
REQUESTED=$("$AAPT2" dump permissions "$APK" | sed -n "s/^uses-permission: name='\([^']*\)'.*/\1/p")
DEVICE_PERMS=$("${ADB[@]}" shell pm list permissions -f | tr -d '\r')
fail=0
for p in $REQUESTED; do
  level=$(awk -v p="+ permission:$p" '$0==p{f=1} f&&!d&&/protectionLevel:/{print; d=1}' <<<"$DEVICE_PERMS")
  case "$level" in
    *privileged*)
      if ! grep -q "name=\"$p\"" "$XML"; then
        echo "ERROR: privileged permission $p is not whitelisted in $XML" >&2; fail=1
      fi ;;
  esac
done
[ "$fail" = 0 ] || exit 1
echo "permission whitelist check passed"

STAGE=build/module
rm -rf "$STAGE" build/callbridge-module.zip
mkdir -p "$STAGE"
cp -R magisk/. "$STAGE/"
mkdir -p "$STAGE/system/priv-app/CallBridgeGateway"
cp "$APK" "$STAGE/system/priv-app/CallBridgeGateway/CallBridgeGateway.apk"
(cd "$STAGE" && zip -qr ../callbridge-module.zip .)
echo "built build/callbridge-module.zip"
