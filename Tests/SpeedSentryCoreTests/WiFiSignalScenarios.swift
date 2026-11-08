import Foundation
#if canImport(SpeedSentryCore)
@testable import SpeedSentryCore
#endif

enum WiFiSignalScenarios {
    struct Failure: Error { let message: String }
    static func run() throws {
        var count = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw Failure(message: message) }
            count += 1; print("PASS \(message)")
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func reading(_ value: Int?, _ seconds: Double = 0, state: WiFiSignalState = .connected) -> WiFiSignalReading {
            WiFiSignalReading(timestamp: now.addingTimeInterval(seconds), state: state, rssiDBm: value)
        }
        try expect(reading(-50).quality == "Excellent" && reading(-50).bars == 4, "strong signal has four bars")
        try expect(reading(-60).quality == "Good" && reading(-60).bars == 3, "good signal has three bars")
        try expect(reading(-70).quality == "Fair" && reading(-70).bars == 2, "fair signal has two bars")
        try expect(reading(-75).quality == "Weak" && reading(-75).bars == 1, "weak boundary is labelled correctly")
        try expect(reading(-90).quality == "Very weak" && reading(-90).bars == 0, "very weak signal still has numeric RSSI")
        for invalid in [0, 20, -121, Int.min, Int.max] {
            try expect(reading(invalid).state == .unavailable && reading(invalid).rssiDBm == nil, "invalid RSSI \(invalid) stays unavailable")
        }
        try expect(reading(-50, state: .notUsingWiFi).rssiDBm == nil, "Ethernet has no fabricated Wi-Fi signal")
        var policy = WiFiSignalPolicy()
        try expect(policy.observe(reading(-80), networkID: "home") == nil, "one weak reading does not alert")
        try expect(policy.observe(reading(-82, 1), networkID: "home") == nil, "rapid repeated menu opens cannot trigger alert")
        let started = policy.observe(reading(-82, 10), networkID: "home")
        guard case .started(let episode) = started else { throw Failure(message: "sustained weak signal did not alert") }
        try expect(episode.startedAt == now && episode.rssiDBm == -82, "warning records first weak observation")
        try expect(policy.observe(reading(-85, 20), networkID: "home") == nil && policy.activeEpisode?.id == episode.id, "ongoing weakness never repeats alert")
        _ = policy.observe(reading(-73, 30), networkID: "home")
        try expect(policy.activeEpisode != nil, "borderline bounce does not clear alert")
        try expect(policy.observe(reading(-67, 40), networkID: "home") == nil, "one good reading does not clear warning")
        try expect(policy.observe(reading(-67, 50), networkID: "home") == .recovered && policy.activeEpisode == nil, "two sustained readings at recovery boundary clear warning")
        _ = policy.observe(reading(-75, 60), networkID: "home")
        guard case .started(let second) = policy.observe(reading(-75, 70), networkID: "home") else { throw Failure(message: "new episode not detected") }
        try expect(second.id != episode.id, "weak signal after recovery opens new episode")
        _ = policy.observe(reading(0, 80), networkID: "home")
        try expect(policy.activeEpisode?.id == second.id, "unavailable data cannot claim recovery or reopen warning")
        try expect(policy.observe(reading(-80, 90), networkID: "home") == nil, "valid weak reading after unknown does not repeat warning")
        _ = policy.observe(reading(nil, 100, state: .notUsingWiFi), networkID: "wired")
        try expect(policy.activeEpisode == nil, "switching to Ethernet resets Wi-Fi warning")
        _ = policy.observe(reading(-80, 110), networkID: "home")
        try expect(policy.observe(reading(-80, 140), networkID: "home") == nil, "monitoring gap cannot join two isolated weak samples")
        _ = policy.observe(reading(-50, 150), networkID: "home")
        _ = policy.observe(reading(-80, 160), networkID: "home")
        try expect(policy.observe(reading(-80, 170), networkID: "office") == nil, "different Wi-Fi networks do not share debounce samples")
        policy.reset()
        try expect(policy.activeEpisode == nil, "pause or disabled alerts reset episode")
        _ = policy.observe(reading(-80, 180), networkID: "home")
        _ = policy.observe(reading(-50, 190), networkID: "home")
        try expect(policy.observe(reading(-80, 200), networkID: "home") == nil, "one good sample interrupts pending weak alert")
        _ = policy.observe(reading(-80, 210), networkID: "home")
        _ = policy.observe(reading(-60, 220), networkID: "home")
        _ = policy.observe(reading(-70, 230), networkID: "home")
        try expect(policy.observe(reading(-60, 240), networkID: "home") == nil && policy.activeEpisode != nil, "recovery debounce resets on borderline reading")
        _ = policy.observe(reading(nil, 250, state: .paused), networkID: "home")
        try expect(policy.activeEpisode == nil, "sleep or pause clears warning")
        var sensitive = WiFiSignalPolicy(weakThresholdDBm: -70)
        _ = sensitive.observe(reading(-70), networkID: "home")
        try expect(sensitive.observe(reading(-70, 10), networkID: "home") != nil && sensitive.recoveryThresholdDBm == -62, "custom threshold uses corresponding hysteresis")
        try expect(WiFiSignalPolicy(weakThresholdDBm: 0).weakThresholdDBm == -75, "invalid preference uses safe default")
        print("All \(count) Wi-Fi signal checks passed.")
    }
}
