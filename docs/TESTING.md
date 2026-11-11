# Verification before release

Automated tests cover deterministic logic and persistence; they do not prove real-world bandwidth accuracy, sleep behavior, notification permission, or Developer ID distribution. Running `make test` or `make check` needs full Xcode with XCTest; app builds through `make build` need only current Command Line Tools. Perform these checks on macOS 13 or later before publishing.

1. Run `make check` and `make universal`. Verify `lipo -archs dist/SpeedSentry.app/Contents/MacOS/SpeedSentry` contains `arm64 x86_64`.
2. Launch one copy of the app. Verify it appears in the menu bar without a Dock icon and that its menu shows a completed sample, sample age, and next check.
3. With notifications allowed, set a threshold above your measured speed and run a check. Verify one low-speed alert and a timestamped incident. Repeat the check while low; verify the sample history updates without repeated alert banners. Lower the threshold, check again, and verify recovery. Restore **20 Mbps** afterward.
4. Turn Wi-Fi off and check. Confirm the app shows a failed/offline state rather than inventing a speed value. Reconnect, run a successful check, and confirm recovery.
5. Export incidents. Confirm the CSV explicitly uses `+05:30`/IST even after changing the Mac's time zone. Check exported fields with a CSV reader.
6. Quit and reopen. Verify retained history and settings. Check history and preferences are written only to the documented local paths.
7. Pause monitoring. Verify no scheduled request runs; resume and verify a fresh check. Sleep the Mac, wait beyond the interval, wake it, and verify a fresh stale-result check without a backlog of queued tests.
8. Copy the app into `/Applications`, enable **Launch at Login**, and check **System Settings → General → Login Items**. Log out/in to confirm it launches once. Disable the toggle and verify it no longer launches.
9. Check on both Apple silicon and an Intel Mac. A universal binary build alone does not replace testing both hardware families.
10. For public distribution, extract the exact downloaded release ZIP on a clean Mac and run `codesign --verify --strict --verbose=2`, `xcrun stapler validate`, and `spctl --assess --type execute --verbose=2` against the app. Test the qualified Homebrew cask installation and removal. Do not use quarantine-removal commands to mask distribution issues.

For the 0.1.1 accuracy patch, use the [measurement methodology and verification scope](ACCURACY.md) when reviewing buffered delivery, transport timing, missing-metrics fallback, and invalid responses. Verify that a fast initial sample triggers one 64 MiB confirmation, that only the confirmation's rate is reported, and that Low Data Mode performs only the initial 8 MiB sample. Check the visible data-use disclosure: default mode uses up to 72 MiB per check (about 10.9 GB/day), while Low Data Mode uses 8 MiB (about 1.2 GB/day). Historical samples from earlier versions remain unchanged.

## Troubleshooting

**No banner:** Check System Settings → Notifications → SpeedSentry, Focus, and notification delivery settings. The incident log still records low samples even if permission is denied.

**No menu bar item:** On a small/notched display, macOS can hide items when space is limited. Quit another menu bar utility temporarily, or Command-drag items to free space.

**Unexpected speed:** Check the app version and whether Low Data Mode is enabled. Version 0.1.1 replaces callback-gap timing and uses a larger confirmation after fast initial samples in the default mode. Low Data Mode retains the uncertainty of a short 8 MiB sample. Compare under idle network conditions. The conservative whole-request fallback includes connection/server delay. VPNs, concurrent traffic, and short bursts change the result. A longer independent benchmark is useful for sustained performance; a fixed plan-speed cap would not correct the measurement.

**Login item unavailable:** Run the app bundle from a stable installed location, preferably `/Applications`. Check macOS Login Items for an approval request. Launch at login is user-controlled and off by default.

**Gatekeeper rejects a downloaded development ZIP:** Use a properly Developer ID signed and notarized release. Local ad hoc builds are for development on the building Mac.

## 0.2.0 network insights

On a Command Line Tools-only Mac, run `bash scripts/validate-insights.sh` and `bash scripts/validate-probe-accuracy.sh`. These compile real native regression executables, require no XCTest shim, write only temporary data, and do not contact the internet. The paced accuracy suite needs permission to bind a loopback socket. `InsightsScenarios.swift` also runs unchanged through XCTest on CI.

