# TestFlight

**0.1.0 (20261013.9)** was verified in the existing private beta on 2026-10-13. Apple processing was `VALID`, the build was `IN_BETA_TESTING`, and upload errors and warnings were empty.

Existing invited testers can open TestFlight on their iPhone and update **Inverter Link**. Publishing this source repository does not create a public TestFlight invitation or App Store listing.

## This update

Restores the native color picker alongside LED presets and RGB hex input. All three update the same draft; review and apply are still required before sending a setting.

The signed Release archive built successfully, app/widget versions match and archive signatures passed verification. The previous build's 25 Release tests passed. The full test suite was not repeated for this UI restoration; physical iPhone color-picker presentation remains to be checked. See [VALIDATION.md](VALIDATION.md).

**Read the [README warnings](README.md#before-using-this-app) before changing settings.** LED color 1 was physically set to blue with acknowledgement and matching readback. Other writes follow the protocol reference and matching Energy Mate formats but have not been exercised on the actual inverter. Battery values must follow manufacturer specifications. Local mode may pause Energy Mate cloud reporting.

Uploaded using `xcodebuild -exportArchive`. No public App Store release was submitted.

Verified at 2026-10-13T11:26:39Z. The local status snapshot is `testflight-status.json` (ignored by Git); release logs and the signed archive stay outside the source repository.
