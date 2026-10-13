# Inverter Link

A native iOS app for monitoring and controlling a solar inverter directly over local Wi-Fi. Built with SwiftUI, RealityKit and WidgetKit, with no third-party app dependencies or cloud account.

Tested against a SolarMax-branded 4 kW / 24 V inverter with an Energy Mate / Eybond Wi-Fi logger using PI30. White-label branding alone does not establish compatibility.

## Before using this app

> **This app can change real inverter settings.** A confirmed change can affect charging, battery voltage limits, AC output, alarms and recovery behavior immediately. Start with monitoring and diagnostics. Use your inverter and battery manufacturers' specifications when changing settings.
>
> **Battery settings require particular care.** Incorrect charging, voltage or equalization values can interrupt power or damage a battery. The app validates command formats and documented limits; it cannot determine whether a value is appropriate for your battery or wiring.
>
> **Local mode may pause Energy Mate cloud reporting.** Discovery and connection ask the logger to send callbacks to the phone on TCP 8899. Automatic restoration of its previous cloud destination has not been verified.
>
> **The verified logger protocol has no authentication or encryption.** Use a trusted LAN and restrict access at the router/firewall. The app does not add security to the logger's network interface. Do not expose the logger or callback port to the internet.

Only LED color 1 has been physically changed and verified on the tested inverter: blue, an acknowledgement and matching readback. Other setting writes follow the protocol reference and matching Energy Mate command formats, but **have not been exercised on the real inverter**. Firmware may reject them. An acknowledgement without matching readback is reported as an error and is not retried automatically.

The settings map is specific to the verified PI30 / 24 V layout. Do not assume it applies to another model, firmware or battery voltage. AC2 schedules and maximum battery discharge current are unavailable in the verified readback. Factory reset and data erasure are not exposed.

## App flow

- **Devices:** Connected, Saved and Discovered devices share one screen. Scan finds local loggers; `+` connects by hostname/private IP. Tap a named device to open its dashboard. Long-press a saved row to rename it, choose it as the default or forget it.
- **Dashboard:** The interactive solar house, live measurements and the latest reading time. The device dashboard has no tab bar. Expand **Details** for inverter settings, diagnostics and the full measurements. The device menu provides Rename and Disconnect.
- **Inverter settings:** 37 mapped settings across Output, Battery, General and LED. Native lists, pickers and steppers, color presets and exact RGB hex input. The toolbar's **Review** opens a separate current/new sheet; **Apply change** sends the command and checks the readback. Unchanged and invalid values cannot reach review.
- **App Settings:** Refresh interval, Live Activity, six persistent accent colors and an optional **Open default inverter** launch preference. The launch shortcut is off by default.

The old single saved-device record migrates into the device library. Saved names, addresses, preferences and default selection stay on the phone. Reconnection checks the logger identity before using a remembered device. Scanning while connected excludes the active logger from discovery probes.

The LED input accepts six-digit RGB hex, for example `0000FF` for blue. Presets and hex input are used instead of a custom-color service that was unreliable in the simulator.

## Build and run

Requires Xcode 26 or newer, XcodeGen and iOS 18 or newer. Development used Xcode 27.

```sh
git clone https://github.com/talhabalaj/inverter-link.git
cd inverter-link
xcodegen generate
open InverterLink.xcodeproj
```

Choose the **InverterLink** scheme and your iPhone. Set your Apple development team for both **InverterLink** and **InverterLinkWidget**, then run. Join the inverter's Wi-Fi and allow **Local Network** access. In Devices, scan or connect by private IP/hostname. The project file is generated from `project.yml` and is ignored by Git.

Discovery uses the phone's Wi-Fi IPv4 interface and scans a `/24` or smaller subnet, with up to 24 simultaneous unicast probes. Larger networks can use manual address entry. Guest-network isolation, a VPN or another TCP 8899 listener can prevent callbacks. If the permission prompt interrupts discovery, allow access and scan again.

The app validates fixed PI30 queries, tunnel routes and CRCs. It does not store a cloud password, upload telemetry or persist readings. Saved logger identity and address information is stored locally for reconnection.

## Live Activity and background behavior

Enable Live Activity in App Settings and permit it in iOS Settings. It shows solar watts, load and battery percentage on the Lock Screen / Dynamic Island.

iOS only grants a short background grace period. When the app is suspended or disconnected, monitoring pauses and the activity marks its data as paused. Foregrounding the selected dashboard reconnects as needed. This is not an always-on background collector or a history service.

Grid watts and energy history are not inferred from grid voltage. Battery watts in the 3D view are an estimate from net reported current × voltage; particle speed is decorative. Reduce Motion disables moving energy dots.

## Verification

The final release checks and limitations are recorded in [VALIDATION.md](VALIDATION.md). Tests use loopback mock loggers; no unit test writes to a physical inverter.

```sh
xcodegen generate
xcodebuild -project InverterLink.xcodeproj -scheme InverterLink \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test
```

To run optimized Release tests, add `-configuration Release ENABLE_TESTABILITY=YES ONLY_ACTIVE_ARCH=YES`. Testability is enabled for that test command only, not for the distribution archive.

A DEBUG-only UI preview uses isolated preferences and sends no network queries or setting writes:

```sh
SIMCTL_CHILD_INVERTER_LINK_SETTINGS_PREVIEW=1 \
  xcrun simctl launch booted me.balaj.InverterLink
```

Preview screens explicitly identify their sample data. The preview fixture is excluded from Release/TestFlight builds.

| Evidence | Status |
| --- | --- |
| Release suite | 25 passed; no failures or runtime warnings |
| Local status and six settings queries | Read from the real tested inverter |
| LED color 1 write | Blue verified with ACK and readback |
| Other writes | Command validation tested; physical writes unverified |
| Navigation, color presets, review sheet, accent and default launch | Simulator UI walkthrough with labeled sample data |
| Physical iPhone UI and all setting writes | Still require device verification |

## Screenshots and design

Screenshots under `Screenshots/` include simulator preview data. The [imagegen concept](Docs/design/concept.png) inspired grouping and color selection; the final UI uses compact native components. The [generation prompt](Docs/design/prompt.md) records the built-in imagegen request.

## References

- [MAX / PI30 communication protocol](https://www.photovoltaikforum.com/core/attachment/232702-max-communication-protocol20210217-pdf/) — command formats used by the settings map.
- [Apple local network privacy guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) — permission and local networking behavior.
- [TestFlight notes](TestFlight.md) — current private beta build and release verification.
