#!/usr/bin/env bash
# install_auto_tether.sh
# Installs Auto Tether Watchdog to rooted Android device over ADB

set -e

DEVICE="${1:-10.47.219.28:8855}"
ADB_CMD="adb -s $DEVICE"

echo "=== Deploying Auto Tether Watchdog to $DEVICE ==="

# 1. Create target directories on device
echo "[1/5] Preparing /data/adb directories..."
$ADB_CMD shell "su -c 'mkdir -p /data/adb/tether /data/adb/service.d'"

# 2. Push core files to temporary directory then move with root
echo "[2/5] Pushing tetherctl binary and scripts..."
$ADB_CMD push tetherctl.dex /data/local/tmp/tetherctl.dex
$ADB_CMD push tetherctl.sh /data/local/tmp/tetherctl
$ADB_CMD push auto_tether_watchdog.sh /data/local/tmp/auto_tether_watchdog.sh
$ADB_CMD push auto_tether_service.sh /data/local/tmp/auto_tether.sh

$ADB_CMD shell "su -c '
    cp /data/local/tmp/tetherctl.dex /data/adb/tether/tetherctl.dex
    cp /data/local/tmp/tetherctl /data/adb/tether/tetherctl
    cp /data/local/tmp/auto_tether_watchdog.sh /data/adb/tether/auto_tether_watchdog.sh
    cp /data/local/tmp/auto_tether.sh /data/adb/service.d/auto_tether.sh
    
    chmod 644 /data/adb/tether/tetherctl.dex
    chmod 755 /data/adb/tether/tetherctl
    chmod 755 /data/adb/tether/auto_tether_watchdog.sh
    chmod 755 /data/adb/service.d/auto_tether.sh
    
    rm -f /data/local/tmp/tetherctl.dex /data/local/tmp/tetherctl /data/local/tmp/auto_tether_watchdog.sh /data/local/tmp/auto_tether.sh
'"

# 3. Kill existing instance if running
echo "[3/5] Restarting watchdog service..."
$ADB_CMD shell "su -c '
    if [ -f /data/adb/tether/watchdog.pid ]; then
        old_pid=\$(cat /data/adb/tether/watchdog.pid 2>/dev/null)
        if [ -n \"\$old_pid\" ] && [ -d \"/proc/\$old_pid\" ]; then
            kill -9 \"\$old_pid\" 2>/dev/null || true
        fi
        rm -f /data/adb/tether/watchdog.pid
    fi
'"

# 4. Start watchdog daemon
echo "[4/5] Launching watchdog daemon..."
$ADB_CMD shell "su -c 'nohup /data/adb/tether/auto_tether_watchdog.sh >/dev/null 2>&1 &'"

# 5. Verify status
sleep 2
echo "[5/5] Verification:"
$ADB_CMD shell "su -c '
    echo \"--- Watchdog Process ---\"
    ps -ef | grep -E \"auto_tether_watchdog|Main\" | grep -v grep || true
    echo \"--- Recent Logcat --- \"
    logcat -d -t 10 -s AutoTether || true
    echo \"--- Watchdog Log File --- \"
    cat /data/adb/tether/auto_tether.log 2>/dev/null | tail -n 5 || true
'"

echo "=== Deployment Complete! ==="
