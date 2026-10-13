# TestFlight

**0.1.0 (20261013.8) is available** in the existing **Private Beta** group. Apple processing is `VALID`, the build is `IN_BETA_TESTING`, and the release notes and one existing personal tester were read back and verified. Upload errors and warnings are empty.

Open TestFlight on your iPhone and update **Inverter Link**. [Manage the build in App Store Connect](https://developer.apple.com/testflight/).

## This update

- Devices and App Settings are the root tabs. Named saved/connected devices open a dashboard without tabs; inverter settings and diagnostics are under Details.
- Adds saved names, default-inverter launch and six persistent accent colors.
- Compact native controls, aligned list insets, a single offline message, latest reading time in the top card and a separate Review sheet.
- A delayed successful connection no longer reopens the dashboard after you have backed out.

All **25 Release tests passed**, with no test failures or runtime warnings. The signed Release archive built successfully, app/widget versions match and archive signatures passed verification. Navigation, settings, review, accent and default launch were checked in the simulator using labeled sample data. See [VALIDATION.md](VALIDATION.md) for the physical-device limits.

**Read the [README warnings](README.md#before-using-this-app) before changing settings.** LED color 1 was physically set to blue with acknowledgement and matching readback. Other writes follow the protocol reference and matching Energy Mate formats but have not been exercised on the actual inverter. Battery values must follow manufacturer specifications. Local mode may pause Energy Mate cloud reporting.

Uploaded using `xcodebuild -exportArchive` and the existing Apple account. No API key was created. The build was assigned to the existing personal group, with no new testers added. No public App Store release was submitted.

Verified at 2026-10-13T11:17:47Z. The local status snapshot is `testflight-status.json` (ignored by Git); release logs and the signed archive stay outside the source repository.
