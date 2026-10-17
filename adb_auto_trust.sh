#!/system/bin/sh
# Magisk service.d script: Auto-trust this Mac's ADB key
# Placed in /data/adb/service.d/ — runs during late_start service mode

MODDIR=${0%/*}

# Wait for boot to complete
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 1
done

sleep 3

ADB_KEYS_FILE="/data/misc/adb/adb_keys"
MAC_KEY="QAAAAOG4OfXfdDL/vXTIygDm5bEjs92lpl2Qu6j/ILHA/dyGP4Rr5g7eL5lwi3kQlUXs2LRXhYTyNRQJIJIgaapkabrpZXiDCPkVWal3XnL1z4iSSD5ohmDp259b7qGmbvIcsas2rDdmDCXQVN2QyT6VOHfZXcg/FWGeMcUxvYihIQvmDFRSLYFON8lIWJKs5E/M4hVFYq0zfn5Od6O/Xpsf6EzOM4PUs7g8BcOhqaykuEYAnU2Fb/44An2W+Q8eKanRL3x3kKK3DRvLmzI6WZDSLOJ45Em+RT7dRrXUv+B4JjdiZQZoqhZ3mtySgL8WoCp7ZS3BCZmuDRQWkupJDbk/9lzztmTUIijTuWXCZwsW44MuLi8pM1QEHjGYKytRM/VWH+mZWU1yVOdwkfImDt2qdLa00aCftlifrR9QElQAJdg66uxNLDwomlv7yzavCIfAxgL3UI2FY+3NYv/QIlh448v3nGWC/8HXIHiDKB46cv8mdjyfcPUY/tNfRh8uJbCzyN0IRDqOzWrvVUbuBoXZrxZLa/YnV4uaCg4+yMNpvKbORAnse2bhBwqMrhT/w5ZuDSDsUC/PwKTXF7xpkcmuL+qlHjEEeIVNEBVCesW25W/6ToII0grMBPa5XKmIe2Z8mm0ZHIgO6d5ElS4jtCVn6ab+HeN2L46Q2q/fwN+42paHLlEpEwEAAQA= bipul@Bipuls-MacBook-Pro.local"

# Ensure the adb_keys file exists
if [ ! -f "$ADB_KEYS_FILE" ]; then
    touch "$ADB_KEYS_FILE"
    chmod 640 "$ADB_KEYS_FILE"
    chown system:shell "$ADB_KEYS_FILE"
fi

# Add this Mac's key if not already present
if ! grep -q "bipul@Bipuls-MacBook-Pro.local" "$ADB_KEYS_FILE" 2>/dev/null; then
    echo "$MAC_KEY" >> "$ADB_KEYS_FILE"
    chmod 640 "$ADB_KEYS_FILE"
    chown system:shell "$ADB_KEYS_FILE"
    log -t MagiskADB "Added Mac ADB key to trusted keys"
fi

# Disable ADB authorization prompt for trusted keys
setprop persist.adb.notify 0

# Restart adbd to reload keys
stop adbd
start adbd

log -t MagiskADB "ADB auto-trust configured"
