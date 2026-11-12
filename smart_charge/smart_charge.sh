#!/system/bin/sh
# smart_charge.sh - Intelligent Battery Hysteresis Controller
# Protects battery health for 24/7 plugged-in Android devices
# Cycle between CHARGE_START_PERCENT and CHARGE_STOP_PERCENT

DIR="/data/adb/smart_charge"
CONF="$DIR/smart_charge.conf"
LOG_FILE="$DIR/smart_charge.log"
PID_FILE="$DIR/smart_charge.pid"

NODE_SUSPEND="/sys/class/power_supply/battery/input_suspend"
NODE_CAPACITY="/sys/class/power_supply/battery/capacity"
NODE_USB_ONLINE="/sys/class/power_supply/usb/online"
NODE_TEMP="/sys/class/power_supply/battery/temp"

# Defaults if config not found
CHARGE_START_PERCENT=50
CHARGE_STOP_PERCENT=85
CHECK_INTERVAL_SECS=15
SAFETY_MIN_PERCENT=25

load_config() {
    if [ -f "$CONF" ]; then
        . "$CONF"
    fi
}

log_msg() {
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    log -t SmartCharge "$1"
    if [ -d "$DIR" ]; then
        echo "$msg" >> "$LOG_FILE"
        # Keep log trimmed to 500 lines
        if [ $(wc -l < "$LOG_FILE" 2>/dev/null || echo 0) -gt 600 ]; then
            tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
        fi
    fi
}

cleanup() {
    log_msg "SmartCharge daemon stopping: ensuring charging is RE-ENABLED (suspend=0)"
    if [ -w "$NODE_SUSPEND" ]; then
        echo 0 > "$NODE_SUSPEND"
    fi
    rm -f "$PID_FILE"
    exit 0
}

trap cleanup INT TERM

# Ensure single instance
if [ -f "$PID_FILE" ]; then
    old_pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$old_pid" ] && [ -d "/proc/$old_pid" ] && [ "$old_pid" != "$$" ]; then
        echo "SmartCharge is already running (PID $old_pid)."
        exit 0
    fi
fi
echo $$ > "$PID_FILE"
echo -900 > "/proc/$$/oom_score_adj" 2>/dev/null || true

# Wait for boot completion
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done

load_config
log_msg "SmartCharge daemon started (PID $$) [Target: ${CHARGE_START_PERCENT}% -> ${CHARGE_STOP_PERCENT}%]"

# Ensure sysfs node exists
if [ ! -w "$NODE_SUSPEND" ]; then
    log_msg "ERROR: $NODE_SUSPEND not writable! Exiting."
    exit 1
fi

last_mode="UNKNOWN"

while true; do
    load_config

    cap=$(cat "$NODE_CAPACITY" 2>/dev/null || echo 0)
    usb=$(cat "$NODE_USB_ONLINE" 2>/dev/null || echo 0)
    suspend=$(cat "$NODE_SUSPEND" 2>/dev/null || echo 0)
    raw_temp=$(cat "$NODE_TEMP" 2>/dev/null || echo 0)
    temp_c=$(awk "BEGIN {printf \"%.1f\", $raw_temp / 10}")

    # Safety Rule 1: If battery drops below safety minimum, ALWAYS enable charging
    if [ "$cap" -le "$SAFETY_MIN_PERCENT" ] && [ "$suspend" -ne 0 ]; then
        echo 0 > "$NODE_SUSPEND"
        last_mode="SAFETY_CHARGE"
        log_msg "CRITICAL: Battery at ${cap}% (<= ${SAFETY_MIN_PERCENT}%). Forcing charging ENABLED."
        sleep "$CHECK_INTERVAL_SECS"
        continue
    fi

    # Safety Rule 2: If power cut / unplugged (usb == 0), keep suspend = 0
    # so charging begins immediately the moment grid power returns
    if [ "$usb" -eq 0 ]; then
        if [ "$suspend" -ne 0 ]; then
            echo 0 > "$NODE_SUSPEND"
            log_msg "Power cut / USB disconnected. Resetting suspend=0 so charging begins on power return."
        fi
        last_mode="ON_BATTERY"
        sleep "$CHECK_INTERVAL_SECS"
        continue
    fi

    # USB is online (charger connected & powered)
    if [ "$suspend" -eq 0 ]; then
        # Currently CHARGING
        if [ "$cap" -ge "$CHARGE_STOP_PERCENT" ]; then
            echo 1 > "$NODE_SUSPEND"
            last_mode="SUSPENDED"
            log_msg "Target reached (${cap}% >= ${CHARGE_STOP_PERCENT}%). Charging SUSPENDED. Temp: ${temp_c}°C."
        else
            if [ "$last_mode" != "CHARGING" ]; then
                log_msg "Charging in progress: currently ${cap}% (target ${CHARGE_STOP_PERCENT}%). Temp: ${temp_c}°C."
                last_mode="CHARGING"
            fi
        fi
    else
        # Currently SUSPENDED (running without charging battery)
        if [ "$cap" -le "$CHARGE_START_PERCENT" ]; then
            echo 0 > "$NODE_SUSPEND"
            last_mode="CHARGING"
            log_msg "Floor reached (${cap}% <= ${CHARGE_START_PERCENT}%). Charging RE-ENABLED up to ${CHARGE_STOP_PERCENT}%. Temp: ${temp_c}°C."
        else
            if [ "$last_mode" != "SUSPENDED" ]; then
                log_msg "Charging suspended: currently ${cap}% (will resume at <= ${CHARGE_START_PERCENT}%). Temp: ${temp_c}°C."
                last_mode="SUSPENDED"
            fi
        fi
    fi

    sleep "$CHECK_INTERVAL_SECS"
done
