#!/usr/bin/env bash
# install_smart_charge.sh
# Deploys Smart Battery Controller to rooted Android device over ADB

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE="${1:-$(adb devices | grep -E '\s+device$' | head -n 1 | awk '{print $1}')}"

if [ -z "$DEVICE" ]; then
    echo "Error: No ADB device connected."
    exit 1
fi

ADB_CMD="adb -s $DEVICE"

echo "=== Deploying SmartCharge Controller to $DEVICE ==="

# 1. Create target directories on device
echo "[1/4] Preparing directories on device..."
$ADB_CMD shell "su -c 'mkdir -p /data/adb/smart_charge /data/adb/service.d'"

# 2. Push files to temporary location then install as root
echo "[2/4] Pushing scripts and configuration..."
$ADB_CMD push "$DIR/smart_charge/smart_charge.sh" /data/local/tmp/smart_charge.sh
$ADB_CMD push "$DIR/smart_charge/smart_charge.conf" /data/local/tmp/smart_charge.conf
$ADB_CMD push "$DIR/smart_charge/chargectl" /data/local/tmp/chargectl
$ADB_CMD push "$DIR/smart_charge/smart_charge_service.sh" /data/local/tmp/smart_charge_service.sh

$ADB_CMD shell "su -c '
    cp /data/local/tmp/smart_charge.sh /data/adb/smart_charge/smart_charge.sh
    # Don'\''t overwrite user config if already present
    if [ ! -f /data/adb/smart_charge/smart_charge.conf ]; then
        cp /data/local/tmp/smart_charge.conf /data/adb/smart_charge/smart_charge.conf
    fi
    cp /data/local/tmp/chargectl /data/adb/smart_charge/chargectl
    cp /data/local/tmp/smart_charge_service.sh /data/adb/service.d/smart_charge.sh

    # Symlink chargectl into /system/bin or /data/adb/modules if possible for easy typing
    chmod 755 /data/adb/smart_charge/smart_charge.sh
    chmod 644 /data/adb/smart_charge/smart_charge.conf
    chmod 755 /data/adb/smart_charge/chargectl
    chmod 755 /data/adb/service.d/smart_charge.sh

    rm -f /data/local/tmp/smart_charge.sh /data/local/tmp/smart_charge.conf /data/local/tmp/chargectl /data/local/tmp/smart_charge_service.sh
'"

# 3. Restart daemon if already running
echo "[3/4] Restarting SmartCharge daemon..."
$ADB_CMD shell "su -c '
    if [ -f /data/adb/smart_charge/smart_charge.pid ]; then
        old_pid=\$(cat /data/adb/smart_charge/smart_charge.pid 2>/dev/null)
        [ -n \"\$old_pid\" ] && kill -9 \"\$old_pid\" 2>/dev/null || true
        rm -f /data/adb/smart_charge/smart_charge.pid
    fi

    # Launch supervisor detached in background
    nohup /data/adb/service.d/smart_charge.sh </dev/null >/dev/null 2>&1 &
'"

# 4. Verify status
sleep 3
echo "[4/4] Verifying installation:"
$ADB_CMD shell "su -c '/data/adb/smart_charge/chargectl status'"

echo ""
echo "=== SmartCharge Deployment Successful! ==="
