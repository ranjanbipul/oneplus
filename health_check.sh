#!/usr/bin/env bash
# health_check.sh
# Prints a health report for the rooted OnePlus 8 over adb: boot and Magisk state, the
# auto-tether and smart-charge daemons, tethering and internet, battery and heat, the
# CallBridge gateway, crashes, and memory/storage/CPU.
#
#   ./health_check.sh               phone at the Mac's default gateway, port 8855
#   ./health_check.sh ip:port       a specific adb device
#   DEVICE=ip:port ./health_check.sh
#
# Read-only: it changes nothing on the phone except a temporary script in /data/local/tmp.
# Exit status: 0 all good, 1 warnings, 2 failures, 3 could not reach the phone.

set -uo pipefail

DEVICE="${1:-${DEVICE:-}}"
if [ -z "$DEVICE" ]; then
    # The Mac is tethered through the phone, so the phone is the default gateway.
    GW=$(route -n get default 2>/dev/null | awk '/gateway/{print $2}')
    if [ -n "$GW" ]; then
        adb connect "$GW:8855" >/dev/null 2>&1 || true
        adb -s "$GW:8855" get-state >/dev/null 2>&1 && DEVICE="$GW:8855"
    fi
fi
if [ -z "$DEVICE" ]; then
    DEVICE=$(adb devices | awk 'NR>1 && $2=="device"{print $1; exit}')
fi
if [ -z "$DEVICE" ] || ! adb -s "$DEVICE" get-state >/dev/null 2>&1; then
    echo "No adb device reachable. Pass one: $0 ip:port" >&2
    exit 3
fi
if ! adb -s "$DEVICE" shell 'su -c id' 2>/dev/null | grep -q 'uid=0'; then
    echo "Device $DEVICE is reachable but root (su) is not available." >&2
    exit 3
fi

COLOR=0
[ -t 1 ] && COLOR=1

TMP=$(mktemp -t oneplus-health.XXXXXX)
trap 'rm -f "$TMP"' EXIT

cat > "$TMP" <<'DEVICE_SCRIPT'
#!/system/bin/sh
# Runs on the phone as root. $1 = 1 for coloured output.

if [ "$1" = "1" ]; then
    G='\033[32m'; Y='\033[33m'; R='\033[31m'; B='\033[1m'; D='\033[2m'; N='\033[0m'
else
    G=''; Y=''; R=''; B=''; D=''; N=''
fi
WARNS=0; FAILS=0
section() { printf "\n${B}== %s ==${N}\n" "$1"; }
ok()   { printf "  ${G}[ OK ]${N} %s\n" "$1"; }
warn() { printf "  ${Y}[WARN]${N} %s\n" "$1"; WARNS=$((WARNS + 1)); }
fail() { printf "  ${R}[FAIL]${N} %s\n" "$1"; FAILS=$((FAILS + 1)); }
info() { printf "         %s\n" "$1"; }
dim()  { while IFS= read -r l; do printf "         ${D}%s${N}\n" "$l"; done; }
rd()   { cat "$1" 2>/dev/null || echo "${2:-}"; }
alive() { [ -n "$1" ] && [ -d "/proc/$1" ]; }

