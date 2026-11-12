# CallBridge: use the OnePlus 8's SIM from another Android device or a Mac

CallBridge lets a second, unrooted Android device or a Mac on the OnePlus 8's network make and
receive calls through the OnePlus 8's SIM, with two-way audio, call log and SMS.

- **Gateway** (`callbridge/gateway`): privileged app on the rooted OnePlus 8, installed as a Magisk module.
- **Client** (`callbridge/client`): normal APK for the second device.
- **Mac client** (`callbridge/macos`): native SwiftUI app (macOS 14+, Intel or Apple silicon).
- **Protocol** (`callbridge/proto`): TCP 8765 for control, UDP 8766 for audio (16 kHz mono PCM). LAN only.

## Install the gateway (OnePlus 8)

```bash
./install_callbridge.sh stage
```

Reboot the phone (tethering drops for about a minute), then:

```bash
./install_callbridge.sh finish
```

`finish` grants the runtime permissions, lets the gateway use root without a prompt, starts the
service, and prints the pairing key. The key is also shown in the **CallBridge Gateway** app on the phone.

The phone's adb address is the Mac's default gateway on port 8855 and changes on every phone
reboot; the script detects it. Override with `DEVICE=ip:port`.

For later code changes that do not add a privileged permission, no reboot is needed:

```bash
./install_callbridge.sh update
```

## Install the client (second device)

Sideload `callbridge/client/build/outputs/apk/release/client-release.apk`, open it, allow the
microphone and notification permissions, then in **Settings** enter the pairing key and tap
**Save and connect**. Leave the gateway address empty when the device is on the OnePlus 8's
hotspot or Ethernet tether: the app connects to the network's router, which is the phone.

Recommended on the second device: exclude CallBridge from battery optimisation so incoming calls
ring reliably, and open the app once after each reboot of that device.

## Install the Mac client

Needs Xcode (or the Command Line Tools) on the Mac:

```bash
callbridge/macos/build_app.sh --install
```

This builds `callbridge/macos/build/CallBridge.app` and copies it to `/Applications`. Open it,
allow the microphone and notifications, then in **Settings** enter the pairing key and click
**Save & Reconnect**. As on Android, leave the address empty when the Mac uses the OnePlus 8's
hotspot or USB tether.

- The app keeps running in the menu bar when its window is closed, so calls still ring. Incoming
  calls ring, bring the window forward and post a notification with Answer and Decline buttons.
- Audio uses the Mac's default input and output with Apple's voice processing (echo
  cancellation and noise suppression), so the built-in speakers and microphone work without
  headphones. Changing devices mid-call is handled.
- **Keep Mac awake while connected** (on by default) stops idle sleep so calls can ring; the
  Mac never idle-sleeps during a call. A closed lid still sleeps the Mac and drops the link.
- The build is signed with your Apple Development identity when there is one, so macOS remembers
  the microphone permission across rebuilds. With only an ad-hoc signature it asks again after
  every build. Set `CODESIGN_IDENTITY` to choose another identity.

## Several clients at once

Any number of paired clients (Android and Mac) can be connected at the same time. All of them get
call state, call log and SMS updates, and an incoming call rings on all of them. The client that
answers or dials owns the call and is the only one that gets its audio; the others show the call
as being on another device and can still hang it up. A call cannot be moved to another client
while it is in progress. **New pairing key** in the gateway app unpairs every client.

## How call audio works on this phone

Verified on IN2011, OxygenOS 13.1, Jio SIM in slot 2:

- **Far party to you:** Android 13 system API `getCallDownlinkExtractionAudioRecord`
  (privileged permission `CALL_AUDIO_INTERCEPTION`).
- **You to far party:** root. The matching system API for injection is silent on this ROM, so the
  gateway enables the modem's in-call music mixer (`Incall_Music` / `Incall_Music_2 Audio Mixer
  MultiMedia2`) and streams 48 kHz stereo into ALSA device 1 with `tinyplay`, fed through a pipe.
  `tinyplay` exits on a buffer underrun, so the gateway uses a 4 x 480-frame buffer, queues
  100 ms of silence ahead of live audio, and restarts the injector if it stops. This adds
  roughly 100-150 ms of delay in this direction.
- **Phone's own microphone:** muted during bridged calls with the default `telecom` mode, which
  is confirmed not to silence the injected audio. The mode can be changed in the gateway app or with
  `adb shell am start-foreground-service -n com.antigravity.callbridge.gateway/.BridgeService --es mute_mode telecom|device|none`.

## Troubleshooting

- Gateway log on the OnePlus 8: `/sdcard/Android/data/com.antigravity.callbridge.gateway/files/gateway.log`
  (the system log on this phone rotates within seconds).
- If the client device drops off the network during a call, the gateway waits 20 seconds for it to
  reconnect and resumes the audio; after that it hangs up.
- `./install_callbridge.sh update` leaves a side-loaded copy of the gateway over the module's copy.
  That is fine while the privileged permission list is unchanged; `finish` removes it.

## Limits

- LAN only; audio and control are not encrypted (control is authenticated with the pairing key).
- One call at a time; a second (waiting) call is ignored.
- If the client stays off the network for more than 20 seconds during a call it is on, the gateway hangs the call up.
- Calls answered on the OnePlus 8 itself are not bridged.
- A call stays on the client that answered or placed it; it cannot be handed to another client.

## Uninstall

```bash
adb -s <phone>:8855 shell su -c 'touch /data/adb/modules/callbridge/remove'
```

Then reboot the phone. Uninstall the client app normally.

If the phone ever fails to boot after a module change, boot to safe mode (hold volume down
during boot) — Magisk disables all modules in safe mode.
