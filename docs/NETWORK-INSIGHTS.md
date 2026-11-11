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

## Wi-Fi signal and prominent warnings

The menu and dashboard now show current Wi-Fi RSSI (dBm), a qualitative label and an approximate four-bar indicator. Signal strength is separate from download throughput; a healthy Wi-Fi signal does not guarantee a healthy internet connection. The app reads Apple's CoreWLAN interface every ten seconds while monitoring is awake and unpaused, including during full speed tests. These readings consume no internet test payload.

**Wi-Fi Signal Alerts** is on by default and can be disabled in the menu. Choose −70, −75 (default), or −80 dBm for the weak threshold. Two weak observations at least eight seconds apart, with no gap over 25 seconds, open one prominent floating warning window and request a normal macOS notification. The message recommends moving back into access-point coverage or switching to a stronger Wi-Fi network. The window shows the first observation in IST, can be dismissed, and never repeats during the same episode. It is a nonmodal, nonactivating panel, so monitoring continues and keyboard focus stays with the current app.

Two sustained readings at least 8 dBm above the selected weak threshold clear the episode and hide the warning. This hysteresis prevents repeated alerts near the threshold. A later weak episode may alert again. Pause, sleep, changing profile/network, Wi-Fi becoming inactive, or disabling alerts reset the episode. An unavailable reading breaks pending debounce and hides the panel; it does not count as recovery from an existing episode. The Mac's system notifications remain subject to permissions and Focus; the in-app panel works independently of notification permission.

Zero/invalid RSSI values are displayed as unavailable, never as a strong signal or a proven weak connection. RSSI can disappear when disconnected or when macOS does not expose the interface. Unknown/disconnected samples alone do not trigger weak-signal warnings; existing connection checks handle internet reachability. Quality labels and bars are app heuristics, not a calibrated percentage. No Wi-Fi scans, location prompts, router changes or automatic network switching are performed. The weak-signal warning lifecycle stays in memory. In 0.2.0, RSSI is not persisted; development builds record point-in-time signal values with the network context described below.

CoreWLAN reference: [Apple RSSI documentation](https://developer.apple.com/documentation/corewlan/cwinterface/rssivalue()).

## Incident network context (in development)

Download samples and lightweight connection samples capture the observed system path at the beginning of a check: Wi-Fi/Ethernet/cellular/other type, interface name (for example `en0`), SSID and valid RSSI where exposed, path availability, metered state, active profile and threshold. Incidents retain their start and recovery context. A path/SSID/profile change during a download invalidates that in-flight result instead of attaching it to the wrong network. Connection-outage continuity is interrupted at an observed network change; failures on two distinct networks cannot combine to create an outage.

The existing ten-second local signal timer also polls the SSID, because a Wi-Fi switch may leave the same interface and NWPath unchanged. Context changes are persisted in `insights.json`; ordinary signal fluctuations do not produce new change events. Changes retain 90 days with a 20,000-event cap. RSSI is a snapshot, not a continuous persisted signal trace. Pause/sleep/restart creates a fresh monitoring baseline on resume, without claiming to know what changed in the gap. Events are observations, so short switches between polls can be missed.

History & Daily Reports shows context beside recent speed incidents and connection outages, plus a separate IST network/profile timeline. Daily text reports include incident contexts and the day's changes (up to the most recent 100 entries per section). CSV appends context columns and `network_change` rows. Old JSON files load without backfilling unknown information; older entries show **Network context not recorded**. Additive optional fields preserve the original history schema.

SSID may be unavailable under macOS privacy restrictions, disconnection or API failure. The app does not request additional location permission, scan nearby networks or infer a name from a manually selected profile. A hidden SSID cannot reliably distinguish two Wi-Fi networks; access points sharing the same SSID/interface are not distinguished. NWPath describes observed routing possibilities, including tunnels or multiple interfaces, rather than verified routing of an individual test request. These details help correlate symptoms, not prove Wi-Fi or ISP responsibility.

Observed SSIDs/interface/profile names stay in local history and user-requested exports, never in speed-test payloads, analytics or Git. Redact exports before sharing them publicly.

Apple references: [SSID availability](https://developer.apple.com/documentation/corewlan/cwinterface/ssid()) and [NWPath interface semantics](https://developer.apple.com/documentation/network/nwpath).
