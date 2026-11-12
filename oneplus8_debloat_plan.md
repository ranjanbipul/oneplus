# OnePlus 8 (IN2011) Debloat Plan
**Device:** OnePlus 8 IN2011 · OxygenOS/ColorOS 13.1.0.590 · Android 13  
**ADB Target:** `10.179.121.158:8855`

> [!IMPORTANT]
> **No packages are removed.** All actions use `pm disable-user --user 0 <pkg>` which is fully reversible with `pm enable <pkg>`. The device must be **rooted** or commands run via ADB shell.

> [!CAUTION]
> Do NOT disable anything outside this list without research. Disabling wrong system packages can bootloop the device.

---

## 📜 Execution Log (Categories 1–3 Executed)
**Execution Date:** 2026-11-12 10:51 IST  
**Target Device:** OnePlus 8 (IN2011)  
**Total Packages Disabled:** 50 packages  

### Disabled in this run:
- **Category 1 (Google Telemetry & Ads - 8 packages):**
  - `com.google.android.adservices.api`
  - `com.google.mainline.adservices`
  - `com.google.mainline.telemetry`
  - `com.google.android.ondevicepersonalization.services`
  - `com.google.android.federatedcompute`
  - `com.google.android.feedback`
  - `com.google.android.partnersetup`
  - `com.google.android.onetimeinitializer`

- **Category 2 (OPlus Telemetry, Cloud, Store & Bloat - 23 packages):**
  - `com.oplus.statistics.rom`
  - `com.oplus.logkit`
  - `com.oplus.onetrace`
  - `com.oplus.qualityprotect`
  - `com.oplus.crashbox`
  - `com.oplus.lfeh`
  - `com.oplus.sau`
  - `com.oplus.sauhelper`
  - `com.oplus.themestore`
  - `com.oplus.omoji`
  - `com.oplus.games`
  - `com.oplus.ocloud`
  - `com.oplus.pay`
  - `com.oneplus.membership`
  - `com.oplus.appplatform`
  - `com.heytap.cloud`
  - `com.heytap.mcs`
  - `com.heytap.colorfulengine`
  - `com.heytap.accessory`
  - `com.oppo.quicksearchbox`
  - `com.coloros.operationManual`
  - `com.coloros.systemclone`
  - `com.coloros.childrenspace`

- **Category 3 (Qualcomm Extras & Engineering Tools - 19 packages):**
  - `com.oplus.wifitest`
  - `com.oplus.bttestmode`
  - `com.oplus.engineercamera`
  - `com.oplus.engineermode`
  - `com.oplus.engineernetwork`
  - `com.qualcomm.qti.modemtestmode`
  - `com.qualcomm.qti.devicestatisticsservice`
  - `com.qualcomm.qti.xrcb`
  - `com.qualcomm.qti.xrvd.service`
  - `com.qualcomm.embms`
  - `com.android.cts.ctsshim`
  - `com.android.cts.priv.ctsshim`
  - `com.android.egg`
  - `com.android.traceur`
  - `com.android.dreams.basic`
  - `com.wapi.wapicertmanage`
  - `com.ses.entitlement.o2`
  - `com.redteamobile.roaming`
  - `com.mediatek.omacp`

---

## ⚡ Exact Step-by-Step Revert Commands

### Option A: Revert ONLY the packages disabled in this session
Run from terminal:
```bash
while read -r pkg; do
  adb shell "pm enable $pkg"
done < /Users/bipul/dspace/oneplus/debloated_packages.log
```

### Option B: Revert a specific package (e.g. OPlus Theme Store)
```bash
adb shell "pm enable com.oplus.themestore"
```

### Option C: Complete restore of all disabled packages on the device
```bash
adb shell "pm list packages -d" | sed 's/package://' | while read -r pkg; do
  adb shell "pm enable $pkg"
done
```

---

## How to Disable & Re-enable (Revert)

### Disable a package
```bash
adb -s 10.179.121.158:8855 shell "pm disable-user --user 0 <package.name>"
```

### Re-enable (revert) a single package
```bash
adb -s 10.179.121.158:8855 shell "pm enable <package.name>"
```

### Re-enable ALL disabled packages at once (full revert)
```bash
adb -s 10.179.121.158:8855 shell "pm list packages -d" | sed 's/package://' | while read pkg; do
  adb -s 10.179.121.158:8855 shell "pm enable $pkg"
done
```