# ---------------------------------------------------------------- device and boot
section "Device and boot"
info "$(getprop ro.product.model) / Android $(getprop ro.build.version.release) / $(getprop ro.build.display.id)"
info "Phone time: $(date '+%Y-%m-%d %H:%M:%S %Z')"
UP=$(cut -d. -f1 /proc/uptime)
info "Uptime: $((UP / 86400))d $((UP % 86400 / 3600))h $((UP % 3600 / 60))m"
[ "$(getprop sys.boot_completed)" = "1" ] && ok "Boot completed" || fail "Boot not completed"
[ "$UP" -lt 300 ] && warn "Booted less than 5 minutes ago; services may still be starting"
info "Recent boots (newest first):"
getprop persist.sys.boot.reason.history | head -4 | while IFS=, read -r a b c; do
    ts="$c"; why="$a,$b"
    case "$b" in ''|*[!0-9]*) ;; *) ts="$b"; why="$a" ;; esac
    when=$(date -d "@$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "?")
    echo "$when  ${why%,}"
done | dim

# ---------------------------------------------------------------- magisk
section "Magisk"
MV=$(magisk -v 2>/dev/null)
[ -n "$MV" ] && ok "Magisk $MV" || fail "magisk binary not found"
for m in /data/adb/modules/*; do
    [ -d "$m" ] || continue
    n=$(basename "$m")
    if [ -f "$m/remove" ]; then warn "Module $n is marked for removal"
    elif [ -f "$m/disable" ]; then
        # A volume-key power-on can trip Magisk safe mode, which disables every module.
        if [ "$n" = "callbridge" ]; then fail "Module $n is DISABLED (CallBridge loses call audio)"
        else warn "Module $n is disabled"; fi
    else ok "Module $n enabled"; fi
done
[ -d /data/adb/modules_update ] && [ -n "$(ls /data/adb/modules_update 2>/dev/null)" ] &&
    warn "Module update staged, takes effect on next reboot: $(ls /data/adb/modules_update | tr '\n' ' ')"
Z=$(magisk --sqlite "select value from settings where key='zygisk'" 2>/dev/null)
info "Zygisk: ${Z#value=}"
info "Boot scripts: $(ls /data/adb/service.d 2>/dev/null | tr '\n' ' ')"

# ---------------------------------------------------------------- daemons
section "Background daemons"
check_daemon() { # name, supervisor script path, pid file
    if pgrep -f "$2" >/dev/null 2>&1; then ok "$1 supervisor running"
    else fail "$1 supervisor not running ($2)"; fi
    p=$(rd "$3")
    if alive "$p"; then ok "$1 daemon running (PID $p)"
    else fail "$1 daemon not running (pid file: ${p:-missing})"; fi
}
check_daemon "Auto-tether" /data/adb/service.d/auto_tether.sh /data/adb/tether/watchdog.pid
check_daemon "Smart-charge" /data/adb/service.d/smart_charge.sh /data/adb/smart_charge/smart_charge.pid
info "adb over network: port $(getprop service.adb.tcp.port)"

# ---------------------------------------------------------------- network
section "Tethering and internet"
TS=$(dumpsys tethering 2>/dev/null)
ETH_T=$(echo "$TS" | grep -cE "eth[0-9]+ - TetheredState")
WIFI_T=$(echo "$TS" | grep -cE "(wlan|softap|ap_br)[a-z_0-9]* - TetheredState")
CARRIER=0
for d in /sys/class/net/eth*; do [ "$(rd "$d/carrier" 0)" = "1" ] && CARRIER=1; done
if [ "$CARRIER" = "1" ]; then
    info "Ethernet link: UP"
    [ "$ETH_T" -gt 0 ] && ok "Ethernet tethering active" || fail "Ethernet link is up but Ethernet tethering is not active"
    [ "$WIFI_T" -gt 0 ] && warn "Wi-Fi hotspot is also on (normal only briefly during a switch)"
else
    info "Ethernet link: DOWN (cable, hub or router off)"
    [ "$WIFI_T" -gt 0 ] && ok "Wi-Fi hotspot active (fallback)" || fail "Ethernet is down and the Wi-Fi hotspot is not active"
fi
echo "$TS" | grep -E " - TetheredState - lastError|Current upstream interface" | sed 's/^ *//' | dim
ip -br -4 addr 2>/dev/null | grep -E "^(eth|wlan|softap|ap_br)" | awk '$2!="DOWN"{print $1, $3}' | dim
UPSTREAM=$(echo "$TS" | sed -n 's/.*Current upstream interface(s): \[\(.*\)\].*/\1/p' | head -1)
[ -n "$UPSTREAM" ] && [ "$UPSTREAM" != "null" ] || fail "No upstream (mobile data) interface for tethering"
info "Mobile network (per SIM slot): $(getprop gsm.operator.alpha | sed 's/^,*//') / $(getprop gsm.network.type)"
RSRP=$(dumpsys telephony.registry 2>/dev/null | grep -o "rsrp=-[0-9]*" | head -1)
[ -n "$RSRP" ] && info "Signal: $RSRP dBm"
PING=$(ping -c 3 -W 2 8.8.8.8 2>/dev/null)
LOSS=$(echo "$PING" | sed -n 's/.* \([0-9]*\)% packet loss.*/\1/p')
AVG=$(echo "$PING" | sed -n 's|.*= [0-9.]*/\([0-9.]*\)/.*|\1|p')
if [ -z "$LOSS" ] || [ "$LOSS" = "100" ]; then fail "No internet: ping to 8.8.8.8 failed"
elif [ "$LOSS" != "0" ]; then warn "Internet reachable with ${LOSS}% packet loss (avg ${AVG} ms)"
else ok "Internet reachable (ping avg ${AVG} ms)"; fi
info "Last tether events:"
tail -n 4 /data/adb/tether/auto_tether.log 2>/dev/null | dim
TODAY=$(date '+%Y-%m-%d')
SW=$(grep -c "^\[$TODAY.*Carrier change confirmed" /data/adb/tether/auto_tether.log 2>/dev/null)
info "Ethernet/Wi-Fi switches today: ${SW:-0}"
[ "${SW:-0}" -gt 20 ] && warn "Many switches today; the Ethernet link may be flapping"

# ---------------------------------------------------------------- battery
section "Battery and charging"
PS=/sys/class/power_supply
MMI_NODE=/sys/class/oplus_chg/battery/mmi_charging_enable
CAP=$(rd $PS/battery/capacity 0); ST=$(rd $PS/battery/status "?")
CUR=$(rd $PS/battery/current_now 0); VOLT=$(rd $PS/battery/voltage_now 0)
BT=$(rd $PS/battery/temp 0); USB=$(rd $PS/usb/online 0)
MMI=$(rd $MMI_NODE "?"); SUSP=$(rd $PS/battery/input_suspend 0)
START=50; STOP=85; MIN=25
[ -f /data/adb/smart_charge/smart_charge.conf ] && . /data/adb/smart_charge/smart_charge.conf &&
    START=$CHARGE_START_PERCENT STOP=$CHARGE_STOP_PERCENT MIN=$SAFETY_MIN_PERCENT
info "Level ${CAP}%  |  ${ST}  |  ${CUR} mA (negative = charging)  |  $(awk "BEGIN{printf \"%.3f\", $VOLT/1000000}") V  |  $(awk "BEGIN{printf \"%.1f\", $BT/10}") C"
info "Charger: $([ "$USB" = "1" ] && echo "connected ($(rd $PS/usb/real_type "?"))" || echo "NOT connected")  |  health $(rd $PS/battery/health "?")  |  cycles $(rd $PS/battery/cycle_count "?")"
info "Smart-charge range: resume at <= ${START}%, stop at >= ${STOP}%, safety floor ${MIN}%"
if [ "$MMI" = "0" ]; then info "Charging switch: OFF (running from the charger, battery idle)"
else info "Charging switch: ON (charging allowed)"; fi
[ "$USB" = "1" ] && ok "Charger connected" || warn "Running on battery (power cut or unplugged)"
if [ "$CAP" -le "$MIN" ]; then fail "Battery at ${CAP}% (at or below the ${MIN}% safety floor)"
elif [ "$CAP" -lt "$START" ] && [ "$USB" != "1" ]; then warn "Battery at ${CAP}% and not on the charger"
else ok "Battery level ${CAP}%"; fi
if [ "$MMI" = "0" ] && [ "$ST" = "Charging" ] && [ "$CUR" -lt -100 ]; then
    fail "Battery is charging at ${CUR} mA although charging is switched off"
elif [ "$MMI" = "0" ]; then
    ok "Cut-off holding (battery idle while switched off)"
    # With charging off the phone runs from the charger, so the level only falls in a power cut.
    [ "$CAP" -ge "$((STOP + 8))" ] &&
        warn "Level ${CAP}% is well above the ${STOP}% stop; it will only come down during a power cut"
elif [ "$USB" = "1" ] && [ "$CAP" -ge "$((STOP + 3))" ]; then
    warn "Level ${CAP}% is above the ${STOP}% stop but charging is still allowed"
fi
[ "$SUSP" = "1" ] && warn "input_suspend is 1: the USB input is cut (old method; can drop the Ethernet hub)"
if [ "$BT" -ge 480 ]; then fail "Battery temperature $(awk "BEGIN{printf \"%.1f\", $BT/10}") C is too high"
elif [ "$BT" -ge 430 ]; then warn "Battery temperature $(awk "BEGIN{printf \"%.1f\", $BT/10}") C is high"
else ok "Battery temperature normal"; fi
info "Last smart-charge events:"
tail -n 4 /data/adb/smart_charge/smart_charge.log 2>/dev/null | dim
grep -q "WARNING: still charging" /data/adb/smart_charge/smart_charge.log 2>/dev/null &&
    warn "Smart-charge log has 'still charging while switched off' warnings: $(grep -c 'WARNING: still charging' /data/adb/smart_charge/smart_charge.log)"

# ---------------------------------------------------------------- thermal
section "Heat"
TH=$(dumpsys thermalservice 2>/dev/null)
TSTAT=$(echo "$TH" | sed -n 's/.*Thermal Status: \([0-9]*\).*/\1/p' | head -1)
SKIN=$(echo "$TH" | grep "mName=skin" | sed -n 's/.*mValue=\([0-9.]*\).*/\1/p' | sort -n | tail -1)
case "${TSTAT:-0}" in
    0) ok "Thermal status: none (0)" ;;
    1|2) ok "Thermal status: light/moderate ($TSTAT)" ;;
    3) warn "Thermal status: severe (3); the phone may throttle" ;;
    *) fail "Thermal status: critical or worse ($TSTAT)" ;;
