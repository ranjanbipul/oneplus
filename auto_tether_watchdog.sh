#!/system/bin/sh
# auto_tether_watchdog.sh
# Automatically toggles between Ethernet Tethering and Wi-Fi Hotspot
# Runs as root via Magisk on OnePlus / Android 13+
# Implements Make-Before-Break: Wi-Fi is only disabled after Ethernet is verified working.

TETHER_DIR="/data/adb/tether"
TETHERCTL="$TETHER_DIR/tetherctl"
LOG_FILE="$TETHER_DIR/auto_tether.log"
PID_FILE="$TETHER_DIR/watchdog.pid"
CHECK_INTERVAL=2
DEBOUNCE_THRESHOLD=2  # Number of consecutive cycles to confirm carrier change (~4s)

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

has_eth_ip() {
    ip -4 addr show eth0 2>/dev/null | grep -q "inet "
}

has_eth_client() {
    ip neigh show dev eth0 2>/dev/null | grep -E -q "REACHABLE|DELAY|STALE"
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

verify_ethernet_working() {
    [ "$(get_eth_carrier)" = "1" ] && is_eth_tethered && has_eth_ip
}

# Initial state determination on boot
init_carrier=$(get_eth_carrier)
if [ "$init_carrier" = "1" ]; then
    log_msg "Initial state: Ethernet link detected UP. Ensuring Ethernet tethering is active..."
    $TETHERCTL start-eth >/dev/null 2>&1
    sleep 2
    if verify_ethernet_working; then
        current_mode="ETHERNET"
        $TETHERCTL stop-wifi >/dev/null 2>&1
        log_msg "Initial state confirmed: Ethernet tethering operational."
    else
        current_mode="WIFI"
        log_msg "Initial state: Ethernet tethering failed to verify. Fallback to Wi-Fi hotspot."
        $TETHERCTL start-wifi
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
            log_msg "Carrier change confirmed: desiring switch from $current_mode to $target_mode..."

            if [ "$target_mode" = "ETHERNET" ]; then
                # Router came back online / Ethernet link detected
                log_msg "Action: Starting Ethernet tethering while KEEPING Wi-Fi hotspot active..."
                $TETHERCTL start-eth

                # Verify Ethernet becomes active with an IP address (up to 12s)
                eth_verified=0
                for attempt in $(seq 1 12); do
                    sleep 1
                    if verify_ethernet_working; then
                        eth_verified=1
                        break
                    fi
                    if [ "$attempt" -eq 5 ]; then
                        # Retry start-eth if not yet bound
                        $TETHERCTL start-eth
                    fi
                done

                if [ "$eth_verified" = "1" ]; then
                    log_msg "Ethernet tethering is UP and has IP. Waiting for router handshake..."
                    
                    # Wait up to 8s for client/router handshake or ARP exchange
                    for g in $(seq 1 8); do
                        sleep 1
                        if has_eth_client; then
                            log_msg "Connected router/client confirmed on Ethernet (after ${g}s)."
                            break
                        fi
                    done
                    
                    # 2s final settling buffer
                    sleep 2

                    # Final check: only disable Wi-Fi if Ethernet is STILL working
                    if verify_ethernet_working; then
                        log_msg "Ethernet connection fully verified. Disabling Wi-Fi hotspot now."
                        $TETHERCTL stop-wifi >/dev/null 2>&1
                        current_mode="ETHERNET"
                        log_msg "Success: Seamless failover to Ethernet complete (zero blackout)."
                    else
                        log_msg "Warning: Ethernet link dropped during handshake. Keeping Wi-Fi hotspot ON."
                    fi
                else
                    log_msg "Warning: Ethernet failed to verify within 12s. Wi-Fi hotspot remains ON for safety."
                fi
            else
                # Router went offline, power out, or cable disconnected
                log_msg "Action: Router offline. Stopping Ethernet tethering and starting Wi-Fi hotspot..."
                $TETHERCTL stop-eth >/dev/null 2>&1
                sleep 1
                $TETHERCTL start-wifi
                sleep 1
                if ! is_wifi_tethered; then
                    sleep 2
                    $TETHERCTL start-wifi
                fi
                current_mode="WIFI"
                log_msg "Success: Wi-Fi hotspot is now active."
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
                if ! verify_ethernet_working; then
                    if [ "$(get_eth_carrier)" = "1" ]; then
                        log_msg "Health check: Ethernet tethering lost, attempting recovery..."
                        $TETHERCTL start-eth
                    else
                        log_msg "Health check: Ethernet link is down, falling back to Wi-Fi hotspot..."
                        $TETHERCTL start-wifi
                        current_mode="WIFI"
                    fi
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
