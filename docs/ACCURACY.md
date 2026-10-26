# How SpeedSentry estimates download throughput

Version 0.1.1 corrects transfer timing and adds adaptive confirmation to reduce the effect of short initial bursts. Defaults remain one check every 10 minutes and an alert below 20 Mbps. **Default mode can download up to 72 MiB per check, about 10.9 GB/day while continuously awake.** Low Data Mode uses 8 MiB per check, about 1.2 GB/day, with the limitations of a short sample. The app performs no upload test, latency test, or background traffic measurement.

## What changed

Version 0.1.0 discarded an initial 512 KiB warmup and timed later data-delegate callbacks. URLSession may buffer network data before scheduling those callbacks. Several callbacks can then arrive close together even though their bytes took longer to cross the network. Treating that brief delivery burst as transfer time can inflate the result. A callback is useful for counting delivered bytes; its arrival time does not establish when those bytes crossed the transport.

Version 0.1.1 counts each complete payload without subtracting warmup bytes. It prefers transport transaction timing and never calculates speed from gaps between data callbacks. That fixes callback-delivery bias, but a small transfer can still capture a real initial burst that exceeds longer-term throughput. The default adaptive confirmation addresses that separate sampling limitation. No 100 Mbps limit or other assumed ISP-plan ceiling is applied: a plan's advertised rate is not a measurement boundary. Existing history remains unchanged; earlier samples are not recalculated or removed.

## Adaptive confirmation and Low Data Mode

The default mode first requests 8 MiB. If the validated measurement interval is under one second, it requests a 64 MiB confirmation using the same URLSession. The displayed rate uses only the confirmation's complete payload and elapsed time. It does not combine the two rates or divide total downloaded bytes by the confirmation interval. If the initial interval is at least one second, the first result is retained and no confirmation is requested.

The one-second trigger corresponds to approximately 67.1 Mbps for an 8 MiB payload. It selects when to measure longer; it is not a maximum speed. Reusing the session permits connection reuse, but does not guarantee that the network stack will use the same transport connection. A failed confirmation cannot establish a valid longer-sample rate and should be handled as unavailable.

**Low Data Mode** stops after the initial 8 MiB result, even when it finishes quickly. It saves bandwidth while allowing real short bursts to affect the estimate more strongly. Choose it for a metered connection or when observing frequent low-speed incidents matters more than estimating faster sustained performance.

## The calculation

For a valid complete payload, the app calculates:

```text
estimated download Mbps = (payload bytes × 8) / elapsed seconds / 1,000,000
```

The initial payload is 8,388,608 bytes (67.108864 megabits); the larger confirmation is 67,108,864 bytes (536.870912 megabits). The selected sample's numerator and duration must match. The byte count is payload data delivered by URLSession, rather than HTTP headers or transport framing.

The recorded measurement's `bytesReceived` field serves a different purpose: it records total traffic received during the check, including the initial sample plus confirmation, or partial traffic before a failure. A completed adaptive check therefore records 72 MiB of received data even though its reported rate uses the 64 MiB confirmation alone. This preserves the history's usefulness for tracking the monitoring data budget.

