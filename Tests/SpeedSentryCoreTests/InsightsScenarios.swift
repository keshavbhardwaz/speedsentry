import Foundation
#if canImport(SpeedSentryCore)
@testable import SpeedSentryCore
#endif

/// Runs unchanged under XCTest in CI and the native local runner on CLT-only Macs.
enum InsightsScenarios {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func run() async throws {
        var count = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { throw Failure(description: label) }; count += 1
            print("PASS \(label)")
        }
        let now = ISO8601DateFormatter().date(from: "2026-11-08T12:00:00Z")!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try InsightsStore(directoryURL: root, now: { now })
        func sample(_ seconds: Double, _ reachable: Bool) -> ConnectionSample {
            ConnectionSample(timestamp: now.addingTimeInterval(seconds), latencyMilliseconds: reachable ? 80 : nil, reachable: reachable)
        }
        try expect(tryRecord(store, sample(-300, false)) == nil, "single failed check does not open outage")
        let start = try store.record(sample(-240, false))
        try expect(start != nil && store.snapshot.outages.count == 1, "second adjacent failure opens outage")
        try expect(tryRecord(store, sample(-180, false)) == nil && store.snapshot.outages.count == 1, "repeated failures do not duplicate alerts")
        let recovery = try store.record(sample(-120, true))
        try expect(recovery != nil && store.snapshot.outages.last?.endedAt == now.addingTimeInterval(-120), "healthy check recovers outage")
        _ = try store.record(sample(-60, false)); _ = try store.record(sample(0, false))
        try store.interrupt()
        try expect(store.snapshot.outages.last?.interrupted == true && store.snapshot.outages.last?.endedAt == now, "pause ends outage observation at last check")
        _ = try store.record(sample(400, false))
        try expect(store.snapshot.outages.count == 2, "gap does not join isolated failures")
        _ = try store.record(sample(460, false))
        let reloaded = try InsightsStore(directoryURL: root, now: { now })
        try expect(reloaded.snapshot.outages.last?.interrupted == true && reloaded.snapshot.outages.last?.endedAt != nil, "restart excludes unobserved downtime")
        do { _ = try reloaded.record(sample(-1000, true)); throw Failure(description: "out of order accepted") } catch HistoryError.invalidMeasurement { count += 1 }
        do { _ = try reloaded.record(ConnectionSample(timestamp: now, latencyMilliseconds: .nan, reachable: true)); throw Failure(description: "NaN accepted") } catch HistoryError.invalidMeasurement { count += 1 }
        let pauseStore = try InsightsStore(directoryURL: root.appendingPathComponent("pause"), now: { now })
        _ = try pauseStore.record(sample(-120, false)); try pauseStore.interrupt()
        _ = try pauseStore.record(sample(-60, false))
        try expect(pauseStore.snapshot.outages.isEmpty, "pause resets even an isolated pending failure")
        _ = try pauseStore.record(sample(0, false))
        try expect(pauseStore.snapshot.outages.count == 1, "two post-pause failures still open an outage")
        let retentionStore = try InsightsStore(directoryURL: root.appendingPathComponent("retention"), now: { now })
        _ = try retentionStore.record(sample(-8 * 86400, true))
        try expect(retentionStore.snapshot.connections.isEmpty, "raw connection samples expire after seven days")
        let atomicDirectory = root.appendingPathComponent("atomic")
        let atomicStore = try InsightsStore(directoryURL: atomicDirectory, now: { now })
        _ = try atomicStore.record(sample(-60, true))
        let before = atomicStore.snapshot
        let atomicURL = atomicDirectory.appendingPathComponent("insights.json")
        try FileManager.default.moveItem(at: atomicURL, to: atomicDirectory.appendingPathComponent("backup.json"))
        try FileManager.default.createDirectory(at: atomicURL, withIntermediateDirectories: false)
        do { _ = try atomicStore.record(sample(0, false)); throw Failure(description: "failed write accepted") }
        catch is Failure { throw Failure(description: "failed write was accepted") }
        catch { try expect(atomicStore.snapshot == before, "failed persistence leaves memory unchanged") }
        try expect(MonitoringPolicy.speedInterval(smart: true, configured: 600) == 3600, "smart schedule uses hourly speed checks")
        try expect(MonitoringPolicy.speedInterval(smart: false, configured: 600) == 600, "fixed schedule preserves ten-minute preference")
        try expect(MonitoringPolicy.isStale(now.addingTimeInterval(-661), now: now, interval: 600), "old result is stale")
        try expect(!MonitoringPolicy.isStale(now.addingTimeInterval(-600), now: now, interval: 600), "current scheduled sample stays recent")
        try expect(MonitoringPolicy.isStale(nil, now: now, interval: 600), "missing sample is stale")
        try expect(!MonitoringPolicy.shouldEscalate(failures: 1, latencyMilliseconds: nil, lastSpeedAttempt: nil, now: now), "isolated endpoint failure cannot trigger full test")
        try expect(MonitoringPolicy.shouldEscalate(failures: 2, latencyMilliseconds: nil, lastSpeedAttempt: nil, now: now), "confirmed connection problem escalates")
        try expect(!MonitoringPolicy.shouldEscalate(failures: 2, latencyMilliseconds: nil, lastSpeedAttempt: now.addingTimeInterval(-599), now: now), "escalation obeys ten-minute cooldown")
        try expect(MonitoringPolicy.shouldEscalate(failures: 0, latencyMilliseconds: 600, lastSpeedAttempt: now.addingTimeInterval(-600), now: now), "high HTTPS latency escalates after cooldown")
        let home = NetworkProfile(name: "Home", ssid: "FixtureWiFi", thresholdMbps: 20)
        let hotspot = NetworkProfile(name: "Hotspot", thresholdMbps: 10, pauseSpeedTests: true)
        try expect(MonitoringPolicy.profile(profiles: [home, hotspot], ssid: "FixtureWiFi", manualID: hotspot.id) == home, "Wi-Fi match selects correct threshold")
        try expect(MonitoringPolicy.profile(profiles: [home, hotspot], ssid: nil, manualID: hotspot.id)?.pauseSpeedTests == true, "manual hotspot blocks full tests without SSID permission")
        try expect(MonitoringPolicy.profile(profiles: [home], ssid: nil, manualID: nil) == nil, "unknown network uses default profile")
        try expect(!NetworkProfile(name: "", thresholdMbps: 20).isValid && !NetworkProfile(name: "Bad", thresholdMbps: .infinity).isValid, "invalid profiles rejected")
        try expect(DailyReport.median([100, 10, 50, 20]) == 35 && DailyReport.median([]) == nil, "median handles even and empty populations")
        let midnight = ISO8601DateFormatter().date(from: "2026-11-07T18:30:00Z")!
        let history = HistorySnapshot(measurements: [
            Measurement(timestamp: midnight.addingTimeInterval(-1), megabitsPerSecond: 999, bytesReceived: 100, errorDescription: nil),
            Measurement(timestamp: midnight, megabitsPerSecond: 10, bytesReceived: 100, errorDescription: nil),
            Measurement(timestamp: midnight.addingTimeInterval(1), megabitsPerSecond: 100, bytesReceived: 200, errorDescription: nil),
            Measurement(timestamp: midnight.addingTimeInterval(2), megabitsPerSecond: nil, bytesReceived: 30, errorDescription: "fixture")
        ], incidents: [Incident(startedAt: midnight.addingTimeInterval(-60), endedAt: midnight.addingTimeInterval(60), lowestMbps: 10, thresholdMbps: 20, kind: .slow)])
        let report = DailyReport(day: now, history: history, insights: store.snapshot, now: now)
        try expect(report.start == midnight && report.speeds == [10, 100] && report.median == 55, "IST midnight boundary selects correct daily samples")
        try expect(report.incidentSeconds == 60 && report.incidentCount == 1, "incident crossing midnight is clipped to report day")
        try expect(report.failedDownloads == 1 && report.bytes == 330, "report counts failed tests and all payload bytes")
        try expect(report.text.contains("IST") && report.text.contains("observations"), "report explains time zone and sampling limits")
        try expect(UploadProbe.rate(SmallHTTPResult(status: 200, bytesSent: 4_194_304, duration: 2, error: nil), expectedBytes: 4_194_304) == 16.777216, "upload uses decimal Mbps and whole-request time")
        try expect(UploadProbe.rate(SmallHTTPResult(status: 200, bytesSent: 10, duration: 2, error: nil), expectedBytes: 100) == nil, "partial uploads never fabricate speed")
        try expect(UploadProbe.rate(SmallHTTPResult(status: 500, bytesSent: 100, duration: 2, error: nil), expectedBytes: 100) == nil, "upload HTTP failure rejected")
        try expect(UploadProbe.rate(SmallHTTPResult(status: 200, bytesSent: 100, duration: .nan, error: nil), expectedBytes: 100) == nil, "invalid upload timing rejected")
        try await checkHTTP(expect: { condition, label in try expect(condition, label) })
        // Corrupt input must survive a failed load byte for byte.
        let corrupt = root.appendingPathComponent("insights.json")
        let bad = Data("{invalid".utf8); try bad.write(to: corrupt)
        do { _ = try InsightsStore(directoryURL: root); throw Failure(description: "corrupt store accepted") } catch is DecodingError { count += 1 }
        try expect(tryData(corrupt) == bad, "corrupt insights file is never overwritten")
        print("All \(count) insights regression checks passed.")
    }
    private static func tryRecord(_ store: InsightsStore, _ sample: ConnectionSample) -> ConnectionEvent? { try? store.record(sample) }
    private static func tryData(_ url: URL) -> Data? { try? Data(contentsOf: url) }
    private static func checkHTTP(expect: (Bool, String) throws -> Void) async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [InsightsProtocol.self]
        let first = URL(string: "https://fixture.invalid/primary")!, second = URL(string: "https://fixture.invalid/fallback")!
        InsightsProtocol.mode = 0
        let success = await ConnectionProbe(endpoints: [first, second], configuration: configuration).measure()
        try expect(success.reachable && success.latencyMilliseconds != nil, "primary HTTP failure falls back to independent endpoint")
        InsightsProtocol.mode = 1
        let failure = await ConnectionProbe(endpoints: [first, second], configuration: configuration).measure()
        try expect(!failure.reachable && failure.latencyMilliseconds == nil, "both endpoints failing returns unavailable")
        InsightsProtocol.mode = 2
        let oversized = await ConnectionProbe(endpoints: [first], configuration: configuration).measure()
        try expect(!oversized.reachable, "connection response size is bounded")
        InsightsProtocol.mode = 3
        let cancelled = Task { await ConnectionProbe(endpoints: [first], configuration: configuration).measure() }
        try await Task.sleep(nanoseconds: 20_000_000); cancelled.cancel()
        let result = await cancelled.value
        try expect(!result.reachable, "in-flight connection task cancellation completes")
    }
}
private final class InsightsProtocol: URLProtocol, @unchecked Sendable {
    // Scenarios run sequentially; only the worker reads while a scenario is active.
    static var mode = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.mode == 3 { return }
        let status = Self.mode == 1 || request.url!.path == "/primary" && Self.mode == 0 ? 503 : 200
        let length = Self.mode == 2 ? 20_000 : 0
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(length)])!, cacheStoragePolicy: .notAllowed)
        if length > 0 { client?.urlProtocol(self, didLoad: Data(repeating: 1, count: length)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
