# SpeedSentry

A lightweight native macOS menu bar app that checks download speed every 10 minutes, alerts below 20 Mbps, and records incidents in India Standard Time.

## Install with Homebrew

```sh
brew install keshavbhardwaz/tap/speedsentry
speedsentry
```

Requires macOS 13+ and Apple Xcode Command Line Tools with Swift 5.9+. Homebrew compiles the app locally for Apple silicon or Intel. Enable notifications when macOS asks. Launch at Login is optional and off by default.

## Features

- Current download estimate in the right-side menu bar, with manual checks and pause/resume.
- Configurable interval and alert threshold; defaults are 10 minutes and 20 Mbps.
- One alert per incident, with recovery recorded and repeated low samples retained.
- Local history, recent incidents, and CSV export using explicit IST / Asia/Kolkata timestamps.
- No browser runtime, third-party runtime dependencies, analytics, or account.

macOS chooses exact menu bar placement. Hold Command and drag the item to reposition it.

## Source and development

This initial repository distributes the project as a complete source package. Download **SpeedSentry-0.1.0-source.zip** from [Releases](https://github.com/keshavbhardwaz/speedsentry/releases/tag/v0.1.0), then extract it. The ZIP contains the Swift package, app/core sources, tests, icon, build scripts, CI/release workflow templates, and full documentation.

```sh
unzip SpeedSentry-0.1.0-source.zip
cd SpeedSentry
make run
```

App builds need only Apple's command-line Swift compiler. `make test` uses XCTest and requires full Xcode. The GitHub-generated source-code archives contain this packaging repository; use the explicitly named source ZIP for development.

## Measurement and privacy

Each check streams up to 8 MiB from Cloudflare, excluding warmup bytes from its estimate. At 10-minute intervals this uses about **1.2 GB/day** if the Mac stays awake continuously. Pause on metered connections or increase the interval. No checks run during sleep; stale samples refresh after wake.

This is a small, single-connection download estimate. Brief drops between checks may be missed. Failed or timed-out probes are recorded as unavailable, not fabricated as zero speed. Very slow connections may hit the 30-second limit.

History stays at `~/Library/Application Support/SpeedSentry/`; display/export times use IST regardless of system timezone. Cloudflare receives your public IP and normal request metadata. Samples and closed incidents are retained for up to 90 days; active incidents remain until recovery.

## Validation and distribution

Nineteen deterministic test cases passed through a local assertion runner. A real 8 MiB probe passed, the universal app compiled, and its local signature verified. Runtime testing was on Apple silicon; full XCTest execution and Intel/macOS 13 hardware testing remain outstanding.

The initial Homebrew formula builds locally with an ad hoc signature. Precompiled Developer ID signed/notarized cask distribution is prepared in the source project's release templates and requires Apple signing credentials.

MIT licensed. See [LICENSE](LICENSE).
