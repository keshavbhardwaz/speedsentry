import Foundation
import XCTest
@testable import SpeedSentryCore

final class HistoryTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
    private var temporaryURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
        temporaryURLs = []
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SpeedSentryHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    private func sample(_ speed: Double?, after seconds: Double = 0, error: String? = nil) -> SpeedSentryCore.Measurement {
        SpeedSentryCore.Measurement(timestamp: referenceDate.addingTimeInterval(seconds), megabitsPerSecond: speed, bytesReceived: speed == nil ? 0 : 1_000_000, errorDescription: error)
    }

    func testStrictThresholdStartsOnceAndRecoveryClosesOnce() throws {
        let store = try HistoryStore(directoryURL: temporaryDirectory(), now: { self.referenceDate })
        XCTAssertNil(try store.record(sample(20), thresholdMbps: 20))
        guard case .started(let opened) = try store.record(sample(19.99, after: 1), thresholdMbps: 20) else {
            return XCTFail("A sample below the threshold must open an incident")
        }
        XCTAssertEqual(opened.kind, .slow)
        XCTAssertNil(try store.record(sample(12, after: 2), thresholdMbps: 20))
        guard case .recovered(let closed) = try store.record(sample(20, after: 3), thresholdMbps: 20) else {
            return XCTFail("Exactly the threshold must recover the active incident")
        }
        XCTAssertEqual(closed.id, opened.id)
        XCTAssertEqual(closed.lowestMbps, 12)
        XCTAssertEqual(closed.endedAt, referenceDate.addingTimeInterval(3))
        XCTAssertNil(try store.record(sample(40, after: 4), thresholdMbps: 20))
        XCTAssertEqual(store.incidents.count, 1)
        XCTAssertEqual(store.measurements.count, 5)
    }

    func testOfflineAndSlowSamplesBelongToOneIncident() throws {
        let store = try HistoryStore(directoryURL: temporaryDirectory(), now: { self.referenceDate })
        guard case .started(let first) = try store.record(sample(nil, error: "No network"), thresholdMbps: 20) else {
            return XCTFail("An unavailable result must open an incident")
        }
        XCTAssertEqual(first.kind, .unavailable)
        XCTAssertNil(first.lowestMbps)
        XCTAssertNil(try store.record(sample(11, after: 1), thresholdMbps: 20))
        XCTAssertNil(try store.record(sample(nil, after: 2), thresholdMbps: 20))
        XCTAssertNil(try store.record(sample(0, after: 3), thresholdMbps: 20))
        XCTAssertEqual(store.incidents.count, 1)
        XCTAssertEqual(store.incidents.first?.lowestMbps, 0)
        XCTAssertEqual(store.incidents.first?.kind, .unavailable)
    }

    func testActiveIncidentSurvivesRestartAndKeepsIdentifier() throws {
        let directory = try temporaryDirectory()
        let initial = try HistoryStore(directoryURL: directory, now: { self.referenceDate })
        _ = try initial.record(sample(15), thresholdMbps: 20)
        let identifier = try XCTUnwrap(initial.incidents.first?.id)
        let restored = try HistoryStore(directoryURL: directory, now: { self.referenceDate })
        XCTAssertEqual(restored.history, initial.history)
        XCTAssertNil(try restored.record(sample(10, after: 10), thresholdMbps: 20))
        guard case .recovered(let incident) = try restored.record(sample(21, after: 20), thresholdMbps: 20) else {
            return XCTFail("Restored ongoing incidents must recover normally")
        }
        XCTAssertEqual(incident.id, identifier)
        XCTAssertEqual(incident.startedAt, referenceDate)
        XCTAssertEqual(incident.lowestMbps, 10)
    }

    func testCorruptFileIsPreservedAndNotSilentlyReset() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("history.json")
        let corruptData = Data("{ interrupted write, original evidence".utf8)
        try corruptData.write(to: file)
        XCTAssertThrowsError(try HistoryStore(directoryURL: directory)) { error in
            XCTAssertTrue(error.localizedDescription.contains("preserved"))
        }
        XCTAssertEqual(try Data(contentsOf: file), corruptData)
    }

    func testFailedPersistenceDoesNotChangeStateOrConsumeStartEvent() throws {
        let directory = try temporaryDirectory()
        let store = try HistoryStore(directoryURL: directory, now: { self.referenceDate })
        let blockingDirectory = directory.appendingPathComponent("history.json", isDirectory: true)
        try FileManager.default.createDirectory(at: blockingDirectory, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.record(sample(10), thresholdMbps: 20))
        XCTAssertTrue(store.measurements.isEmpty)
        XCTAssertTrue(store.incidents.isEmpty)
        try FileManager.default.removeItem(at: blockingDirectory)
        guard case .started = try store.record(sample(10), thresholdMbps: 20) else {
            return XCTFail("A retry after persistence recovers must still return the start event")
        }
        XCTAssertEqual(store.measurements.count, 1)
        XCTAssertEqual(store.incidents.count, 1)
    }

    func testRetentionIsNinetyDaysAndBoundedEvenWithManualChecks() throws {
        let directory = try temporaryDirectory()
        let old = referenceDate.addingTimeInterval(-91 * 24 * 60 * 60)
        let expiredMeasurement = Measurement(timestamp: old, megabitsPerSecond: 50, bytesReceived: 1, errorDescription: nil)
        let recent = (0..<(HistoryStore.maximumMeasurements + 10)).map { index in
            Measurement(timestamp: referenceDate.addingTimeInterval(Double(index - HistoryStore.maximumMeasurements - 10)), megabitsPerSecond: 50, bytesReceived: 1, errorDescription: nil)
        }
        let expiredIncident = Incident(startedAt: old, endedAt: old.addingTimeInterval(10), lowestMbps: 10, thresholdMbps: 20, kind: .slow)
        let openIncident = Incident(startedAt: old, lowestMbps: 8, thresholdMbps: 20, kind: .slow)
        let snapshot = HistorySnapshot(measurements: [expiredMeasurement] + recent, incidents: [expiredIncident, openIncident])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: directory.appendingPathComponent("history.json"))

        let store = try HistoryStore(directoryURL: directory, now: { self.referenceDate })
        XCTAssertEqual(store.measurements.count, HistoryStore.maximumMeasurements)
        XCTAssertEqual(store.measurements.first?.timestamp, recent[10].timestamp)
        XCTAssertEqual(store.incidents.map(\.id), [openIncident.id], "An ongoing incident must survive even if it began before retention")
        let restored = try HistoryStore(directoryURL: directory, now: { self.referenceDate })
        XCTAssertEqual(restored.history, store.history)
    }

    func testISTFormattingAndCSVPreserveDateBoundaryAndEscapeErrorText() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-20T20:15:00Z"))
        XCTAssertEqual(ISTDate.string(date), "2026-10-21 01:45:00 IST (+05:30)")
        let directory = try temporaryDirectory()
        let store = try HistoryStore(directoryURL: directory, now: { date })
        _ = try store.record(Measurement(timestamp: date, megabitsPerSecond: nil, bytesReceived: 0, errorDescription: "=SUM(1,2)\n\"timeout\""), thresholdMbps: 20)
        let exported = directory.appendingPathComponent("history.csv")
        try store.exportCSV(to: exported)
        let csv = try String(contentsOf: exported, encoding: .utf8)
        XCTAssertTrue(csv.contains("Asia/Kolkata, UTC+05:30"))
        XCTAssertTrue(csv.contains("2026-10-21 01:45:00 IST (+05:30)"))
        XCTAssertTrue(csv.contains("\"'=SUM(1,2)\n\"\"timeout\"\"\""))
        XCTAssertTrue(csv.contains("\"incident\""))
        XCTAssertTrue(csv.contains("\"unavailable\""))
    }

    func testInvalidInputAndOutOfOrderSamplesCannotAlterHistory() throws {
        let store = try HistoryStore(directoryURL: temporaryDirectory(), now: { self.referenceDate })
        _ = try store.record(sample(30), thresholdMbps: 20)
        let saved = store.history
        XCTAssertThrowsError(try store.record(sample(.nan, after: 1), thresholdMbps: 20))
        XCTAssertThrowsError(try store.record(sample(-1, after: 1), thresholdMbps: 20))
        XCTAssertThrowsError(try store.record(sample(30, after: 1), thresholdMbps: 0))
        XCTAssertThrowsError(try store.record(sample(10, after: -1), thresholdMbps: 20))
        XCTAssertEqual(store.history, saved)
    }
}
