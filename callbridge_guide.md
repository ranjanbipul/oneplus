# CallBridge: use the OnePlus 8's SIM from another Android device

CallBridge lets a second, unrooted Android device on the OnePlus 8's network make and receive
calls through the OnePlus 8's SIM, with two-way audio, call log and SMS.

- **Gateway** (`callbridge/gateway`): privileged app on the rooted OnePlus 8, installed as a Magisk module.
- **Client** (`callbridge/client`): normal APK for the second device.
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

## Uninstall

```bash
adb -s <phone>:8855 shell su -c 'touch /data/adb/modules/callbridge/remove'
```

Then reboot the phone. Uninstall the client app normally.

If the phone ever fails to boot after a module change, boot to safe mode (hold volume down
during boot) — Magisk disables all modules in safe mode.
