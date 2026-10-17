#!/system/bin/sh
# auto_tether_watchdog.sh
# Automatically toggles between Ethernet Tethering and Wi-Fi Hotspot
# Runs as root via Magisk on OnePlus / Android 13+

TETHER_DIR="/data/adb/tether"
TETHERCTL="$TETHER_DIR/tetherctl"
LOG_FILE="$TETHER_DIR/auto_tether.log"
PID_FILE="$TETHER_DIR/watchdog.pid"
CHECK_INTERVAL=2
DEBOUNCE_THRESHOLD=2  # Number of consecutive cycles required to confirm state change (~4s)

log_msg() {
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    log -t AutoTether "$1"
    if [ -d "$TETHER_DIR" ]; then
        echo "$msg" >> "$LOG_FILE"
        # Keep log trimmed to last 500 lines
        if [ $(wc -l < "$LOG_FILE" 2>/dev/null || echo 0) -gt 600 ]; then
            tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
        fi
    fi
}

# Ensure singleton instance
if [ -f "$PID_FILE" ]; then
    old_pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$old_pid" ] && [ -d "/proc/$old_pid" ]; then
        echo "Auto tether watchdog is already running (PID $old_pid)."
        exit 0
    fi
fi
echo $$ > "$PID_FILE"

# Wait for boot completion
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done

# Wait for tethering service to be ready
while ! dumpsys tethering >/dev/null 2>&1; do
    sleep 2
done

log_msg "Auto Tether Watchdog started (PID $$)"

is_eth_tethered() {
    dumpsys tethering 2>/dev/null | grep -qE "eth[0-9]+ - TetheredState"
}

is_wifi_tethered() {
    dumpsys tethering 2>/dev/null | grep -qE "(wlan|softap|ap_br)[0-9]+ - TetheredState"
}

get_eth_carrier() {
    for dev in /sys/class/net/eth*; do
        if [ -f "$dev/carrier" ]; then
            val=$(cat "$dev/carrier" 2>/dev/null)
            if [ "$val" = "1" ]; then
                echo 1
                return 0
            fi
        fi
    done
    echo 0
}

# Initial state determination
init_carrier=$(get_eth_carrier)
if [ "$init_carrier" = "1" ]; then
    current_mode="ETHERNET"
    log_msg "Initial state: Ethernet link detected UP. Ensuring Ethernet tethering is active."
    if ! is_eth_tethered; then
        $TETHERCTL stop-wifi >/dev/null 2>&1
        sleep 1
        $TETHERCTL start-eth
    fi
else
    current_mode="WIFI"
    log_msg "Initial state: Ethernet link DOWN / router offline. Ensuring Wi-Fi hotspot is active."
    if ! is_wifi_tethered; then
        $TETHERCTL stop-eth >/dev/null 2>&1
        sleep 1
        $TETHERCTL start-wifi
    fi
fi

pending_mode=""
debounce_count=0
health_check_counter=0

while true; do
    sleep "$CHECK_INTERVAL"

    carrier=$(get_eth_carrier)
    if [ "$carrier" = "1" ]; then
        target_mode="ETHERNET"
    else
        target_mode="WIFI"
    fi

    if [ "$target_mode" != "$current_mode" ]; then
        if [ "$target_mode" = "$pending_mode" ]; then
            debounce_count=$((debounce_count + 1))
        else
            pending_mode="$target_mode"
            debounce_count=1
        fi

        if [ "$debounce_count" -ge "$DEBOUNCE_THRESHOLD" ]; then
            log_msg "State transition confirmed: switching from $current_mode to $target_mode..."

            if [ "$target_mode" = "ETHERNET" ]; then
                # Router came back online or Ethernet cable connected
                log_msg "Action: Stopping Wi-Fi hotspot and enabling Ethernet tethering..."
                $TETHERCTL stop-wifi >/dev/null 2>&1
                sleep 1
                $TETHERCTL start-eth
                current_mode="ETHERNET"
                log_msg "Success: Switched to Ethernet tethering."
            else
                # Router went offline or Ethernet cable disconnected
                log_msg "Action: Stopping Ethernet tethering and enabling Wi-Fi hotspot..."
                $TETHERCTL stop-eth >/dev/null 2>&1
                sleep 1
                $TETHERCTL start-wifi
                current_mode="WIFI"
                log_msg "Success: Switched to Wi-Fi hotspot."
            fi

            debounce_count=0
            pending_mode=""
        fi
    else
        debounce_count=0
        pending_mode=""

        # Periodic health check every 10 seconds (~5 iterations)
        health_check_counter=$((health_check_counter + 1))
        if [ "$health_check_counter" -ge 5 ]; then
            health_check_counter=0
            if [ "$current_mode" = "ETHERNET" ]; then
                if ! is_eth_tethered; then
                    log_msg "Health check: Ethernet tethering dropped unexpectedly, re-enabling..."
                    $TETHERCTL start-eth
                fi
            elif [ "$current_mode" = "WIFI" ]; then
                if ! is_wifi_tethered; then
                    log_msg "Health check: Wi-Fi hotspot dropped unexpectedly, re-enabling..."
                    $TETHERCTL start-wifi
                fi
            fi
        fi
    fi
done
