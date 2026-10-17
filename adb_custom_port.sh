#!/system/bin/sh
# Magisk service.d script: Restart ADB on custom port 8855
# Placed in /data/adb/service.d/ — runs during late_start service mode

MODDIR=${0%/*}

# Wait for boot to complete
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 1
done

# Small delay to ensure adbd is fully initialized
sleep 5

# Set ADB to listen on TCP port 8855
setprop service.adb.tcp.port 8855

# Restart adbd to apply the new port
stop adbd
start adbd

log -t MagiskADB "ADB restarted on port 8855"
