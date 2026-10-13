# Validation

## Scope

Version 0.1.0, build 20261013.9. Native iOS app, local PI30 transport and 37 mapped settings. The signed distribution archive excludes the DEBUG-only preview fixture.

## Automated checks

Build 20261013.8 Release test baseline: **25 passed, 0 failed, 0 skipped**, with no runtime warnings. Build 20261013.9 restores only the color-picker UI; its signed Release archive, app/widget version checks and signatures passed. The full test suite was not repeated for this UI restoration.

25 tests cover CRCs and fixed queries, malformed inputs, fragmentation and pinned reply routing, charging choices and setting command validation, cancellation, real loopback UDP/TCP exchanges, a full mock logger handshake and keepalive, hostname validation, saved-device migration, names and addresses, default/appearance preference persistence, forgetting one device, Live Activity/scene lifecycle and the SwiftUI-hosted 3D rendering regression.

The release test harness uses `ENABLE_TESTABILITY=YES ONLY_ACTIVE_ARCH=YES`; the distribution archive uses normal Release signing and optimization. No test sends a physical inverter write.

## UI walkthrough

Checked in the iPhone 18 Pro simulator for build 20261013.8:

- Compact Devices list with two root tabs; named device row opens a dashboard without a tab bar.
- Inverter settings and diagnostics are under the dashboard's Details disclosure.
- Native grouped settings and App Settings; SF-symbol dismissal/confirmation controls.
- LED presets update the preview and hex value; unchanged values disable Review; changed values open a separate current/new sheet.
- Purple accent selection updates UI controls, status/metric highlights and navigation. Preference persists across launch.
- Enabling default launch opens the saved sample inverter's dashboard on the next launch.
- Disconnecting the sample device clears live data. The settings view shows one offline message and no category selector.

These UI checks use a clearly labeled DEBUG fixture with isolated preferences. It blocks network queries and setting writes. Earlier in this session, the actual logger connected and all six settings queries populated the original settings UI. After the test run, the actual logger acknowledged callback requests but did not reconnect; the new navigation was therefore checked with sample data.

## Physical evidence and remaining limits

The real inverter supplied PI30 status and settings responses. LED color 1 was set to blue and verified with ACK plus matching QLED readback. Other setting writes are implemented and validated from the documented formats but have not been physically sent. iPhone rendering, physical Local Network permission handling, actual DHCP/DNS changes and every non-LED setting write still require device verification.

Build 20261013.9 restores the native color picker alongside presets and RGB hex input. The simulator previously failed to present Apple’s color-picker service reliably; physical-device presentation remains to be verified.

See README warnings before using the app. Cloud-destination restoration after local takeover remains unverified; background monitoring is constrained by iOS suspension.