esac
[ -n "$SKIN" ] && info "Hottest skin sensor: ${SKIN} C"

# ---------------------------------------------------------------- callbridge
section "CallBridge gateway"
PKG=com.antigravity.callbridge.gateway
PD=$(dumpsys package $PKG 2>/dev/null)
if ! echo "$PD" | grep -q "versionName"; then
    warn "CallBridge gateway is not installed"
else
    info "Version $(echo "$PD" | sed -n 's/.*versionName=//p' | head -1), updated $(echo "$PD" | sed -n 's/.*lastUpdateTime=//p' | head -1)"
    echo "$PD" | grep -q "pkgFlags=\[ SYSTEM" && ok "Installed as a privileged system app" ||
        fail "Not a system app (Magisk module disabled?); privileged permissions are unavailable"
    for p in CALL_AUDIO_INTERCEPTION CAPTURE_AUDIO_OUTPUT CONTROL_INCALL_EXPERIENCE MODIFY_PHONE_STATE; do
        echo "$PD" | grep -q "android.permission.$p: granted=true" && ok "Permission $p granted" ||
            fail "Permission $p NOT granted"
    done
    GUID=$(echo "$PD" | sed -n 's/.*userId=\([0-9]*\).*/\1/p' | head -1)
    POL=$(magisk --sqlite "select policy from policies where uid=$GUID" 2>/dev/null)
    [ "$POL" = "policy=2" ] && ok "Root access allowed (needed to send your voice)" ||
        fail "Root access not granted to the gateway (${POL:-no policy})"
    GP=$(pidof $PKG)
    [ -n "$GP" ] && ok "Gateway process running (PID $GP)" || fail "Gateway process is not running"
    GL=/sdcard/Android/data/$PKG/files/gateway.log
    if [ -f "$GL" ]; then
        info "Last start: $(grep "gateway started" "$GL" | tail -1 | cut -c1-18)"
        info "Recent clients:"
        grep "client connected" "$GL" | tail -40 | sed 's/.*client connected: //' | awk '{$NF=""; print}' | sort | uniq -c | dim
        TO=$(tail -200 "$GL" | grep -c "Read timed out")
        [ "$TO" -gt 30 ] && warn "Clients timed out $TO times in the last 200 log lines (one client keeps reconnecting)"
        LAST=$(grep "audio session stopped" "$GL" | tail -1)
        [ -n "$LAST" ] && info "Last call: $(echo "$LAST" | cut -c1-18) $(echo "$LAST" | sed 's/.*audio session stopped:* *//')"
        TE=$(grep -c "tinyplay: Error" "$GL")
        IR=$(grep -c "injector stopped" "$GL")
        info "In this log: $TE injector underruns, $IR injector restarts"
        if grep -qE " W/CallBridge| E/CallBridge|audio session failed|ended:" "$GL"; then
            info "Most recent warnings in the log:"
            grep -E " W/CallBridge| E/CallBridge|audio session failed|ended:" "$GL" | tail -3 | cut -c1-150 | dim
        fi
    else
        warn "No gateway.log found"
    fi