When valid transport metrics are present, elapsed time is the matching response transaction's `responseEndDate - responseStartDate`. Apple's [responseStartDate](https://developer.apple.com/documentation/foundation/urlsessiontasktransactionmetrics/responsestartdate) marks receipt of the first response byte; [responseEndDate](https://developer.apple.com/documentation/foundation/urlsessiontasktransactionmetrics/responseenddate) marks receipt of the resource's last byte. The interval includes the response, rather than DNS, connection establishment, TLS setup, or time waiting for the first response byte.

Metrics and delivered data must describe the same complete, uncompressed network response. Apple's [countOfResponseBodyBytesAfterDecoding](https://developer.apple.com/documentation/foundation/urlsessiontasktransactionmetrics/countofresponsebodybytesafterdecoding) describes bytes delivered to the app. Its [countOfResponseBodyBytesReceived](https://developer.apple.com/documentation/foundation/urlsessiontasktransactionmetrics/countofresponsebodybytesreceived) can include protocol framing and encoding, so that transport count is not interchangeable with payload size.

If transport metrics are absent, elapsed time uses a monotonic clock from immediately before the request starts until it completes. This includes DNS, TCP/TLS setup, server wait, transfer, and callback scheduling where applicable. The same complete payload is divided by that longer interval, producing a conservative whole-request estimate. Missing metrics do not cause a return to callback-gap timing. Present but invalid metrics are rejected rather than hidden by a fallback.

## Rejected checks

A failed, timed-out, incomplete, oversized, compressed, cached, or inconsistent response cannot establish the intended throughput. Such checks return **unavailable**, with an error, rather than zero Mbps or a fabricated speed. Available timing must be finite and positive; available payload counts and response metadata must agree with the completed sample. Cached data must not be reported as internet throughput.

Each request has a 30-second timeout. An adaptive check can span two such requests and take up to about 60 seconds when connection setup or server delay consumes time. A transfer that cannot complete within its timeout yields unavailable rather than a numeric speed. A fast initial burst followed by a much slower connection can therefore produce an unavailable confirmation. A slower initial sample, such as a 15 Mbps transfer taking about 4.5 seconds for 8 MiB, does not trigger confirmation and retains its numeric result. Cancellation aborts the whole check, including any current or remaining confirmation work.

## Limits of a short sample

This estimates one path to one server at one moment. It does not determine a connection's sustained capacity or enforce an advertised subscription speed. A larger confirmation reduces the influence of short initial bursts, but its finite duration can still differ from a longer multi-connection benchmark. Low Data Mode retains the larger uncertainty of an 8 MiB sample. VPNs, proxies, Wi-Fi conditions, competing downloads, server load, and routing all matter.

At the default interval, 144 checks that each use 8 + 64 MiB transfer 10,871,635,968 payload bytes, about **10.9 GB/day** while continuously awake, plus protocol overhead. If confirmations are unnecessary, or Low Data Mode is enabled, 144 full 8 MiB checks use 1,207,959,552 payload bytes, about **1.2 GB/day**. Manual checks add traffic. Monitoring does not prevent sleep. Drops that begin and recover between checks can be missed; incident times are detection times.

## Verification scope

Regression verification should exercise buffered callback delivery independently of transport elapsed time; normal payload/timing calculation; missing-metrics fallback with setup delay; invalid timing; cached or compressed responses; byte-count mismatch and partial downloads; cancellation; and prevention of overlapping checks. Adaptive cases must also verify the one-second boundary, the 8 MiB/64 MiB request sizes, confirmation-only reporting, same-session follow-up, failure/cancellation between samples, and Low Data Mode. These cases validate calculation and policy without relying on an external internet connection.

The controlled 8 MiB timing regression below was recorded while isolating the callback bias, before adding adaptive confirmation. In the 100 Mbps case, the callback queue was deliberately stalled for 500 ms while the server continued its paced transfer. The legacy callback-based calculation then reported about 218 Mbps; corrected transport timing reported 99.93 Mbps against the approximately 100 Mbps server reference.

| Controlled case | Server transfer (Mbps) | Probe estimate (Mbps) |
| --- | ---: | ---: |
| Legacy timing, 100 Mbps target, delayed callbacks | 99.96 | 217.86 |
| 0.1.1, 100 Mbps target, delayed callbacks | 99.958 | 99.932 |
| 0.1.1, genuine 150 Mbps target | 149.936 | 149.871 |
| 0.1.1, 15 Mbps target | 14.994 | 14.993 |

The 150 Mbps case confirms that fixing callback timing does not require capping results at 100 Mbps. The 15 Mbps case preserves a below-threshold result. These measurements isolate the callback-delivery problem on loopback; they are not a guarantee about a user's ISP connection.

The repeatable local check is:

```sh
bash scripts/validate-probe-accuracy.sh
```

That script uses local TCP transfers without internet access. The table establishes the transport-timing correction; adaptive-policy results and full XCTest/CI outcomes must be assessed separately. No CI pass count is claimed here.

A live endpoint comparison, successful build, or controlled regression alone cannot establish accuracy across all ISPs, proxies, hardware, and network conditions. Compare the app with a controlled reference using the same payload and timing basis, then use a longer independent benchmark when investigating sustained capacity.

