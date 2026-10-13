# Secure your inverter's network

This guide applies to both [iOS](https://github.com/talhabalaj/inverter-link) and [Android](https://github.com/talhabalaj/inverter-link-android).

> [!WARNING]
> **The tested logger's local protocol has no authentication or encryption.** Treat any device that can reach it as able to read data, redirect its callback and send settings commands. An Energy Mate account password, the app's review sheet, CRC checks and remembered logger IDs do not authenticate local commands. Network isolation reduces exposure; it does not fix this protocol.

## 1. Keep it off the public internet

Remove router port forwards and DMZ/exposed-host rules targeting the logger or the app's phone. Disable UPnP if you do not need it, check for existing automatic mappings, and turn off router administration from the WAN. Apply inbound restrictions to both IPv4 and IPv6 where enabled. Blocking unsolicited internet access is recommended by [CISA's home-router guidance](https://www.cisa.gov/sites/default/files/publications/HomeRouterSecurity2011.pdf) and [internet exposure guidance](https://www.cisa.gov/resources-tools/resources/exposure-reduction).

## 2. Use a dedicated, trusted Wi-Fi network

Prefer a separate SSID/VLAN containing the logger and only phones you trust to control it. Keep visitors and other untrusted IoT devices out. Use a unique Wi-Fi password and WPA3 Personal where every device supports it; otherwise use WPA2 Personal with AES. Avoid open networks, WEP and WPA/TKIP, and disable WPS after onboarding. Change default router administrator credentials and install supported router updates. [The FTC explains these Wi-Fi and router controls](https://consumer.ftc.gov/articles/how-secure-your-home-wi-fi-network).

Keep the phone and logger on the same private IPv4 subnet for this app's discovery. A router firewall generally does not filter traffic between peers on the same subnet: isolation must also be enforced by the AP/switch, or by separating devices into routed networks. Blanket guest/client isolation can block the logger's callback and prevent this app from working. Only enable it when you can explicitly permit the trusted phone/logger pair.

## 3. Allow only the communication you need

Where your network equipment can enforce device-level rules, allow the trusted phone/logger pair and deny other clients access to the logger. Reserve their addresses in DHCP to make rules predictable; an IP reservation is not authentication. [NIST describes limiting both local and internet IoT communications](https://www.nccoe.nist.gov/publication/1800-15/VolB/index.html).

| Direction | Required traffic |
| --- | --- |
| Phone → logger | UDP destination port **58899**, for discovery/callback requests |
| Logger → phone | UDP replies to the request's temporary source port; permit established reply traffic |
| Logger → phone | TCP destination port **8899**, for the local callback connection |

These directions come from the current [iOS transport](https://github.com/talhabalaj/inverter-link/blob/main/Sources/Transport.swift) and [Android transport](https://github.com/talhabalaj/inverter-link-android/blob/main/app/src/main/java/me/balaj/inverterlink/Transport.kt). They are LAN rules, **not instructions to forward these ports from the internet**. Both apps scan a `/24` or smaller subnet; manual entry does not bypass routing or firewall restrictions.

For local-only use, consider blocking the logger's internet access after checking your manufacturer's requirements. This stops cloud reporting and can prevent cloud-delivered updates. If you need cloud features, permit only manufacturer-confirmed destinations/services; this guide does not establish an Energy Mate cloud allowlist. Local mode itself may interrupt cloud reporting.

## 4. Verify the rules without changing settings

From the trusted phone, confirm discovery and monitoring work. Check that an untrusted client cannot reach the logger and that the router has no WAN mappings to the logger/phone. Verify the actual firewall/AP rules; a failed scan alone does not prove isolation. Repeat after network, address or firmware changes.

Use firmware only from the manufacturer for your exact inverter/logger revision. Similar white-label names do not establish compatibility. Ask the vendor about authenticated local control and security updates; this app does not provide a firmware fix.

> [!WARNING]
> **Network hardening does not make a setting safe for your battery or wiring.** Start with monitoring, follow manufacturer specifications, and read the [README cautions](README.md) before applying any change. Physical Android writes and non-LED setting writes remain unverified.

## Sharing logs or reporting a concern

Remove cloud credentials, Wi-Fi passwords, logger serial/identity, MAC addresses and personal network details from screenshots and logs before posting them publicly. Never attach signing keys or credential files. For a vulnerability involving real device identifiers or credentials, contact the manufacturer through its private support channel; avoid publishing working credentials or device-specific details in a public issue.