fi

# ---------------------------------------------------------------- crashes
section "Crashes"
CR=$(logcat -b crash -d -v brief 2>/dev/null | sed -n 's/.*Process: \([^,]*\),.*/\1/p' | sort | uniq -c | sort -rn)
if [ -z "$CR" ]; then ok "No app crashes in the crash log since boot"
else
    TOP=$(echo "$CR" | head -1 | awk '{print $1}')
    if [ "$TOP" -ge 20 ]; then fail "Crash loop: $(echo "$CR" | head -1 | awk '{print $2 " crashed " $1 " times"}')"
    else warn "App crashes since boot:"; fi
    echo "$CR" | head -5 | dim
fi
pm list packages -d 2>/dev/null | grep -q "com.oplus.appplatform" &&
    fail "com.oplus.appplatform is disabled; com.oplus.ndsf (DSF) crash-loops without it" ||
    ok "com.oplus.appplatform enabled (DSF needs it)"
ANR=$(find /data/anr -type f -mtime -1 2>/dev/null | wc -l)
names() { sort | uniq -c | awk '{printf "%s x%s  ", $2, $1}'; }
if [ "$ANR" -gt 0 ]; then
    warn "$ANR app-not-responding report(s) in the last 24 h: $(find /data/anr -type f -mtime -1 | xargs grep -h -m1 '^Cmd line' 2>/dev/null | sed 's/Cmd line: //' | names)"
