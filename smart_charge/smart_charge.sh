#!/system/bin/sh
# smart_charge.sh - Intelligent Battery Hysteresis Controller
# Protects battery health for 24/7 plugged-in Android devices
# Cycle between CHARGE_START_PERCENT and CHARGE_STOP_PERCENT

DIR="/data/adb/smart_charge"
CONF="$DIR/smart_charge.conf"
LOG_FILE="$DIR/smart_charge.log"
PID_FILE="$DIR/smart_charge.pid"

# Charging switch. OnePlus's own node stops battery charging while the phone keeps running
# from the charger. input_suspend is NOT used for that on this phone: it cuts the USB input,
# and the charger re-enables charging about 10 s later while the node still reads 1.
NODE_MMI="/sys/class/oplus_chg/battery/mmi_charging_enable"
NODE_SUSPEND="/sys/class/power_supply/battery/input_suspend"
NODE_STATUS="/sys/class/power_supply/battery/status"
NODE_CURRENT="/sys/class/power_supply/battery/current_now"
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

# Prints 1 when charging is switched off, 0 when it is allowed.
charging_off() {
    if [ -w "$NODE_MMI" ]; then
        [ "$(cat "$NODE_MMI" 2>/dev/null)" = "0" ] && echo 1 || echo 0
    else
        cat "$NODE_SUSPEND" 2>/dev/null || echo 0
    fi
}

# set_charging on|off
set_charging() {
    if [ -w "$NODE_MMI" ]; then
        [ "$1" = "on" ] && echo 1 > "$NODE_MMI" || echo 0 > "$NODE_MMI"
        # Never leave the USB input cut: that is a leftover of the old method.
        [ "$(cat "$NODE_SUSPEND" 2>/dev/null)" = "1" ] && echo 0 > "$NODE_SUSPEND"
    else
        [ "$1" = "on" ] && echo 0 > "$NODE_SUSPEND" || echo 1 > "$NODE_SUSPEND"
    fi
}

cleanup() {
    log_msg "SmartCharge daemon stopping: ensuring charging is RE-ENABLED"
    set_charging on
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

# Ensure a control node exists
if [ -w "$NODE_MMI" ]; then
    log_msg "Control node: $NODE_MMI"
    # Clear a USB input cut left behind by the old method.
    [ "$(cat "$NODE_SUSPEND" 2>/dev/null)" = "1" ] && echo 0 > "$NODE_SUSPEND"
elif [ -w "$NODE_SUSPEND" ]; then
    log_msg "Control node: $NODE_SUSPEND (fallback; $NODE_MMI not found)"
else
    log_msg "ERROR: no writable charging control node! Exiting."
    exit 1
fi

last_mode="UNKNOWN"
leak_count=0

while true; do
    load_config

    cap=$(cat "$NODE_CAPACITY" 2>/dev/null || echo 0)
    usb=$(cat "$NODE_USB_ONLINE" 2>/dev/null || echo 0)
    suspend=$(charging_off)
    raw_temp=$(cat "$NODE_TEMP" 2>/dev/null || echo 0)
    temp_c=$(awk "BEGIN {printf \"%.1f\", $raw_temp / 10}")

    # Safety Rule 1: If battery drops below safety minimum, ALWAYS enable charging
    if [ "$cap" -le "$SAFETY_MIN_PERCENT" ] && [ "$suspend" -ne 0 ]; then
        set_charging on
        last_mode="SAFETY_CHARGE"
        log_msg "CRITICAL: Battery at ${cap}% (<= ${SAFETY_MIN_PERCENT}%). Forcing charging ENABLED."
        sleep "$CHECK_INTERVAL_SECS"
        continue
    fi

    # Safety Rule 2: If power cut / unplugged (usb == 0), keep charging allowed
    # so charging begins immediately the moment grid power returns
    if [ "$usb" -eq 0 ]; then
        if [ "$suspend" -ne 0 ]; then
            set_charging on
            log_msg "Power cut / USB disconnected. Re-allowing charging so it begins on power return."
        fi
        last_mode="ON_BATTERY"
        sleep "$CHECK_INTERVAL_SECS"
        continue
    fi

    # USB is online (charger connected & powered)
    if [ "$suspend" -eq 0 ]; then
        # Currently CHARGING
        if [ "$cap" -ge "$CHARGE_STOP_PERCENT" ]; then
            set_charging off
            last_mode="SUSPENDED"
            leak_count=0
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
            set_charging on
            last_mode="CHARGING"
            log_msg "Floor reached (${cap}% <= ${CHARGE_START_PERCENT}%). Charging RE-ENABLED up to ${CHARGE_STOP_PERCENT}%. Temp: ${temp_c}°C."
        else
            if [ "$last_mode" != "SUSPENDED" ]; then
                log_msg "Charging suspended: currently ${cap}% (will resume at <= ${CHARGE_START_PERCENT}%). Temp: ${temp_c}°C."
                last_mode="SUSPENDED"
            fi
            # The switch says off; make sure the battery agrees. Re-assert if it keeps charging.
            cur=$(cat "$NODE_CURRENT" 2>/dev/null || echo 0)
            if [ "$(cat "$NODE_STATUS" 2>/dev/null)" = "Charging" ] && [ "$cur" -lt -100 ]; then
                leak_count=$((leak_count + 1))
                if [ "$leak_count" -ge 4 ]; then
                    log_msg "WARNING: still charging at ${cur} mA while switched off (${cap}%). Re-asserting."
                    set_charging off
                    leak_count=0
                fi
            else
                leak_count=0
            fi
        fi
    fi

    sleep "$CHECK_INTERVAL_SECS"
done
