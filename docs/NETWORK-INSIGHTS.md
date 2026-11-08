# Network insights (0.2.0)

The menu adds **History & Daily Reports**, **Test Upload Now (4 MiB)**, **Smart Schedule**, and **Network Profiles**.

## Scheduling and connection health

The existing ten-minute default remains. Smart Schedule is opt-in and runs a full download hourly, with an extra full check when two connection samples fail or HTTPS response time reaches 500 ms. Escalations have a ten-minute cooldown. Automatic full tests remain serialized with manual upload tests. The highest payload use in stable hourly accurate mode is approximately 1.8 GB/day awake continuously, before manual/escalated checks and overhead; fixed ten-minute accurate mode can use 10.9 GB/day. Low Data Mode uses 8 MiB per download check.

One connection check runs every minute while awake and unpaused, except during speed tests. It first requests Cloudflare's zero-byte download; if that fails, it tries Apple's small HTTPS success page. Each endpoint has a five-second total deadline and a 16 KiB response limit; redirects are rejected. The app never saves response bodies. Shown response time measures the successful whole HTTPS request including setup; this is not an ICMP ping, packet-loss measurement or jitter estimate. A fallback-provider latency is not directly comparable to a primary-provider latency.

Only two adjacent checks failing both providers open a connection outage. One successful check closes it. Notifications occur on transitions, subject to macOS permission/Focus. A gap over 150 seconds or interruption by pause/sleep/restart/network-profile change breaks continuity. Recorded durations are observation intervals, not proof of ISP responsibility or exact failure onset.

## Profiles

Profiles store a name, alert threshold and whether to pause full speed tests. macOS expensive/constrained network flags also block download and upload tests automatically. Connection checks continue. Wi-Fi SSIDs can match profiles when the OS exposes them without location permission. If no SSID is available, manually select the appropriate profile after switching networks; no location access is requested and the app cannot reliably distinguish two hidden-SSID Wi-Fi networks. Selecting Default clears the current SSID binding. Automatic SSID matches take precedence over the last manually selected fallback. Reports combine all networks; they do not attribute an outage to a particular ISP.

## Dashboard and reports

The dashboard shows 24-hour, seven-day and 30-day download sample plots. Failed tests have no Mbps point; an orange rule shows the current profile threshold, not the historical threshold of every sample. Daily reports use Asia/Kolkata boundaries even on Macs in other time zones. Reports include min/median/max, unavailable checks, observed incident and outage intervals clipped at midnight, reachable sample counts and download/upload payload traffic. Generate/select any retained day and export a plain-text report; existing CSV export is still available. Reports are generated locally on demand, with no scheduled popups or automatic sharing.

## Upload methodology and storage

Upload is explicitly on demand. A single 4 MiB generated payload is posted to Cloudflare. Only a complete successful 2xx request with matching bytes sent and valid monotonic elapsed time yields a rate. Whole-request elapsed time includes setup and server response, so this is a conservative request-level estimate; short bursts may still differ from sustained upload capacity. No personal files are uploaded.

The download history remains in `history.json` with its existing schema. New connection samples, outages and uploads use atomic `insights.json` beside it. Raw connection samples retain seven days (up to 10,100), outages 90 days (up to 10,000), uploads 90 days (up to 20,000). An active outage is preserved until recovery/interruption. Preferences/profiles remain in UserDefaults. Unreadable data is preserved; monitoring stops with an error. Exported reports may reveal your schedule and remain where you save them.

Provider API: [Cloudflare speedtest](https://github.com/cloudflare/speedtest) documents zero-byte latency requests and the upload endpoint. The app uses its own bounded Swift implementation and no third-party runtime.
