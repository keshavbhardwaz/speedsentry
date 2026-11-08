# SpeedSentry

A small native macOS menu bar app that estimates your download speed every 10 minutes, alerts below 20 Mbps, and records incidents in India Standard Time. Built with Swift, AppKit and SwiftUI, with no third-party runtime dependencies.

Requires macOS 13 Ventura or later. Local builds use your Mac's architecture; release builds support Apple silicon and Intel.

## Build and run locally

Install Apple's Xcode Command Line Tools (`xcode-select --install`) or Xcode, then run:

```sh
make run
```

`make build` builds without launching. App builds need only Apple's Swift compiler and macOS SDK from current Command Line Tools. Running the XCTest suite separately with `make test` requires full Xcode; some CLT installations do not include XCTest.

The app is built at `dist/SpeedSentry.app`. It appears on the right side of the menu bar, with no Dock icon. macOS decides the exact position; hold **Command** and drag its menu bar item to reposition it.

For reliable login and notification behavior, quit the development copy, copy the app into `/Applications`, and launch that copy. Enable **Launch at Login** in the app only if you want it to start automatically. It is off by default. Keep one installed copy with the same bundle ID to avoid confusing macOS permission records.

The local build has an ad hoc signature for use on your own Mac. It is not the signed and notarized release needed for smooth public installation through Gatekeeper. The [release guide](docs/RELEASING.md) explains the public distribution pipeline.

## New in 0.2.0

- One-minute lightweight HTTPS connection checks with outage and recovery alerts.
- Opt-in **Smart Schedule**: hourly speed tests, with cooldown-limited checks on connection problems.
- **History & Daily Reports**: 24-hour/seven-day/30-day charts, IST daily statistics and text report export.
- **Network Profiles**: per-network thresholds and full-test pause; system-metered networks automatically block full tests. Select profiles manually when macOS hides Wi-Fi names.
- **Test Upload Now**: one explicit 4 MiB generated upload and a conservative whole-request estimate.
- Visible stale-result state, current network/profile and latest connection/upload status.
- Wi-Fi signal strength in dBm with a dashboard indicator and a large, dismissible weak-signal warning recommending moving closer or switching Wi-Fi networks. Alerts are configurable and avoid repeats until recovery.

Your existing schedule, threshold and history remain. Smart Schedule is off until you select it. See [network insights](docs/NETWORK-INSIGHTS.md) for limits, privacy and data use.

## What it does

- Shows the most recent download estimate in the menu bar; the menu includes its timestamp and the next check.
- Checks immediately when launched, then every 10 minutes while running and awake. A manual check is also available.
- Notifies when a measured download estimate is below 20 Mbps. Each low result is recorded; repeated low results in the same incident do not repeatedly notify. Recovery closes the incident.
- Records network failures separately from measured low speeds.
- Keeps samples and closed incidents locally for up to 90 days, with fixed record-count limits. Ongoing incidents remain until recovery is observed. Export history to CSV with explicit `Asia/Kolkata` timestamps (`+05:30`, IST), regardless of the Mac's selected time zone.
- Provides pause, threshold/interval controls, Low Data Mode, and an optional login item. There is no background daemon after you quit the app.

macOS must allow notifications for SpeedSentry. Focus modes and macOS notification preferences can suppress banners even when an incident is recorded. Open **System Settings → Notifications → SpeedSentry** if alerts are missing.

## Measurement and data use

**Default monitoring can use up to 72 MiB per check, about 10.9 GB/day at 10-minute intervals while continuously awake.** Enable **Low Data Mode** to use 8 MiB per check, about 1.2 GB/day, accepting that short bursts may overstate longer-term performance. Protocol overhead and manual checks add traffic.

In the default adaptive mode, a check starts with an 8 MiB HTTPS download from Cloudflare. If its validated elapsed time is under one second, the app downloads a 64 MiB confirmation using the same URLSession and reports that confirmation's throughput. Otherwise it reports the initial 8 MiB result. The initial and confirmation rates are not averaged. Low Data Mode skips the larger confirmation. The same session permits connection reuse, although the network stack controls whether a connection is reused.

