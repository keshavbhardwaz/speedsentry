import Foundation
#if canImport(SpeedSentryCore)
@testable import SpeedSentryCore
#endif

/// Shared by XCTest and the native CLT runner. Uses synthetic Wi-Fi names only.
enum NetworkContextScenarios {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func run() throws {
        var count = 0
        func expect(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try condition() else { throw Failure(description: label) }
            count += 1; print("PASS \(label)")
        }
        let now = ISO8601DateFormatter().date(from: "2026-11-10T19:00:00Z")!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let distant = NetworkContext(kind: .wifi, interfaceName: "en0", ssid: "Fixture Upstairs", rssiDBm: -82)
        let nearby = NetworkContext(kind: .wifi, interfaceName: "en0", ssid: "Fixture Office", rssiDBm: -48)
        let ethernet = NetworkContext(kind: .ethernet, interfaceName: "en5", ssid: "Should be removed", rssiDBm: -50)
        let hidden = NetworkContext(kind: .wifi, interfaceName: "en0", profileName: "Manual home profile")
        try expect(hidden.ssid == nil && hidden.summary.contains("SSID: unavailable"), "manual profile never fabricates a hidden SSID")
        try expect(ethernet.ssid == nil && ethernet.rssiDBm == nil, "Ethernet never retains previous Wi-Fi data")
        try expect(NetworkContext(kind: .wifi, interfaceName: "en0", rssiDBm: 0).rssiDBm == nil, "invalid signal stays unavailable")
        try expect(!distant.hasSameIdentity(as: nearby), "SSID change detected on the same interface")
        try expect(!nearby.hasSameIdentity(as: ethernet), "Wi-Fi to Ethernet switch detected")
        try expect(!ethernet.hasSameIdentity(as: NetworkContext(kind: .ethernet, interfaceName: "en6")), "same transport with different interface detected")
        try expect(!nearby.hasSameIdentity(as: hidden), "loss of SSID visibility is recorded honestly")
        try expect(!nearby.hasSameIdentity(as: NetworkContext(kind: .wifi, interfaceName: "en0", ssid: "Fixture Office", thresholdMbps: 50)),
            "threshold change creates a policy-context event")
        try expect(!nearby.hasSameIdentity(as: NetworkContext(kind: .wifi, interfaceName: "en0", ssid: "Fixture Office", metered: true)),
            "metered-state change is part of network context")

        let insights = try InsightsStore(directoryURL: root, now: { now })
        try expect(try insights.observeNetwork(distant, at: now.addingTimeInterval(-120)), "first observation records a baseline")
        let shiftedRSSI = NetworkContext(kind: .wifi, interfaceName: "en0", ssid: "Fixture Upstairs", rssiDBm: -80)
        try expect(!(try insights.observeNetwork(shiftedRSSI, at: now.addingTimeInterval(-110))) && insights.snapshot.networkChanges.count == 1,
            "RSSI changes do not flood the timeline")
        try expect(try insights.observeNetwork(nearby, at: now.addingTimeInterval(-60)), "network switch creates one event")
        try expect(insights.snapshot.networkChanges.last?.previous == shiftedRSSI, "switch keeps latest previous signal and new context")
        let restored = try InsightsStore(directoryURL: root, now: { now })
        try expect(restored.snapshot.networkChanges == insights.snapshot.networkChanges, "network timeline survives restart")
        _ = try restored.observeNetwork(ethernet, at: now)
        try expect(restored.snapshot.networkChanges.last?.previous == nil, "restart records baseline without inventing an unobserved switch")
        restored.resetNetworkObservation()
        _ = try restored.observeNetwork(nearby, at: now.addingTimeInterval(10))
        try expect(restored.snapshot.networkChanges.last?.previous == nil, "resume after pause or sleep records a new baseline")

        let history = try HistoryStore(directoryURL: root, now: { now })
        let start = now.addingTimeInterval(-120), end = now.addingTimeInterval(-30)
        _ = try history.record(Measurement(timestamp: start, megabitsPerSecond: 12, bytesReceived: 100,
            errorDescription: nil, networkContext: distant), thresholdMbps: 20)
        _ = try history.record(Measurement(timestamp: end, megabitsPerSecond: 90, bytesReceived: 100,
            errorDescription: nil, networkContext: nearby), thresholdMbps: 20)
        try expect(history.incidents.first?.startNetworkContext == distant && history.incidents.first?.endNetworkContext == nearby,
            "incident preserves distinct start and recovery contexts")
        let reloadedHistory = try HistoryStore(directoryURL: root, now: { now })
        try expect(reloadedHistory.history == history.history, "sample and incident contexts survive JSON round trip")
        let csvURL = root.appendingPathComponent("export.csv")
        try history.exportCSV(to: csvURL, networkChanges: insights.snapshot.networkChanges)
        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        try expect(csv.contains("network_change") && csv.contains("Fixture Upstairs") && csv.contains("Fixture Office") && csv.contains("en0"),
            "CSV exports incident context and intermediate network changes")
        let report = DailyReport(day: now, history: history.history, insights: insights.snapshot, now: now)
        try expect(report.text.contains("2026-11-11 00:28:00 IST") && report.text.contains("Fixture Upstairs") && report.text.contains("Fixture Office"),
            "IST daily report includes incident contexts and network timeline")
        try expect(report.text.contains("does not prove an ISP fault") && report.text.contains("redact"), "report explains causality and sharing limits")

