import Foundation

public struct NetworkProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var ssid: String?
    public var thresholdMbps: Double
    public var pauseSpeedTests: Bool
    public init(id: UUID = UUID(), name: String, ssid: String? = nil, thresholdMbps: Double = 20, pauseSpeedTests: Bool = false) {
        self.id = id; self.name = name; self.ssid = ssid
        self.thresholdMbps = thresholdMbps; self.pauseSpeedTests = pauseSpeedTests
    }
    public var isValid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && thresholdMbps.isFinite && thresholdMbps > 0 && thresholdMbps <= 10_000 }
}

public enum MonitoringPolicy {
    public static func speedInterval(smart: Bool, configured: TimeInterval) -> TimeInterval { smart ? 3600 : configured }
    public static func isStale(_ timestamp: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard let timestamp else { return true }
        return now.timeIntervalSince(timestamp) > interval + 60
    }
    public static func shouldEscalate(failures: Int, latencyMilliseconds: Double?, lastSpeedAttempt: Date?, now: Date) -> Bool {
        let degraded = failures >= 2 || (latencyMilliseconds.map { $0 >= 500 } ?? false)
        // A fault cannot turn one-minute connection checks into unbounded full downloads.
        return degraded && (lastSpeedAttempt.map { now.timeIntervalSince($0) >= 600 } ?? true)
    }
    public static func profile(profiles: [NetworkProfile], ssid: String?, manualID: UUID?) -> NetworkProfile? {
        if let ssid, !ssid.isEmpty, let matched = profiles.first(where: { $0.ssid == ssid && $0.isValid }) { return matched }
        return profiles.first { $0.id == manualID && $0.isValid }
    }
}

public struct ConnectionSample: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let latencyMilliseconds: Double?
    public let reachable: Bool
    public init(timestamp: Date = Date(), latencyMilliseconds: Double?, reachable: Bool) {
        self.timestamp = timestamp; self.latencyMilliseconds = latencyMilliseconds; self.reachable = reachable
    }
}
public struct ConnectionOutage: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public var endedAt: Date?
    public var interrupted: Bool
}
public struct UploadSample: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let megabitsPerSecond: Double?
    public let bytesSent: Int
    public let errorDescription: String?
    public init(timestamp: Date = Date(), megabitsPerSecond: Double?, bytesSent: Int, errorDescription: String?) {
        self.timestamp = timestamp; self.megabitsPerSecond = megabitsPerSecond
        self.bytesSent = bytesSent; self.errorDescription = errorDescription
    }
}
public enum ConnectionEvent: Equatable { case started(ConnectionOutage), recovered(ConnectionOutage) }
public struct InsightsSnapshot: Codable, Equatable {
    public var connections: [ConnectionSample] = []
    public var outages: [ConnectionOutage] = []
    public var uploads: [UploadSample] = []
    public init() {}
}

/// Separate additive file: the original download/incident history format stays readable.
public final class InsightsStore {
    public private(set) var snapshot: InsightsSnapshot
    private let url: URL
    private let now: () -> Date
    private var previousFailure: Date?
    public init(directoryURL: URL, now: @escaping () -> Date = Date.init) throws {
        self.now = now; url = directoryURL.appendingPathComponent("insights.json")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            snapshot = try decoder.decode(InsightsSnapshot.self, from: Data(contentsOf: url))
            guard snapshot.connections.allSatisfy({ $0.timestamp.timeIntervalSince1970.isFinite && ($0.latencyMilliseconds.map { $0.isFinite && $0 >= 0 } ?? true) }),
                  snapshot.outages.filter({ $0.endedAt == nil }).count <= 1,
                  snapshot.outages.allSatisfy({ outage in outage.startedAt.timeIntervalSince1970.isFinite && (outage.endedAt.map { $0.timeIntervalSince1970.isFinite && $0 >= outage.startedAt } ?? true) }),
                  snapshot.uploads.allSatisfy({ $0.bytesSent >= 0 && ($0.megabitsPerSecond.map { $0.isFinite && $0 >= 0 } ?? true) }) else { throw HistoryError.invalidMeasurement }
            // A restart breaks observation continuity; never count unmonitored time as outage.
            try interrupt()
        } else { snapshot = InsightsSnapshot() }
    }
    @discardableResult public func record(_ sample: ConnectionSample) throws -> ConnectionEvent? {
        guard sample.timestamp.timeIntervalSince1970.isFinite,
              sample.latencyMilliseconds.map({ $0.isFinite && $0 >= 0 }) ?? true,
              snapshot.connections.last.map({ sample.timestamp >= $0.timestamp }) ?? true else { throw HistoryError.invalidMeasurement }
        var updated = snapshot
        // A gap means sleep, pause, or shutdown; consecutive failures must be adjacent observations.
        if let previous = updated.connections.last, sample.timestamp.timeIntervalSince(previous.timestamp) > 150,
           let index = updated.outages.lastIndex(where: { $0.endedAt == nil }) {
            updated.outages[index].endedAt = previous.timestamp; updated.outages[index].interrupted = true
        }
        let previous = previousFailure
        var event: ConnectionEvent?
        if sample.reachable {
            if let index = updated.outages.lastIndex(where: { $0.endedAt == nil }) {
                updated.outages[index].endedAt = sample.timestamp
                event = .recovered(updated.outages[index])
            }
        } else if updated.outages.last?.endedAt != nil || updated.outages.isEmpty {
            if let previous, sample.timestamp.timeIntervalSince(previous) <= 150 {
                let outage = ConnectionOutage(id: UUID(), startedAt: previous, endedAt: nil, interrupted: false)
                updated.outages.append(outage); event = .started(outage)
            }
        }
        updated.connections.append(sample)
        try commit(updated)
        previousFailure = sample.reachable ? nil : sample.timestamp
        return event
    }
    public func record(_ upload: UploadSample) throws {
        guard upload.timestamp.timeIntervalSince1970.isFinite, upload.bytesSent >= 0,
              upload.megabitsPerSecond.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw HistoryError.invalidMeasurement }
        var updated = snapshot; updated.uploads.append(upload); try commit(updated)
    }
    public func interrupt() throws {
        previousFailure = nil
        var updated = snapshot
        if let index = updated.outages.lastIndex(where: { $0.endedAt == nil }) {
            updated.outages[index].endedAt = max(updated.outages[index].startedAt, updated.connections.last?.timestamp ?? updated.outages[index].startedAt)
            updated.outages[index].interrupted = true
            try commit(updated)
        }
    }
    private func commit(_ value: InsightsSnapshot) throws {
        var retained = value
        let cutoff = now().addingTimeInterval(-90 * 86400)
        retained.connections = Array(value.connections.filter { $0.timestamp >= now().addingTimeInterval(-7 * 86400) }.suffix(10_100))
        retained.outages = Array(value.outages.filter { $0.endedAt.map { $0 >= cutoff } ?? true }.suffix(10_000))
        retained.uploads = Array(value.uploads.filter { $0.timestamp >= cutoff }.suffix(20_000))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(retained).write(to: url, options: .atomic)
        snapshot = retained
    }
}

