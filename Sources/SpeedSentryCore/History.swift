import Foundation

public struct Measurement: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let megabitsPerSecond: Double?
    public let bytesReceived: Int
    public let errorDescription: String?

    public init(timestamp: Date, megabitsPerSecond: Double?, bytesReceived: Int, errorDescription: String?) {
        self.timestamp = timestamp
        self.megabitsPerSecond = megabitsPerSecond
        self.bytesReceived = bytesReceived
        self.errorDescription = errorDescription
    }
}

public enum IncidentKind: String, Codable, Sendable {
    case slow
    case unavailable
}

public struct Incident: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public var endedAt: Date?
    public var lowestMbps: Double?
    public let thresholdMbps: Double
    public var kind: IncidentKind

    public init(id: UUID = UUID(), startedAt: Date, endedAt: Date? = nil, lowestMbps: Double?, thresholdMbps: Double, kind: IncidentKind) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lowestMbps = lowestMbps
        self.thresholdMbps = thresholdMbps
        self.kind = kind
    }
}

public enum IncidentEvent: Equatable, Sendable {
    case started(Incident)
    case recovered(Incident)
}

public struct HistorySnapshot: Codable, Equatable, Sendable {
    public var measurements: [Measurement]
    public var incidents: [Incident]
    public let schemaVersion: Int

    public init(measurements: [Measurement] = [], incidents: [Incident] = []) {
        self.measurements = measurements
        self.incidents = incidents
        self.schemaVersion = 1
    }
}

public enum HistoryError: LocalizedError {
    case invalidMeasurement
    case invalidThreshold
    case outOfOrderMeasurement
    case unreadableHistory(URL, String)

    public var errorDescription: String? {
        switch self {
        case .invalidMeasurement:
            return "The measurement contains an invalid speed, byte count, or timestamp."
        case .invalidThreshold:
            return "The speed threshold must be a finite number greater than zero."
        case .outOfOrderMeasurement:
            return "A measurement cannot precede the last recorded measurement."
        case .unreadableHistory(let url, let reason):
            return "History could not be read at \(url.path). The original file has been preserved. \(reason)"
        }
    }
}

/// A local, atomic history store. Access it from one executor (the app uses its main thread).
public final class HistoryStore {
    public static let retentionDays = 90
    public static let maximumMeasurements = 20_000
    public static let maximumIncidents = 10_000