else ok "No app-not-responding reports in the last 24 h"; fi
TB=$(find /data/tombstones -type f -mtime -1 ! -name '*.pb' 2>/dev/null | wc -l)
if [ "$TB" -gt 0 ]; then
    warn "$TB native crash dump(s) in the last 24 h: $(find /data/tombstones -type f -mtime -1 ! -name '*.pb' | xargs grep -h -m1 '^Cmdline' 2>/dev/null | sed 's/Cmdline: //' | awk '{print $1}' | names)"
else ok "No native crash dumps in the last 24 h"; fi

# ---------------------------------------------------------------- system
section "Memory, storage and CPU"
MT=$(awk '/^MemTotal/{print int($2/1024)}' /proc/meminfo)
MA=$(awk '/^MemAvailable/{print int($2/1024)}' /proc/meminfo)
SWT=$(awk '/^SwapTotal/{print int($2/1024)}' /proc/meminfo)
SWF=$(awk '/^SwapFree/{print int($2/1024)}' /proc/meminfo)
info "RAM: ${MA} MB available of ${MT} MB  |  swap used $((SWT - SWF)) of ${SWT} MB"
[ "$MA" -lt 400 ] && warn "Low available memory (${MA} MB)" || ok "Memory available"
DU=$(df /data 2>/dev/null | awk 'END{gsub("%","",$5); print $5}')
DF=$(df -h /data 2>/dev/null | awk 'END{print $4 " free of " $2}')
if [ "${DU:-0}" -ge 95 ]; then fail "Storage ${DU}% full ($DF)"
elif [ "${DU:-0}" -ge 85 ]; then warn "Storage ${DU}% full ($DF)"
else ok "Storage ${DU}% used ($DF)"; fi
TOPOUT=$(top -b -n 1 -m 6 -s 9 2>/dev/null)
CPUS=$(echo "$TOPOUT" | sed -n 's/^\([0-9]*\)%cpu.*/\1/p')
IDLE=$(echo "$TOPOUT" | sed -n 's/.* \([0-9]*\)%idle.*/\1/p')
if [ -n "$CPUS" ] && [ -n "$IDLE" ]; then
    BUSY=$(( (CPUS - IDLE) * 100 / CPUS ))
    [ "$BUSY" -ge 85 ] && warn "CPU ${BUSY}% busy" || ok "CPU ${BUSY}% busy"
fi
# Load average is not a useful signal here: ~10 kernel threads sit in uninterruptible sleep.
info "Top processes by CPU:"
echo "$TOPOUT" | tail -6 | grep -v "top -b" | head -5 |
    awk '{a=$12; for (i=13; i<=NF; i++) a=a " " $i; printf "%5s%%  %s\n", $9, substr(a, 1, 70)}' | dim

# ---------------------------------------------------------------- summary
printf "\n${B}== Summary ==${N}\n"
if [ "$FAILS" -gt 0 ]; then printf "  ${R}%d failure(s)${N}, %d warning(s)\n" "$FAILS" "$WARNS"; exit 2
elif [ "$WARNS" -gt 0 ]; then printf "  ${Y}%d warning(s)${N}, no failures\n" "$WARNS"; exit 1
else printf "  ${G}All checks passed${N}\n"; exit 0; fi
DEVICE_SCRIPT

REMOTE=/data/local/tmp/oneplus_health_$$.sh
echo "OnePlus health check: $DEVICE ($(date '+%Y-%m-%d %H:%M:%S'))"
adb -s "$DEVICE" push "$TMP" "$REMOTE" >/dev/null 2>&1 || { echo "Could not copy the check script to the phone." >&2; exit 3; }
adb -s "$DEVICE" shell "su -c 'sh $REMOTE $COLOR'; rc=\$?; rm -f $REMOTE; exit \$rc"
