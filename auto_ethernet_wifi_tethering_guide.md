# Automated Ethernet & Wi-Fi Tethering Failover Guide

## Overview
On modern rooted Android devices (Android 11–14+, such as your OnePlus 8 on OxygenOS / Android 13), automatic tethering handover is fully possible.

This system provides:
1. **Auto Ethernet Tethering**: Whenever a capable Ethernet adapter is connected and the WAN router is powered on (`carrier = 1`), Ethernet tethering turns on automatically, sharing mobile data with your router.
2. **Auto Wi-Fi Hotspot Failover**: The instant your Ethernet WAN router is powered down or loses connection (`carrier = 0`), the phone automatically stops Ethernet tethering and starts **Wi-Fi Tethering (Mobile Hotspot)**.
3. **Automatic Recovery**: As soon as power is restored to the router and the Ethernet link negotiates (`carrier = 1`), the phone turns off the Wi-Fi hotspot and reverts to Ethernet tethering.
4. **Persistent Boot Support**: Configured as a Magisk late_start service (`/data/adb/service.d/auto_tether.sh`) so it automatically starts on boot.

---

## System Architecture

```
                 +-----------------------------+
                 |   Rooted OnePlus 8 (A13)    |
                 +-----------------------------+
                                |
                   /sys/class/net/eth*/carrier
                                |
               +----------------+----------------+
               |                                 |
        [ carrier == 1 ]                  [ carrier == 0 ]
     (Router is powered ON)            (Router is powered OFF)
               |                                 |
               v                                 v
   +-----------------------+         +-----------------------+
   | 1. Stop Wi-Fi Hotspot |         | 1. Stop Eth Tethering |
   | 2. Start Eth Tether   |         | 2. Start Wi-Fi Hotspot|
   +-----------------------+         +-----------------------+
```

### Components Deployed
| Component | Device Path | Purpose |
| :--- | :--- | :--- |
| **`tetherctl.dex`** | `/data/adb/tether/tetherctl.dex` | Compiled DEX bridge that directly calls Android 13's hidden `ITetheringConnector` Binder APIs. |
| **`tetherctl`** | `/data/adb/tether/tetherctl` | Shell wrapper CLI to start/stop Wi-Fi & Ethernet tethering from terminal or scripts. |
| **`auto_tether_watchdog.sh`** | `/data/adb/tether/auto_tether_watchdog.sh` | Background daemon that polls link carrier every 2s, debounces flaps, and triggers switches. |
| **`auto_tether.sh`** | `/data/adb/service.d/auto_tether.sh` | Magisk boot service that launches the watchdog after `sys.boot_completed=1`. |
| **`auto_tether.log`** | `/data/adb/tether/auto_tether.log` | Persistent rolling log file (capped at 500 lines) of all state transitions. |

---

## CLI Usage (`tetherctl`)

You can control tethering programmatically or manually from `adb shell` or Termux as root (`su`):

```bash
# Start/Stop Wi-Fi Hotspot
/data/adb/tether/tetherctl wifi-on
/data/adb/tether/tetherctl wifi-off

# Start/Stop Ethernet Tethering
/data/adb/tether/tetherctl eth-on
/data/adb/tether/tetherctl eth-off

# Emergency: Stop all tethering
/data/adb/tether/tetherctl stop-all
```

---

## Checking Logs & Status

### 1. View Watchdog Daemon Log
```bash
adb -s 10.47.219.28:8855 shell "su -c 'cat /data/adb/tether/auto_tether.log'"
```

### 2. View Real-time Android System Logcat
```bash
adb -s 10.47.219.28:8855 shell "su -c 'logcat -d -s AutoTether'"
```

### 3. Check Current Android Tethering State
```bash
adb -s 10.47.219.28:8855 shell "dumpsys tethering | grep -E 'Tether state:' -A 4"
```
- When Ethernet is active: `eth0 - TetheredState`
- When Wi-Fi is active: `wlan2 - TetheredState` (or similar `wlan`/`ap_br` interface)

---

## Debouncing & Power Cycle Resilience
When your WAN router powers down or restarts, network cards can rapidly bounce the physical link (`1 -> 0 -> 1 -> 0`). 
To prevent thrashing:
- The watchdog script enforces a **4-second debounce threshold** (requires 2 consecutive stable samples before performing a handover).
- Includes an automatic **health check loop** every 10 seconds: if tethering ever crashes or is killed by the OS, it self-heals and restarts.

---

## Redeploying or Modifying
To redeploy from your Mac workspace at any time:
```bash
cd /Users/bipul/dspace/oneplus
./install_auto_tether.sh
```