    public static var defaultDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpeedSentry", isDirectory: true)
    }

    public let directoryURL: URL
    public private(set) var history: HistorySnapshot
    public var measurements: [Measurement] { history.measurements }
    public var incidents: [Incident] { history.incidents }

    private let historyURL: URL
    private let now: () -> Date

    public init(directoryURL: URL, now: @escaping () -> Date = Date.init) throws {
        self.directoryURL = directoryURL
        self.historyURL = directoryURL.appendingPathComponent("history.json")
        self.now = now
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: historyURL.path) {
            do {
                let data = try Data(contentsOf: historyURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let decoded = try decoder.decode(HistorySnapshot.self, from: data)
                try Self.validate(decoded)
                history = decoded
            } catch {
                // Never replace unreadable data with a fresh, empty file.
                throw HistoryError.unreadableHistory(historyURL, error.localizedDescription)
            }
        } else {
            history = HistorySnapshot()
        }

        let retained = Self.retainingRecent(history, relativeTo: now())
        if retained != history {
            try persist(retained)
            history = retained
        }
    }

    /// A bad sample opens one incident; further bad samples update it until a healthy sample closes it.
    /// Exactly the threshold is healthy. A missing speed means the test could not establish throughput.
    @discardableResult
    public func record(_ measurement: Measurement, thresholdMbps: Double) throws -> IncidentEvent? {
        guard thresholdMbps.isFinite, thresholdMbps > 0 else { throw HistoryError.invalidThreshold }
        guard Self.isValid(measurement) else { throw HistoryError.invalidMeasurement }
        if let last = history.measurements.last, measurement.timestamp < last.timestamp {
            throw HistoryError.outOfOrderMeasurement
        }

        var updated = history
        updated.measurements.append(measurement)
        let isBad = measurement.megabitsPerSecond.map { $0 < thresholdMbps } ?? true
        let activeIndex = updated.incidents.lastIndex { $0.endedAt == nil }
        var event: IncidentEvent?

        if isBad {
            if let index = activeIndex {
                if let speed = measurement.megabitsPerSecond {
                    updated.incidents[index].lowestMbps = min(updated.incidents[index].lowestMbps ?? speed, speed)
                } else {
                    updated.incidents[index].kind = .unavailable
                }
            } else {
                let incident = Incident(
                    startedAt: measurement.timestamp,
                    lowestMbps: measurement.megabitsPerSecond,
                    thresholdMbps: thresholdMbps,
                    kind: measurement.megabitsPerSecond == nil ? .unavailable : .slow
                )
                updated.incidents.append(incident)
                event = .started(incident)
            }
        } else if let index = activeIndex {
            updated.incidents[index].endedAt = measurement.timestamp
            event = .recovered(updated.incidents[index])
        }

        updated = Self.retainingRecent(updated, relativeTo: now())
        // Commit in memory only after the atomic disk write succeeds.
        try persist(updated)
        history = updated
        return event
    }

    /// Exports sample and incident rows. All human-facing times explicitly use Asia/Kolkata.
    public func exportCSV(to url: URL) throws {
        var rows: [[String]] = [[
            "record_type", "timestamp_ist (Asia/Kolkata, UTC+05:30)", "download_mbps", "bytes_received", "error",
            "incident_id", "started_at_ist (Asia/Kolkata, UTC+05:30)", "ended_at_ist (Asia/Kolkata, UTC+05:30)",
            "lowest_mbps", "threshold_mbps", "incident_kind"
        ]]
        rows += history.measurements.map { measurement in
            ["measurement", ISTDate.string(measurement.timestamp), Self.number(measurement.megabitsPerSecond),
             String(measurement.bytesReceived), measurement.errorDescription ?? "", "", "", "", "", "", ""]
        }
        rows += history.incidents.map { incident in
            ["incident", "", "", "", "", incident.id.uuidString, ISTDate.string(incident.startedAt),
             incident.endedAt.map(ISTDate.string) ?? "", Self.number(incident.lowestMbps),
             Self.number(incident.thresholdMbps), incident.kind.rawValue]
        }
        let csv = rows.map { $0.map(Self.csvCell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
        try Data(csv.utf8).write(to: url, options: .atomic)
    }

    private func persist(_ snapshot: HistorySnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: historyURL, options: .atomic)
    }

    private static func retainingRecent(_ source: HistorySnapshot, relativeTo now: Date) -> HistorySnapshot {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
        let samples = source.measurements.filter { $0.timestamp >= cutoff }.suffix(maximumMeasurements)
        // An incident still being observed remains intact even if it began before the retention window.
        let incidents = source.incidents.filter { $0.endedAt.map { $0 >= cutoff } ?? true }.suffix(maximumIncidents)
        return HistorySnapshot(measurements: Array(samples), incidents: Array(incidents))
    }

    private static func isValid(_ measurement: Measurement) -> Bool {
        measurement.timestamp.timeIntervalSince1970.isFinite && measurement.bytesReceived >= 0
            && (measurement.megabitsPerSecond.map { $0.isFinite && $0 >= 0 } ?? true)
    }

    private static func validate(_ snapshot: HistorySnapshot) throws {
        guard snapshot.schemaVersion == 1,
              snapshot.measurements.allSatisfy(isValid),
              zip(snapshot.measurements, snapshot.measurements.dropFirst()).allSatisfy({ $0.timestamp <= $1.timestamp }),
              Set(snapshot.incidents.map(\.id)).count == snapshot.incidents.count,
              snapshot.incidents.filter({ $0.endedAt == nil }).count <= 1,
              snapshot.incidents.allSatisfy({ incident in
                  incident.startedAt.timeIntervalSince1970.isFinite
                      && (incident.endedAt.map { $0.timeIntervalSince1970.isFinite && $0 >= incident.startedAt } ?? true)
                      && incident.thresholdMbps.isFinite && incident.thresholdMbps > 0
                      && (incident.lowestMbps.map { $0.isFinite && $0 >= 0 } ?? true)
              }) else { throw HistoryError.invalidMeasurement }
    }

    private static func number(_ number: Double?) -> String { number.map { String($0) } ?? "" }

    private static func csvCell(_ value: String) -> String {
        // Spreadsheet apps interpret these prefixes as formulas, even in quoted CSV fields.
        let safe: String
        if let first = value.first, "=+-@\t\r".contains(first) { safe = "'" + value } else { safe = value }
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

public enum ISTDate {
    public static func string(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'IST' (XXX)"
        return formatter.string(from: date)
    }
}
