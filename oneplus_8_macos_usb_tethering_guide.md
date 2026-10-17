# OnePlus 8 → macOS USB Tethering Guide

How to get USB tethering from a OnePlus 8 working on a Mac by switching the phone's USB tethering protocol from **RNDIS** to **NCM**.

---

## The problem

The Mac didn't detect the OnePlus 8 when USB tethering was turned on. No new network interface appeared in System Settings → Network.

**Cause:** the OnePlus 8 uses **RNDIS** for USB tethering by default. macOS has no RNDIS driver, so it ignores the phone.

---

## RNDIS vs NCM

| | **RNDIS** | **NCM** |
|---|---|---|
| Full name | Remote Network Driver Interface Specification | Network Control Model |
| Origin | Proprietary Microsoft protocol | Open USB-IF standard (part of the CDC class spec) |
| Windows | Supported natively | Supported natively on Windows 10/11 |
| Linux | Supported natively | Supported natively |
| macOS | **Not supported** (no driver) | **Supported natively** |
| Android default | Most phones, including OnePlus, Samsung and Xiaomi | Pixels and some newer devices |
| Performance | Fine, but older design with more overhead | Batches packets into larger USB transfers, which makes it more efficient |

**Why the old driver workaround is not an option:** HoRNDIS, a third-party RNDIS driver for macOS, is abandoned. It doesn't work on recent macOS versions or on Apple Silicon Macs. Don't install it.

**The fix:** on Android 12 and newer, a hidden global setting, `tether_force_usb_functions`, makes USB tethering use NCM instead of RNDIS. The phone's kernel also has to support NCM, which the OnePlus 8 does.

| Value | Protocol used for USB tethering |
|---|---|
| `0` (default) | RNDIS |
| `1` | NCM |

---

## Requirements

- OnePlus 8 running **Android 12 or newer** (OxygenOS 12/13)
- A USB cable that carries data (not charge-only), plugged directly into the Mac with no hub
- ADB (Android Platform Tools) installed on the Mac
- Root is **not** required

---

## Steps

### 1. Enable Developer options
1. Go to **Settings → About device → Version**.
2. Tap **Build number** 7 times until it says you are a developer.

### 2. Enable USB debugging
1. Go to **Settings → System → Developer options**.
2. Turn on **USB debugging**.

### 3. Install ADB on the Mac
With Homebrew:
```bash
brew install android-platform-tools
```
Without Homebrew, download "SDK Platform-Tools for Mac" from the Android developer site and unzip it.

### 4. Connect the phone and authorise ADB
```bash
adb devices
```
Tap **Allow** on the USB-debugging prompt on the phone. The device should then be listed as `device`, not `unauthorized`.

### 5. Disable permission monitoring (OnePlus-specific)
On OxygenOS 12/13 the first attempt failed with a permission denial:
```bash
adb shell settings put global tether_force_usb_functions 1
# → denied
```
OnePlus's permission monitoring blocks ADB from writing global settings. To turn it off:
1. Go to **Developer options**.
2. Turn on **Disable permission monitoring**.

### 6. Reconnect and restart
1. Unplug the USB cable and plug it back in.
2. Restart the phone so the permission change fully applies.
3. Run `adb devices` again to confirm the phone reconnects.

### 7. Force NCM for USB tethering
```bash
adb shell settings put global tether_force_usb_functions 1
```
Verify it:
```bash
adb shell settings get global tether_force_usb_functions
# should print: 1
```

### 8. Turn on USB tethering
1. On the phone, go to **Settings → Network & internet → Hotspot & tethering**.
2. Turn **USB tethering** off and back on, if it was already on.

### 9. Confirm on the Mac
1. Open **System Settings → Network**. A new interface for the phone should appear and connect.
2. If it appears but doesn't connect:
   - Click **"…" → Add Service** and select the interface.
   - Click **"…" → Set Service Order** and drag it above Wi-Fi if you want it to take priority.

You can also check from Terminal:
```bash
networksetup -listallhardwareports
```

---

## Reverting

To go back to RNDIS, for example when tethering to Windows or a device that only supports RNDIS:
```bash
adb shell settings put global tether_force_usb_functions 0
```
Then turn **Disable permission monitoring** back off and turn off **USB debugging** if you no longer need them.

---

## Alternative: setting it with root

If the phone is rooted, you can skip disabling permission monitoring and run the command as root. Grant **Shell** root access when Magisk (or your root manager) prompts:
```bash
adb shell su -c "settings put global tether_force_usb_functions 1"
adb shell su -c "settings get global tether_force_usb_functions"
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `settings put` denied | Turn on **Disable permission monitoring**, reconnect, and restart the phone (steps 5–6). Or use the root method. |
| `adb devices` shows `unauthorized` | Unlock the phone and accept the USB-debugging prompt. Revoke USB debugging authorisations in Developer options and reconnect if no prompt appears. |
| `adb devices` shows nothing | Try a different cable or port, avoid hubs, and make sure USB debugging is on. |
| USB tethering won't turn on after the change | The kernel may not support NCM on that build. Revert to `0`. |
| Mac still sees nothing | Toggle USB tethering off and on, replug the cable, and check `settings get` still returns `1`. A major OTA update may reset the setting. |

## Fallbacks if NCM ever stops working
- **Phone Wi-Fi hotspot**: no setup needed.
- **EasyTether**: paid app with a Mac driver that does USB tethering without RNDIS. A free Lite version is available.
