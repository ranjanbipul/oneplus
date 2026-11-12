#!/system/bin/sh
# Magisk late_start service: start the CallBridge gateway once the system is up.
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done
sleep 15
am start-foreground-service -n com.antigravity.callbridge.gateway/.BridgeService >/dev/null 2>&1
log -t CallBridge "gateway service start requested"
