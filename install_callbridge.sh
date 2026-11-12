#!/usr/bin/env bash
# install_callbridge.sh
# Installs the CallBridge gateway on the rooted OnePlus 8 and builds the companion APK.
#
#   ./install_callbridge.sh stage    build + stage the Magisk module (takes effect on next reboot)
#   ./install_callbridge.sh finish   after the reboot: grant permissions, start the gateway, show the pairing key
#   ./install_callbridge.sh update   push a new gateway APK without a reboot (only when the
#                                    privileged permission list has not changed)
#   ./install_callbridge.sh apns AuthKey_KEYID.p8 TEAMID
#                                    give the gateway an APNs key so it can ring iPhone clients
#                                    whose app is in the background
#
# The phone's adb address is the Mac's default gateway (it changes on every phone reboot);
# override with DEVICE=ip:port.

set -euo pipefail
cd "$(dirname "$0")"

PKG=com.antigravity.callbridge.gateway
DEVICE="${DEVICE:-$(route -n get default | awk '/gateway/{print $2}'):8855}"
ADB=(adb -s "$DEVICE")
adb connect "$DEVICE" >/dev/null 2>&1 || true

grant_and_start() {
    "${ADB[@]}" shell "su -c '
        for p in RECORD_AUDIO READ_PHONE_STATE CALL_PHONE ANSWER_PHONE_CALLS READ_CALL_LOG READ_SMS RECEIVE_SMS SEND_SMS POST_NOTIFICATIONS; do
            pm grant $PKG android.permission.\$p
        done
        cmd deviceidle whitelist +$PKG >/dev/null
        uid=\$(dumpsys package $PKG | sed -n \"s/.*userId=\\([0-9]*\\).*/\\1/p\" | head -1)
        # Let the gateway use root (for call-audio injection) without an on-screen prompt.
        magisk --sqlite \"INSERT OR REPLACE INTO policies (uid,policy,until,logging,notification) VALUES(\$uid,2,0,1,0)\" >/dev/null
        am force-stop $PKG
        am start-foreground-service -n $PKG/.BridgeService >/dev/null
        sleep 2
        echo \"--- privileged permissions ---\"
        dumpsys package $PKG | grep -E \"(CALL_AUDIO_INTERCEPTION|CONTROL_INCALL_EXPERIENCE|MODIFY_PHONE_STATE|CAPTURE_AUDIO_OUTPUT): granted\" | sort -u
        echo \"--- pairing key ---\"
        sed -n \"s/.*name=\\\"key\\\">\\(.*\\)<.*/\\1/p\" /data/data/$PKG/shared_prefs/callbridge.xml 2>/dev/null || echo \"(open the CallBridge Gateway app on the phone to see it)\"
    '"
}

case "${1:-}" in
    stage)
        ./callbridge/build_module.sh "$DEVICE"
        (cd callbridge && ./gradlew -q :client:assembleRelease)
        "${ADB[@]}" push callbridge/build/callbridge-module.zip /data/local/tmp/callbridge-module.zip
        "${ADB[@]}" shell "su -c 'magisk --install-module /data/local/tmp/callbridge-module.zip; rm -f /data/local/tmp/callbridge-module.zip'"
        echo
        echo "Staged. Reboot the phone, then run: ./install_callbridge.sh finish"
        echo "Companion APK: callbridge/client/build/outputs/apk/release/client-release.apk"
        ;;
    finish)
        # A copy side-loaded earlier with "update" would mask the module's APK and its
        # privileged permissions; drop it so the module version is the one that runs.
        "${ADB[@]}" shell "su -c 'pm uninstall-system-updates $PKG >/dev/null 2>&1'" || true
        grant_and_start
        ;;
    apns)
        KEY="${2:?usage: $0 apns AuthKey_KEYID.p8 TEAMID}"
        TEAM="${3:?usage: $0 apns AuthKey_KEYID.p8 TEAMID}"
        KEYID="${KEYID:-$(basename "$KEY" | sed -n 's/^AuthKey_\([A-Z0-9]*\)\.p8$/\1/p')}"
        [[ -n "$KEYID" ]] || { echo "Cannot read the key id from the file name; set KEYID=..."; exit 1; }
        DIR=/data/media/0/Android/data/$PKG/files/apns
        printf '{"keyId":"%s","teamId":"%s"}' "$KEYID" "$TEAM" > /tmp/callbridge-apns.json
        "${ADB[@]}" push "$KEY" /data/local/tmp/cb-key.p8 >/dev/null
        "${ADB[@]}" push /tmp/callbridge-apns.json /data/local/tmp/cb-apns.json >/dev/null
        rm -f /tmp/callbridge-apns.json
        # Same owner/group as the app's other external files, so the app can read them.
        "${ADB[@]}" shell "su -c '
            files=\$(dirname $DIR); grp=\$(stat -c %g \$files)
            mkdir -p $DIR
            mv /data/local/tmp/cb-key.p8 $DIR/key.p8
            mv /data/local/tmp/cb-apns.json $DIR/config.json
            chown -R 1023:\$grp $DIR; chmod 2770 $DIR; chmod 660 $DIR/key.p8 $DIR/config.json
            ls -ln $DIR
        '"
        echo "APNs key $KEYID (team $TEAM) installed. iPhone clients pick it up when they next connect."
        ;;
    update)
        ./callbridge/build_module.sh "$DEVICE"
        "${ADB[@]}" push callbridge/gateway/build/outputs/apk/release/gateway-release.apk /data/local/tmp/gw.apk
        "${ADB[@]}" shell "su -c 'pm install -r /data/local/tmp/gw.apk; rm -f /data/local/tmp/gw.apk'"
        grant_and_start
        ;;
    *)
        sed -n '2,12p' "$0"
        exit 1
        ;;
esac