public struct DailyReport {
    public let start: Date
    public let end: Date
    public let speeds: [Double]
    public let failedDownloads: Int
    public let incidentCount: Int
    public let incidentSeconds: TimeInterval
    public let outageCount: Int
    public let outageSeconds: TimeInterval
    public let connectionChecks: Int
    public let reachableChecks: Int
    public let bytes: Int
    public var median: Double? { Self.median(speeds) }
    public static func median(_ numbers: [Double]) -> Double? {
        let sorted = numbers.filter { $0.isFinite }.sorted()
        guard !sorted.isEmpty else { return nil }
        let i = sorted.count / 2
        return sorted.count % 2 == 0 ? sorted[i - 1] / 2 + sorted[i] / 2 : sorted[i]
    }
    public init(day: Date, history: HistorySnapshot, insights: InsightsSnapshot, now: Date = Date()) {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        start = calendar.startOfDay(for: day); end = calendar.date(byAdding: .day, value: 1, to: start)!
        let from = start, to = end, until = min(end, now)
        let measurements = history.measurements.filter { $0.timestamp >= from && $0.timestamp < to && $0.timestamp <= now }
        speeds = measurements.compactMap(\.megabitsPerSecond); failedDownloads = measurements.count - speeds.count
        func overlap(_ began: Date, _ ended: Date?) -> TimeInterval { max(0, min(ended ?? now, until).timeIntervalSince(max(began, from))) }
        let incidents = history.incidents.filter { overlap($0.startedAt, $0.endedAt) > 0 }
        incidentCount = incidents.count; incidentSeconds = incidents.reduce(0) { $0 + overlap($1.startedAt, $1.endedAt) }
        let outages = insights.outages.filter { overlap($0.startedAt, $0.endedAt) > 0 }
        outageCount = outages.count; outageSeconds = outages.reduce(0) { $0 + overlap($1.startedAt, $1.endedAt) }
        let checks = insights.connections.filter { $0.timestamp >= from && $0.timestamp < to && $0.timestamp <= now }
        connectionChecks = checks.count; reachableChecks = checks.filter(\.reachable).count
        bytes = measurements.reduce(0) { $0 + $1.bytesReceived } + insights.uploads.filter { $0.timestamp >= from && $0.timestamp < to && $0.timestamp <= now }.reduce(0) { $0 + $1.bytesSent }
    }
    public var text: String {
        func number(_ n: Double?) -> String { n.map { String(format: "%.2f", $0) } ?? "No samples" }
        return """
        SpeedSentry daily ISP report
        Day: \(ISTDate.string(start))
        Download samples: \(speeds.count) successful, \(failedDownloads) unavailable
        Download Mbps — minimum: \(number(speeds.min())), median: \(number(median)), maximum: \(number(speeds.max()))
        Speed incidents overlapping day: \(incidentCount); observed elapsed minutes: \(number(incidentSeconds / 60))
        Connection outages overlapping day: \(outageCount); observed elapsed minutes: \(number(outageSeconds / 60))
        Reachable connection samples: \(reachableChecks)/\(connectionChecks)
        Download/upload payload traffic: \(bytes) bytes

        All times IST (Asia/Kolkata). Incident durations describe time between observations, not continuous proof of ISP failure. Connection outages require two adjacent failed checks against both endpoints. Sleep/pause gaps are excluded from connection outages. Raw connection samples are retained for seven days; download history, uploads and outages for 90 days. Endpoint failures, VPNs and Wi-Fi can affect results. Upload is a conservative whole-request estimate. Payload traffic excludes connection-check headers and protocol overhead.
        """
    }
}
