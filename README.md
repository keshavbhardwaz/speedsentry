# SpeedSentry

A small native macOS menu bar app that estimates your download speed every 10 minutes, alerts below 20 Mbps, and records incidents in India Standard Time. Built with Swift and AppKit, with no third-party runtime dependencies.

Requires macOS 13 Ventura or later. Local builds use your Mac's architecture; release builds support Apple silicon and Intel.

## Build and run locally

Install Apple's Xcode Command Line Tools (`xcode-select --install`) or Xcode, then run:

```sh
make test
make run
```

The app is built at `dist/SpeedSentry.app`. It appears on the right side of the menu bar, with no Dock icon. macOS decides the exact position; hold **Command** and drag its menu bar item to reposition it.

For reliable login and notification behavior, quit the development copy, copy the app into `/Applications`, and launch that copy. Enable **Launch at Login** in the app only if you want it to start automatically. It is off by default. Keep one installed copy with the same bundle ID to avoid confusing macOS permission records.

The local build has an ad hoc signature for use on your own Mac. It is not the signed and notarized release needed for smooth public installation through Gatekeeper. The [release guide](docs/RELEASING.md) explains the public distribution pipeline.

## What it does

- Shows the most recent download estimate in the menu bar; the menu includes its timestamp and the next check.
- Checks immediately when launched, then every 10 minutes while running and awake. A manual check is also available.
- Notifies when a measured download estimate is below 20 Mbps. Each low result is recorded; repeated low results in the same incident do not repeatedly notify. Recovery closes the incident.
- Records network failures separately from measured low speeds.
- Keeps samples and closed incidents locally for up to 90 days, with fixed record-count limits. Ongoing incidents remain until recovery is observed. Export history to CSV with explicit `Asia/Kolkata` timestamps (`+05:30`, IST), regardless of the Mac's selected time zone.
- Provides pause, threshold/interval controls, and an optional login item. There is no background daemon after you quit the app.

macOS must allow notifications for SpeedSentry. Focus modes and macOS notification preferences can suppress banners even when an incident is recorded. Open **System Settings → Notifications → SpeedSentry** if alerts are missing.

## Measurement and data use

SpeedSentry makes one HTTPS request to Cloudflare's speed-test download endpoint per check. It streams a sample capped at 8 MiB and omits the first 512 KiB from the timed estimate. It does not keep the downloaded payload. Each result estimates throughput to that endpoint, influenced by Wi-Fi, routing, VPNs, server conditions, and test duration. It is not a certified ISP benchmark or an upload/latency test.

A sample must finish within 30 seconds. Extremely slow connections (roughly below 2.24 Mbps, and potentially higher with connection overhead) can time out before the full sample finishes. These are recorded and alerted as **unavailable**, rather than assigned an inaccurate numeric speed.

At 10-minute intervals, 144 full 8 MiB samples use about **1.2 GB per 24 hours** while continuously awake, plus small protocol overhead. Manual checks add traffic. A full-buffer transfer can already be in flight when cancellation takes effect. Pause monitoring on a metered connection or increase the interval.

Checks consume real bandwidth briefly and can affect other downloads. The app does not prevent sleep. It performs no checks while asleep and performs a fresh check after wake when the last result is stale. A drop that happens and recovers between checks may never be observed. History times mark detection, not the exact beginning of a connection problem.

## Privacy

History stays in `~/Library/Application Support/SpeedSentry/`; settings use macOS preferences for `app.speedsentry.mac`. No analytics or accounts are included. Cloudflare receives your public IP address and ordinary HTTPS request metadata when a speed sample runs. Exported CSVs are files you choose to save; keep them private if they reveal your work schedule.

## Homebrew distribution

The Homebrew formula builds version **0.1.0** from source on the installing Mac. Source lives in [`keshavbhardwaz/speedsentry`](https://github.com/keshavbhardwaz/speedsentry), with the formula in [`keshavbhardwaz/homebrew-tap`](https://github.com/keshavbhardwaz/homebrew-tap). Install and launch with:

```sh
brew install keshavbhardwaz/tap/speedsentry
speedsentry
```

The formula requires Swift 5.9 or later from current Apple Command Line Tools or Xcode. The app itself supports macOS 13+, while Homebrew's [current platform support](https://docs.brew.sh/Installation) has its own requirements.

The project also includes a cask generator and signed universal release workflow for future precompiled distribution. See [publishing and Homebrew setup](docs/RELEASING.md).

## Development

```sh
make check                 # Script/plist validation and unit tests
make build                 # Native-architecture release app, ad hoc signature
make universal             # Apple silicon + Intel app, ad hoc signature
bash ./scripts/build-app.sh --configuration debug
```

`SpeedSentryCore` contains the measurement, incident, and persistence logic; the executable target owns the menu bar, notifications, scheduling, and login integration. Tests use synthetic samples and local data, not live speed tests. See [manual verification](docs/TESTING.md) before a public release.

## Recommendations

Keep incident alerts tied to transitions to avoid a banner every 10 minutes during a long outage. Use this monitor to spot patterns; run a longer independent test when investigating ISP performance. A future release could add Wi-Fi-only/metered-network rules, optional latency checks, configurable data budgets, and a signed in-app updater. Homebrew upgrades are the initial update path.

MIT licensed. See [LICENSE](LICENSE).