---

## Already Disabled (Pre-existing)
These were disabled before — leaving them as-is:
| Package | Description |
|---|---|
| `com.google.android.gms.supervision` | Google Kids supervision |
| `com.netflix.mediaclient` | Netflix (pre-installed bloat) |
| `com.oplus.customize.coreapp` | Oplus customization core |

---

## 🗑️ Recommended Packages to Disable

### Category 1 — Google Bloat (Safe to disable if unused)

| Package | What it is | Risk |
|---|---|---|
| `com.google.android.apps.googleassistant` | Google Assistant (use if you don't use voice assistant) | Low |
| `com.google.android.apps.restore` | Pixel-only restore app — useless on OnePlus | None |
| `com.google.android.apps.wellbeing` | Digital Wellbeing (screen time tracker) | Low |
| `com.google.android.ar.core` | ARCore — only needed for AR apps | Low |
| `com.google.ar.lens` | Google Lens (standalone) — still works via camera | Low |
| `com.google.android.feedback` | Google feedback reporter | None |
| `com.google.android.gm` | Gmail (if you use another email client) | Low |
| `com.google.android.apps.podcasts` | Google Podcasts | None |
| `com.google.android.apps.youtube.music` | YouTube Music (if unused) | None |
| `com.google.android.youtube` | YouTube (if unused) | None |
| `com.google.android.calendar` | Google Calendar (if using another) | Low |
| `com.google.android.apps.maps` | Google Maps (if using another) | Low |
| `com.google.android.apps.photos` | Google Photos (if using OnePlus Gallery) | Low |
| `com.google.android.tts` | Google Text-to-Speech (if no apps use it) | Low |
| `com.google.android.printservice.recommendation` | Print service recommender | None |
| `com.google.android.projection.gearhead` | Android Auto | None |
| `com.google.android.marvin.talkback` | TalkBack accessibility (if not needed) | Low |
| `com.google.android.accessibility.switchaccess` | Switch Access accessibility | None |
| `com.google.android.gms.location.history` | Google Location History | Low |
| `com.google.android.ondevicepersonalization.services` | Ad personalization service | None |
| `com.google.android.federatedcompute` | Federated learning for ads | None |
| `com.google.android.adservices.api` | Google Ad Services | None |
| `com.google.mainline.adservices` | Google mainline ad services | None |
| `com.google.mainline.telemetry` | Google telemetry | None |
| `com.google.android.hotwordenrollment.okgoogle` / `xgoogle` | "Hey Google" hotword | Low |
| `com.android.hotwordenrollment.okgoogle` / `xgoogle` | Duplicate hotword enrollment | Low |
| `com.google.android.setupwizard` | Setup wizard (post-setup, safe) | Low |
| `com.google.android.onetimeinitializer` | First-boot initializer | Low |
| `com.google.android.partnersetup` | Partner app setup | None |
| `com.google.android.apps.nbu.paisa.user` | Google Pay (if unused) | Low |

---

### Category 2 — OxygenOS / ColorOS Bloat (OPlus)

| Package | What it is | Risk |
|---|---|---|
| `com.oplus.themestore` | Oplus Theme Store | None |
| `com.oplus.omoji` | Omoji (AR emoji) | None |
| `com.oplus.games` | Oplus Games platform | None |
| `com.oplus.ocloud` | Oplus Cloud storage | None |
| `com.oplus.cast` | Screen casting app | Low |
| `com.oplus.melody` | Oplus music? | None |
| `com.oplus.deepthinker` | AI on-device inference engine (if no Oplus AI features used) | Low |
| `com.oplus.obrain` | Oplus AI brain service | Low |
| `com.oplus.aiunit` | Oplus AI processing unit | Low |
| `com.oplus.portrait` | Portrait mode extra service | Low |
| `com.oplus.viewtalk` | Video call features (Oplus) | None |
| `com.oplus.synergy` | Oplus multi-device synergy (Oplus Connect) | None |
| `com.oplus.interconnectcollectkit` | Multi-device connectivity kit | None |
| `com.oplus.virtualcomm` | Virtual communication layer | Low |
| `com.oplus.pay` | Oplus Pay | None |
| `com.oplus.membership` / `com.oneplus.membership` | OnePlus membership / ads | None |
| `com.oneplus.account` | OnePlus account (if not using Oplus cloud services) | Low |
| `com.oplus.appplatform` | Oplus app store / platform | None |
| `com.oplus.statistics.rom` | ROM telemetry / analytics | None |
| `com.oplus.logkit` | Log collection tool | None |
| `com.oplus.onetrace` | Telemetry trace tool | None |
| `com.oplus.qualityprotect` | Oplus quality reporting | None |
| `com.oplus.crashbox` | Crash reporting (can disable, rooted) | Low |
| `com.oplus.lfeh` | Log/feedback handler | None |
| `com.oplus.sau` / `com.oplus.sauhelper` | Software auto-update helpers | Low |
| `com.oplus.romupdate` | OTA ROM updater (disable only if on custom ROM or don't want OTA) | Medium |
| `com.oplus.wifitest` | Wi-Fi test/engineering tool | None |
| `com.oplus.bttestmode` | Bluetooth test mode | None |
| `com.oplus.engineercamera` | Engineering camera | None |
| `com.oplus.engineermode` | Engineering mode dialer | None |
| `com.oplus.engineernetwork` | Engineering network tool | None |
| `com.coloros.operationManual` | Built-in operation manual | None |
| `com.coloros.systemclone` | System clone (phone migration) | None |
| `com.coloros.childrenspace` | Kids mode | None |
| `com.coloros.scenemode` | Scene mode service | Low |
| `com.coloros.weather.service` | Coloros weather backend | Low |
| `com.oplus.phonenoareainquire` | Phone number area lookup | None |
| `com.oppo.quicksearchbox` | Oppo Quick Search (use Google Search) | None |
| `com.heytap.cloud` | HeyTap/Oppo cloud | None |
| `com.heytap.colorfulengine` | HeyTap UI engine | Low |
| `com.heytap.mcs` | HeyTap message/cloud service | None |
| `com.heytap.accessory` | HeyTap accessory support | None |
| `com.oplus.wallpapers` | Oplus wallpaper app (if using OnePlus wallpaper) | Low |
| `net.oneplus.wallpaperresources` | OnePlus wallpaper resources | Low |
| `com.oneplus.wallpaper` | OnePlus wallpaper app | Low |
| `com.oplus.nas` | NAS/network storage service | Low |
| `com.oplus.multiapp` | Multi-app / clone app feature | Low |
| `com.oplus.ocs` | Oplus cloud services backend | Low |
| `com.oplus.olc` | Oplus live caption? | Low |

---

### Category 3 — Qualcomm Extras (Safe)

| Package | What it is | Risk |
|---|---|---|
| `com.qualcomm.qti.modemtestmode` | Modem test mode | None |
| `com.qualcomm.qti.devicestatisticsservice` | Qualcomm device statistics | None |
| `com.qualcomm.qti.workloadclassifier` | Qualcomm workload classifier | Low |
| `com.qualcomm.qti.xrcb` | XR (AR/VR) Qualcomm service | None |
| `com.qualcomm.qti.xrvd.service` | XR visual display service | None |
| `com.qualcomm.embms` | eMBMS (carrier TV streaming, unused in India) | None |
| `com.quicinc.voice.activation` | Qualcomm voice activation | None |
| `com.redteamobile.roaming` | Virtual SIM / roaming service | Low |
| `com.ses.entitlement.o2` | O2 carrier entitlement (irrelevant in India) | None |
| `com.wapi.wapicertmanage` | WAPI cert (China Wi-Fi standard, irrelevant) | None |
| `com.mediatek.omacp` | MediaTek OMA-CP (not relevant on Snapdragon) | None |
| `com.android.cts.ctsshim` / `com.android.cts.priv.ctsshim` | CTS test shims (factory testing) | None |
| `com.android.egg` | Android easter egg | None |
| `com.android.dreams.basic` | Daydream screensaver | None |
| `com.android.bookmarkprovider` | Browser bookmark provider | None |
| `com.android.wallpaper.livepicker` | Live wallpaper picker | Low |
| `com.android.traceur` | System tracing (dev tool) | None |
| `com.android.bips` | Built-in print service | None |
| `com.android.printspooler` | Print spooler (if no printing needed) | Low |
| `com.android.stk` | SIM Toolkit (disable only if carrier doesn't use it) | Medium |

---

### Category 4 — Pre-installed User Apps (3rd party)

> These are **your installed apps** — only listed ones that appear to be shopping/delivery bloat:

| Package | What it is |
|---|---|
| `com.akshat.comparify` | Price comparator |
| `com.bigbasket.mobileapp` | BigBasket grocery |
| `com.buyhatke.assistant` | BuyHatke deals |
| `com.cricbuzz.android` | Cricbuzz cricket |
| `com.flipkart.android` | Flipkart |
| `com.freshtohome` | FreshToHome meat delivery |
| `com.fsn.nykaa` | Nykaa beauty |
| `com.games24x7.my11circle.fantasycricket` | Fantasy cricket |
| `com.grofers.customerapp` | Blinkit/Grofers |
| `com.licious` | Licious meat |
| `com.milkbasket.app` | MilkBasket |
| `com.myntra.android` | Myntra fashion |
| `com.olacabs.customer` | Ola cabs |
| `com.rapido.passenger` | Rapido |
| `com.tendercuts.app` | Tendercuts |
| `com.urbanpiper.meatigo` | Meatigo |
| `com.zeptoconsumerapp` | Zepto |
| `in.amazon.mShop.android.shopping` | Amazon Shopping |
| `in.dmart` | DMart |
| `in.juspay.nammayatri` | Namma Yatri |
| `in.mobility.bharatTaxi` | Bharat Taxi |
| `in.rozmo.app` | Rozmo |
| `in.swiggy.android` | Swiggy |
| `in.swiggy.android.instamart` | Swiggy Instamart |

---

## ⚡ Ready-to-Run Disable Commands (by group)

### Group A — Google Telemetry / Ads (paste as one block)
```bash
ADB="adb -s 10.179.121.158:8855 shell"
$ADB "pm disable-user --user 0 com.google.android.adservices.api"
$ADB "pm disable-user --user 0 com.google.mainline.adservices"
$ADB "pm disable-user --user 0 com.google.mainline.telemetry"
$ADB "pm disable-user --user 0 com.google.android.ondevicepersonalization.services"
$ADB "pm disable-user --user 0 com.google.android.federatedcompute"
$ADB "pm disable-user --user 0 com.google.android.feedback"
$ADB "pm disable-user --user 0 com.google.android.partnersetup"
$ADB "pm disable-user --user 0 com.google.android.onetimeinitializer"
```

### Group B — Oplus Telemetry / Analytics
```bash
ADB="adb -s 10.179.121.158:8855 shell"
$ADB "pm disable-user --user 0 com.oplus.statistics.rom"
$ADB "pm disable-user --user 0 com.oplus.logkit"
$ADB "pm disable-user --user 0 com.oplus.onetrace"
$ADB "pm disable-user --user 0 com.oplus.qualityprotect"
$ADB "pm disable-user --user 0 com.oplus.crashbox"
$ADB "pm disable-user --user 0 com.oplus.lfeh"
$ADB "pm disable-user --user 0 com.oplus.sau"
$ADB "pm disable-user --user 0 com.oplus.sauhelper"
```

### Group C — Oplus Cloud / Social / Store
```bash
ADB="adb -s 10.179.121.158:8855 shell"
$ADB "pm disable-user --user 0 com.oplus.themestore"
$ADB "pm disable-user --user 0 com.oplus.omoji"
$ADB "pm disable-user --user 0 com.oplus.games"
$ADB "pm disable-user --user 0 com.oplus.ocloud"
$ADB "pm disable-user --user 0 com.oplus.pay"
$ADB "pm disable-user --user 0 com.oplus.membership"
$ADB "pm disable-user --user 0 com.oneplus.membership"
$ADB "pm disable-user --user 0 com.oplus.appplatform"
$ADB "pm disable-user --user 0 com.heytap.cloud"
$ADB "pm disable-user --user 0 com.heytap.mcs"
$ADB "pm disable-user --user 0 com.heytap.colorfulengine"
$ADB "pm disable-user --user 0 com.heytap.accessory"
$ADB "pm disable-user --user 0 com.oppo.quicksearchbox"
$ADB "pm disable-user --user 0 com.coloros.operationManual"
$ADB "pm disable-user --user 0 com.coloros.systemclone"
$ADB "pm disable-user --user 0 com.coloros.childrenspace"
```

### Group D — Engineering / Test Tools
```bash
ADB="adb -s 10.179.121.158:8855 shell"
$ADB "pm disable-user --user 0 com.oplus.wifitest"
$ADB "pm disable-user --user 0 com.oplus.bttestmode"
$ADB "pm disable-user --user 0 com.oplus.engineercamera"
$ADB "pm disable-user --user 0 com.oplus.engineermode"
$ADB "pm disable-user --user 0 com.oplus.engineernetwork"
$ADB "pm disable-user --user 0 com.qualcomm.qti.modemtestmode"
$ADB "pm disable-user --user 0 com.qualcomm.qti.devicestatisticsservice"
$ADB "pm disable-user --user 0 com.qualcomm.qti.xrcb"
$ADB "pm disable-user --user 0 com.qualcomm.qti.xrvd.service"
$ADB "pm disable-user --user 0 com.qualcomm.embms"
$ADB "pm disable-user --user 0 com.android.cts.ctsshim"
$ADB "pm disable-user --user 0 com.android.cts.priv.ctsshim"
$ADB "pm disable-user --user 0 com.android.egg"
$ADB "pm disable-user --user 0 com.android.traceur"
$ADB "pm disable-user --user 0 com.android.dreams.basic"
$ADB "pm disable-user --user 0 com.wapi.wapicertmanage"
$ADB "pm disable-user --user 0 com.ses.entitlement.o2"
$ADB "pm disable-user --user 0 com.redteamobile.roaming"
$ADB "pm disable-user --user 0 com.mediatek.omacp"
```

### Group E — Google Apps (disable only what you don't use)
```bash
ADB="adb -s 10.179.121.158:8855 shell"
$ADB "pm disable-user --user 0 com.google.android.apps.restore"
$ADB "pm disable-user --user 0 com.google.android.printservice.recommendation"
$ADB "pm disable-user --user 0 com.google.android.projection.gearhead"
$ADB "pm disable-user --user 0 com.google.android.accessibility.switchaccess"
$ADB "pm disable-user --user 0 com.google.android.gms.location.history"
$ADB "pm disable-user --user 0 com.android.hotwordenrollment.okgoogle"
$ADB "pm disable-user --user 0 com.android.hotwordenrollment.xgoogle"
$ADB "pm disable-user --user 0 com.android.bips"
$ADB "pm disable-user --user 0 com.android.printspooler"
$ADB "pm disable-user --user 0 com.android.bookmarkprovider"
$ADB "pm disable-user --user 0 com.android.dreams.basic"
$ADB "pm disable-user --user 0 com.android.wallpaper.livepicker"
```

---

## ✅ Full Revert — Re-enable Everything
If anything breaks, run this to re-enable all disabled packages:
```bash
adb -s 10.179.121.158:8855 shell "pm list packages -d" \
  | sed 's/package://' \
  | while IFS= read -r pkg; do
      echo "Enabling: $pkg"
      adb -s 10.179.121.158:8855 shell "pm enable $pkg"
    done
```

Or re-enable specific packages:
```bash
adb -s 10.179.121.158:8855 shell "pm enable com.package.name"
```

---

## ⚠️ Do NOT Disable These (even if tempted)

| Package | Why |
|---|---|
| `com.oplus.battery` | Battery management — disabling kills power features |
| `com.oplus.ota` | OTA updates trigger |
| `com.oplus.securitypermission` | Permission framework |
| `com.oplus.exsystemservice` / `com.oplus.exserviceui` | Core OxygenOS system services |
| `com.oplus.location` / `com.oplus.locationproxy` | Location framework |
| `com.oplus.gesture` | Gesture navigation |
| `com.oplus.smartengine` | System intelligence engine |
| `com.oplus.subsys` | Oplus subsystem framework |
| `com.oplus.uiengine` / `com.oplus.uxdesign` | Core UI rendering |
| `com.oplus.notificationmanager` | Notification system |
| `com.oplus.aod` | Always-on display |
| `com.oplus.sos` | Emergency SOS |
| `com.oplus.encryption` | Full-disk encryption |
| `com.qualcomm.qti.telephonyservice` | Cell radio / calls |
| `com.qualcomm.qti.ims` / `org.codeaurora.ims` | VoLTE / IMS calls |
| `com.google.android.gms` | Google Play Services |
| `com.android.vending` | Play Store |
| `com.google.android.webview` | WebView (used by all apps) |
| `com.android.phone` | Phone dialer |
| `com.android.systemui` | System UI |
