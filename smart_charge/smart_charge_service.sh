#!/system/bin/sh
# Magisk late_start service: SmartCharge Daemon Supervisor
# Placed in /data/adb/service.d/ — launches and supervises SmartCharge on boot

DIR="/data/adb/smart_charge"
DAEMON="$DIR/smart_charge.sh"
PID_FILE="$DIR/smart_charge.pid"

# Wait for boot to complete
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done

# Wait for hardware services to settle
sleep 10

chmod 755 "$DIR/chargectl" 2>/dev/null
chmod 755 "$DAEMON" 2>/dev/null

log -t SmartChargeBoot "SmartCharge supervisor starting..."

while true; do
    if [ -f "$PID_FILE" ]; then
        old_pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$old_pid" ] && [ -d "/proc/$old_pid" ]; then
            sleep 20
            continue
        fi
    fi

    # Not running, launch daemon
    log -t SmartChargeBoot "Starting smart_charge daemon..."
    "$DAEMON" &
    daemon_pid=$!

    sleep 1
    if [ -d "/proc/$daemon_pid" ] && [ -f "/proc/$daemon_pid/oom_score_adj" ]; then
        echo -900 > "/proc/$daemon_pid/oom_score_adj" 2>/dev/null || true
    fi

    sleep 20
done