        let legacyDir = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let date = ISO8601DateFormatter().string(from: now)
        let legacy = """
        {"schemaVersion":1,"measurements":[{"timestamp":"\(date)","megabitsPerSecond":10,"bytesReceived":10}],
         "incidents":[{"id":"11111111-1111-1111-1111-111111111111","startedAt":"\(date)","lowestMbps":10,"thresholdMbps":20,"kind":"slow"}]}
        """
        try Data(legacy.utf8).write(to: legacyDir.appendingPathComponent("history.json"))
        let legacyInsights = """
        {"connections":[{"timestamp":"\(date)","reachable":false}],
         "outages":[{"id":"22222222-2222-2222-2222-222222222222","startedAt":"\(date)","endedAt":"\(date)","interrupted":true}],"uploads":[]}
        """
        try Data(legacyInsights.utf8).write(to: legacyDir.appendingPathComponent("insights.json"))
        let oldHistory = try HistoryStore(directoryURL: legacyDir, now: { now })
        let oldInsights = try InsightsStore(directoryURL: legacyDir, now: { now })
        try expect(oldHistory.incidents.count == 1 && oldHistory.incidents[0].startNetworkContext == nil,
            "0.2.0 incident history loads without migration or invented context")
        try expect(oldInsights.snapshot.networkChanges.isEmpty, "0.2.0 insights loads with an empty network timeline")
        try expect(oldInsights.snapshot.connections[0].networkContext == nil && oldInsights.snapshot.outages[0].startNetworkContext == nil,
            "legacy connection samples and outages decode without context")

        let outageStore = try InsightsStore(directoryURL: root.appendingPathComponent("outages"), now: { now })
        func failed(_ offset: Double, _ context: NetworkContext) -> ConnectionSample {
            ConnectionSample(timestamp: now.addingTimeInterval(offset), latencyMilliseconds: nil, reachable: false, networkContext: context)
        }
        _ = try outageStore.record(failed(-120, distant)); _ = try outageStore.record(failed(-60, nearby))
        try expect(outageStore.snapshot.outages.isEmpty, "failed checks on different SSIDs never combine into one outage")
        _ = try outageStore.record(failed(0, nearby))
        try expect(outageStore.snapshot.outages.first?.startNetworkContext == nearby, "outage starts with context of the first adjacent failure")
        _ = try outageStore.record(ConnectionSample(timestamp: now.addingTimeInterval(60), latencyMilliseconds: 50, reachable: true, networkContext: ethernet))
        try expect(outageStore.snapshot.outages.first?.interrupted == true && outageStore.snapshot.outages.first?.endedAt == now,
            "interface switch interrupts observation instead of claiming recovery on old network")
        try expect(outageStore.snapshot.outages.first?.endNetworkContext == nearby, "interrupted outage retains last observed network")

        let atomicDir = root.appendingPathComponent("atomic")
        let atomic = try InsightsStore(directoryURL: atomicDir, now: { now })
        try FileManager.default.createDirectory(at: atomicDir.appendingPathComponent("insights.json"), withIntermediateDirectories: false)
        do { _ = try atomic.observeNetwork(distant, at: now); throw Failure(description: "Failed write accepted") }
        catch is Failure { throw Failure(description: "Failed write accepted") }
        catch { try expect(atomic.snapshot.networkChanges.isEmpty, "failed timeline write leaves memory unchanged") }
        try FileManager.default.removeItem(at: atomicDir.appendingPathComponent("insights.json"))
        _ = try atomic.observeNetwork(distant, at: now)
        try expect(atomic.snapshot.networkChanges.count == 1 && atomic.snapshot.networkChanges[0].previous == nil, "retry does not consume baseline on failed write")
        _ = try atomic.observeNetwork(nearby, at: now.addingTimeInterval(10))
        do { _ = try atomic.observeNetwork(distant, at: now.addingTimeInterval(-1)); throw Failure(description: "Out of order accepted") }
        catch HistoryError.invalidMeasurement { try expect(atomic.snapshot.networkChanges.count == 2, "out-of-order network event cannot alter history") }

        let retentionDir = root.appendingPathComponent("retention")
        let retention = try InsightsStore(directoryURL: retentionDir, now: { now })
        _ = try retention.observeNetwork(distant, at: now.addingTimeInterval(-91 * 86400))
        try expect(retention.snapshot.networkChanges.isEmpty, "network events expire after 90 days")
        var crowded = InsightsSnapshot()
        crowded.networkChanges = (0..<20_005).map { index in
            NetworkChange(timestamp: now.addingTimeInterval(Double(index - 20_005)), previous: nil, current: nearby)
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(crowded).write(to: retentionDir.appendingPathComponent("insights.json"))
        let bounded = try InsightsStore(directoryURL: retentionDir, now: { now })
        _ = try bounded.observeNetwork(distant, at: now)
        try expect(bounded.snapshot.networkChanges.count == 20_000 && bounded.snapshot.networkChanges.last?.current == distant,
            "frequent context changes obey the record cap and retain the newest event")
        print("All \(count) network context checks passed.")
    }
}
