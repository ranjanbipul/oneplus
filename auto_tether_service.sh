#!/system/bin/sh
# Magisk late_start service: Auto Tether Watchdog
# Placed in /data/adb/service.d/ — launches the watchdog daemon on boot

# Wait for boot to complete
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done

# Ensure executable permissions
chmod 755 /data/adb/tether/tetherctl 2>/dev/null
chmod 755 /data/adb/tether/auto_tether_watchdog.sh 2>/dev/null

# Launch watchdog daemon in background
nohup /data/adb/tether/auto_tether_watchdog.sh >/dev/null 2>&1 &

log -t MagiskTether "Auto Tether Watchdog service launched"
