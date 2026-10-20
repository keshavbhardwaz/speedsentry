# Verification before release

Automated tests cover deterministic logic and persistence; they do not prove real-world bandwidth accuracy, sleep behavior, notification permission, or Developer ID distribution. Perform these checks on macOS 13 or later before publishing.

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

## Troubleshooting

**No banner:** Check System Settings → Notifications → SpeedSentry, Focus, and notification delivery settings. The incident log still records low samples even if permission is denied.

**No menu bar item:** On a small/notched display, macOS can hide items when space is limited. Quit another menu bar utility temporarily, or Command-drag items to free space.

**Unexpected speed:** Compare under idle network conditions. This small single-stream sample measures the path to Cloudflare and can under-read a fast connection or a long-latency link. VPNs and concurrent traffic change the result.

**Login item unavailable:** Run the app bundle from a stable installed location, preferably `/Applications`. Check macOS Login Items for an approval request. Launch at login is user-controlled and off by default.

**Gatekeeper rejects a downloaded development ZIP:** Use a properly Developer ID signed and notarized release. Local ad hoc builds are for development on the building Mac.
