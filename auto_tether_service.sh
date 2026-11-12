#!/system/bin/sh
# Magisk late_start service: Auto Tether Watchdog Supervisor
# Placed in /data/adb/service.d/ — supervises and auto-restarts the watchdog on boot

TETHER_DIR="/data/adb/tether"
WATCHDOG="$TETHER_DIR/auto_tether_watchdog.sh"
PID_FILE="$TETHER_DIR/watchdog.pid"

# Wait for boot to complete
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done

# Extra delay: let system services fully settle before starting
sleep 10

# Ensure executable permissions
chmod 755 "$TETHER_DIR/tetherctl" 2>/dev/null
chmod 755 "$WATCHDOG" 2>/dev/null

log -t MagiskTether "Auto Tether supervisor starting..."

# Supervisor loop: restart watchdog if it ever dies
while true; do
    # Check if already running via PID file
    if [ -f "$PID_FILE" ]; then
        old_pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$old_pid" ] && [ -d "/proc/$old_pid" ]; then
            # Still alive — wait and re-check
            sleep 15
            continue
        fi
    fi

    # Not running: (re)start it
    log -t MagiskTether "Starting auto_tether_watchdog (previous PID dead or missing)..."
    "$WATCHDOG" &
    echo $! > "$PID_FILE"

    # Protect the new process from OOM killer
    new_pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$new_pid" ] && [ -f "/proc/$new_pid/oom_score_adj" ]; then
        echo -950 > "/proc/$new_pid/oom_score_adj" 2>/dev/null || true
    fi

    sleep 15
done
