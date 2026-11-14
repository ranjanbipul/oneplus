# Smart Battery Cycle Controller Guide
**Target Device:** Rooted OnePlus 8 (Android 13 / OxygenOS / Snapdragon 865)  
**Deployment Path:** `/data/adb/smart_charge/` & `/data/adb/service.d/smart_charge.sh`

---

## 📌 Problem & Motivation
In rural and remote regions with frequent grid power outages:
1. The phone serves as a **24/7 tethering router / hotspot**, always plugged into USB power.
2. Keeping a lithium-ion battery continuously at **100% (high voltage ~4.2V–4.35V)** while running warm (~44°C) causes rapid degradation and **dangerous battery swelling (pillowing)**.
3. However, during power cuts, the phone must maintain sufficient battery reserve so that internet connectivity doesn't die.

---

## ⚡ The Solution: Intelligent Hysteresis Cycle
Instead of continuously holding the battery at 100%, the daemon cycles between two safe thresholds:
- **Floor Threshold (Default: 50%):** When battery drains down to 50% (either slowly while suspended or after a power cut), charging is **re-enabled** (`mmi_charging_enable = 1`).
- **Ceiling Target (Default: 85%):** The battery charges up to 85% (holding ~4.1V, well below destructive overcharge voltage). Once it hits 85%, charging is **automatically suspended** (`mmi_charging_enable = 0`), and the phone runs from the charger with the battery idle.

> The switch is OnePlus's own node, `/sys/class/oplus_chg/battery/mmi_charging_enable`. The generic `input_suspend` node does not work on this phone: it cuts the USB input, and the charger turns charging back on about 10 seconds later while the node still reads 1. Because the phone keeps running from the charger while suspended, the level holds near the ceiling instead of draining to the floor; the floor mainly matters after a power cut.

```
       [ Power Cut / Normal Run ]
                  |
                  v
         Battery drops to <= 50%
                  |
                  v
     [ RE-ENABLE CHARGING (suspend=0) ]
                  |
       Charges up to >= 85% (or 90%)
                  |
                  v
     [ SUSPEND CHARGING (suspend=1) ]
                  |
   Battery floats/rests without stress
```

### 🛡️ Critical Fail-Safes Built-In
1. **Instant Power-Cut Recovery:** When USB power drops (`usb/online == 0`), the daemon re-allows charging. The instant grid power returns, charging begins immediately with zero delay.
2. **Safety Floor Protection:** If battery ever drops to `<= 25%`, charging is unconditionally forced on regardless of any state.
3. **Graceful Exit Safety:** If the service is ever stopped or killed, an automatic signal trap re-allows charging so charging is never accidentally left disabled.
4. **Boot Persistence:** Placed in `/data/adb/service.d/smart_charge.sh` as a Magisk late_start service, with an automatic supervisor loop and `-900` OOM-killer immunity.

---

## 💻 CLI Usage (`chargectl`)
Run directly from `adb shell` as root (`su`):

```bash
# 1. Check live battery, temperature, voltage, and daemon status
/data/adb/smart_charge/chargectl status

adb shell "su -c '/data/adb/smart_charge/chargectl on'"

# 2. View recent state transition logs
/data/adb/smart_charge/chargectl log

# 3. Adjust thresholds on the fly (e.g. 50% to 90%)
/data/adb/smart_charge/chargectl limits 50 90

# 4. Force charging ON immediately (e.g. before a scheduled long outage)
/data/adb/smart_charge/chargectl on

# 5. Force charging OFF / suspended manually
/data/adb/smart_charge/chargectl off
```

---

## 📂 Configuration File
Path: `/data/adb/smart_charge/smart_charge.conf`

```sh
# Start charging when battery drops to or below this percentage
CHARGE_START_PERCENT=50

# Stop/suspend charging when battery reaches or exceeds this percentage
CHARGE_STOP_PERCENT=85

# Check interval in seconds
CHECK_INTERVAL_SECS=15

# Emergency safety floor
SAFETY_MIN_PERCENT=25
```

---

## 🚀 Redeployment / Installer
From your Mac workspace:
```bash
cd /Users/bipul/dspace/oneplus
./install_smart_charge.sh
```