Version 0.1.1 counts each complete payload without discarding warmup bytes. It prefers URLSession's transport response-start to response-end interval rather than timing data-delegate callbacks. Data can be buffered before callbacks arrive close together, which could inflate estimates in 0.1.0. A short transfer can also capture a real initial burst, so larger confirmation addresses a separate limitation. When transport metrics are absent, monotonic whole-request elapsed time includes setup/server delay for a conservative estimate. Invalid or incomplete checks are recorded as **unavailable**. See [measurement accuracy](docs/ACCURACY.md) for details.

Each request has a 30-second timeout; a check with confirmation may take up to about 60 seconds including setup delays. Cancellation aborts the whole check. History records total received traffic across both samples, while the reported confirmation speed uses only its 64 MiB payload and duration.

Each result estimates download throughput to one endpoint. The download result is separate from the lightweight HTTPS response check and explicit upload estimate. None guarantees sustained ISP capacity. Wi-Fi, routing, VPNs, server conditions, competing traffic, and transfer duration affect the result. Values are not capped at an assumed plan speed, and existing historical measurements remain unchanged. Full tests pause on system-metered networks or profiles marked to pause; increase the interval to save more data; cancellation cannot recall data already in flight.

Checks consume real bandwidth briefly and can affect other downloads. The app does not prevent sleep. It performs no checks while asleep and performs a fresh check after wake when the last result is stale. A drop that happens and recovers between checks may never be observed. History times mark detection, not the exact beginning of a connection problem.

## Privacy

History stays in `~/Library/Application Support/SpeedSentry/`; settings use macOS preferences for `app.speedsentry.mac`. No analytics or accounts are included. Cloudflare receives your public IP and ordinary HTTPS request metadata for speed and connection checks; Apple receives them when the connection fallback runs. Uploads contain only generated bytes. New connection/upload history uses a separate local `insights.json`; raw connection samples retain seven days. Exported CSVs are files you choose to save; keep them private if they reveal your work schedule.

## Homebrew distribution

The Homebrew formula builds version **0.1.1** from source on the installing Mac. Source lives in [`keshavbhardwaz/speedsentry`](https://github.com/keshavbhardwaz/speedsentry), with the formula in [`keshavbhardwaz/homebrew-tap`](https://github.com/keshavbhardwaz/homebrew-tap). Install and launch with:

```sh
brew install keshavbhardwaz/tap/speedsentry
speedsentry
```

The formula requires Swift 5.9 or later from current Apple Command Line Tools or Xcode. The app itself supports macOS 13+, while Homebrew's [current platform support](https://docs.brew.sh/Installation) has its own requirements.

The project also includes a cask generator and inactive signed universal release template for future precompiled distribution. See [publishing and Homebrew setup](docs/RELEASING.md).

## Development

```sh
make check                 # Script/plist validation and unit tests; requires full Xcode
make test                  # XCTest suite; requires full Xcode
make build                 # Native-architecture release app, ad hoc signature
make universal             # Apple silicon + Intel app, ad hoc signature
bash ./scripts/build-app.sh --configuration debug
bash scripts/validate-insights.sh       # Native local regressions, no XCTest required
bash scripts/validate-wifi-signal.sh    # Offline signal/alert lifecycle checks
bash scripts/validate-probe-accuracy.sh # Controlled loopback accuracy tests
```

The app build script uses `xcrun swiftc` directly and does not evaluate a SwiftPM manifest. `Package.swift` remains available for tests and IDE integration. `SpeedSentryCore` contains the measurement, incident, and persistence logic; the executable owns the menu bar, notifications, scheduling, and login integration. Tests use synthetic samples and local data, not live speed tests. See [manual verification](docs/TESTING.md) before a public release.

## Recommendations

Keep incident alerts tied to transitions to avoid a banner every 10 minutes during a long outage. Use this monitor to spot patterns; run a longer independent test when investigating ISP performance. Possible future additions include explicit daily data budgets and a signed in-app updater. Homebrew upgrades are the initial update path.

MIT licensed. See [LICENSE](LICENSE).