For optional live checks (4 MiB generated upload, no personal files), compile `Sources/SpeedSentryCore/*.swift` with `scripts/LiveProbeCheck.swift` using `swiftc -parse-as-library`, then run the executable. Results depend on your network; upload uses whole-request elapsed time and can reflect short ISP bursts.

Manual UI checks:

- Launch with `--preview`: synthetic seven-day download history, no monitoring, preferences, notifications or real history writes. Open History & Daily Reports, switch 24 hours / seven / 30 days, select a report day and export a text report. Preview report exports are synthetic.
- Smart Schedule is opt-in. Check that it changes the next speed check to hourly and retains one-minute connection checks. Restore fixed schedule to preserve your existing interval.
- Set up two profiles, switch manually, check their effective thresholds. macOS may conceal SSIDs; no location access is requested. Known SSID matches override manual fallback. Default clears the current SSID binding. Check profile pause and metered/Low Data system-network flags block download and upload while connection checks continue.
- Check upload blocks overlapping full tests and displays/stores its result. Pause, sleep or change profile during a transfer; cancelled results must not be logged against the next network.
- Two consecutive failed connection checks (each trying both providers) open one alert. Repeated failures do not repeat it; one success recovers. Pause, sleep, restart or a gap over 150 seconds breaks outage continuity. A single provider failure must not declare an outage. The shown latency includes DNS/TLS/server time; it is not ICMP ping.
- Inspect old `history.json` after upgrading. Its schema and existing records remain intact. New records use separate `insights.json`. A corrupt insights file must be preserved, with monitoring stopped and an error visible until restart/recovery.
- Confirm stale download results receive a dot in the menu bar and an explicit menu/tooltip label. Full checks never prevent sleep.

Local validation does not substitute for Intel hardware, notification delivery under Focus, login-item behavior after logout, or long-duration sleep/network-switch testing.

## Wi-Fi signal verification

Run `bash scripts/validate-wifi-signal.sh` for native, offline policy checks on a CLT-only Mac. The same scenarios run under XCTest in CI. Coverage includes RSSI quality boundaries, zero/invalid values, sustained weak observations, rapid menu polling, recovery hysteresis, interrupted observations, unavailable data, network changes and reset/threshold preferences.

Verify on a Wi-Fi-connected Mac that the menu/dashboard show dBm and a checked-at IST timestamp. No radio scan or internet payload is required. Use a synthetic preview to inspect the large warning and Dismiss action without moving/disconnecting the user's real network. In real use, a threshold crossing should show one nonactivating floating warning with the move-closer/switch-network message; dismissal must not reopen it until sustained recovery followed by a new weak episode. Recovery, pause, sleep and disabling alerts hide the warning. Metered/profile pauses block speed tests but keep signal monitoring active; the global Pause Monitoring option stops both.

## Incident network context (development)

Run `bash scripts/validate-network-context.sh`. Synthetic fixtures cover SSID changes on one interface, Wi-Fi/Ethernet and interface-name changes, hidden names, invalid signal, context snapshots, non-repeating RSSI updates, sleep/pause/restart baselines, legacy JSON decoding, atomic-write failure/retry, outage continuity across switches, IST reports, CSV and retention. XCTest runs these same scenarios in CI.

The `--preview` dashboard includes a synthetic incident on **Demo — Upstairs**, a switch to **Demo — Office**, and recovery with both contexts visible. Preview never reads/writes real monitoring history or changes the Mac's Wi-Fi. Verify that start/recovery context, intermediate event, interface, RSSI and IST times are legible, and that exported synthetic reports contain those names.

On a separate manual test, switch between two known Wi-Fi networks and then Ethernet. Confirm the timeline follows observations, one in-flight download is cancelled rather than attributed to the next network, and two failed connection checks across a switch do not open one outage. With SSID hidden, confirm the UI says unavailable and does not substitute a manual profile's name. Pause/sleep, change networks and resume; the first new entry must be a baseline rather than a claim about changes during the gap. Check that ordinary RSSI changes do not grow the event timeline. This physical roaming/sleep test still requires user hardware access and is separate from the synthetic regression run.
