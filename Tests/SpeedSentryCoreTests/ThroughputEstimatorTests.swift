import XCTest
@testable import SpeedSentryCore

final class ThroughputEstimatorTests: XCTestCase {
    private let payloadBytes = 8 * 1_024 * 1_024

    private func metrics(bytes: Int? = nil, duration: Double, network: Bool = true, transactions: Int = 1) -> TransportTiming {
        TransportTiming(durationSeconds: duration, bytesReceived: Int64(bytes ?? payloadBytes), isNetworkLoad: network, transactionCount: transactions)
    }

    private func assertRejected(
        bytes: Int? = nil,
        request: Double = 1,
        transport: TransportTiming?,
        expected: ThroughputEstimationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try ThroughputEstimator.estimate(bytesReceived: bytes ?? payloadBytes, requestDurationSeconds: request, transport: transport), file: file, line: line) {
            XCTAssertEqual($0 as? ThroughputEstimationError, expected, file: file, line: line)
        }
    }

    func testCoalescedCallbacksCannotInflateA100MbpsTransport() throws {
        let transportSeconds = Double(payloadBytes) * 8 / 100_000_000
        let oldCallbackSeconds = 0.32
        let oldWarmupBytes = 512 * 1_024
        let oldEstimate = Double(payloadBytes - oldWarmupBytes) * 8 / oldCallbackSeconds / 1_000_000
        XCTAssertGreaterThan(oldEstimate, 150, "A buffered callback window can report more than the actual link throughput")

        let estimate = try ThroughputEstimator.estimate(
            bytesReceived: payloadBytes,
            requestDurationSeconds: transportSeconds + 0.2,
            transport: metrics(duration: transportSeconds)
        )
        XCTAssertEqual(estimate.megabitsPerSecond, 100, accuracy: 0.000_000_1)
        XCTAssertEqual(estimate.durationSeconds, transportSeconds)
        XCTAssertEqual(estimate.source, "transport")
    }

    func testMbpsUsesEightBitsPerByteAndDecimalMegabits() throws {
        let decimal = try ThroughputEstimator.estimate(bytesReceived: 1_000_000, requestDurationSeconds: 1, transport: nil)
        let binary = try ThroughputEstimator.estimate(bytesReceived: 1_024 * 1_024, requestDurationSeconds: 1, transport: nil)
        XCTAssertEqual(decimal.megabitsPerSecond, 8)
        XCTAssertEqual(binary.megabitsPerSecond, 8.388608, accuracy: 0.000_000_001)
    }

    func testCompletePayloadIsUsedWithoutWarmupSubtraction() throws {
        let estimate = try ThroughputEstimator.estimate(bytesReceived: payloadBytes, requestDurationSeconds: 1.2, transport: metrics(duration: 1))
        XCTAssertEqual(estimate.megabitsPerSecond, 67.108864, accuracy: 0.000_000_001)
    }

    func testGenuineSpeedsAbove100MbpsArePreserved() throws {
        for expectedMbps in [150.0, 300, 1_000] {
            let seconds = Double(payloadBytes) * 8 / (expectedMbps * 1_000_000)
            let estimate = try ThroughputEstimator.estimate(bytesReceived: payloadBytes, requestDurationSeconds: seconds + 0.05, transport: metrics(duration: seconds))
            XCTAssertEqual(estimate.megabitsPerSecond, expectedMbps, accuracy: 0.000_000_1)
        }
    }

    func testBufferedCallbacksCannotHideABelow20MbpsIncident() throws {
        let trueMbps = 15.0
        let oldEstimate = Double(payloadBytes - 512 * 1_024) * 8 / 1 / 1_000_000
        XCTAssertGreaterThan(oldEstimate, 20)
        let seconds = Double(payloadBytes) * 8 / (trueMbps * 1_000_000)
        let estimate = try ThroughputEstimator.estimate(bytesReceived: payloadBytes, requestDurationSeconds: seconds + 0.1, transport: metrics(duration: seconds))
        XCTAssertEqual(estimate.megabitsPerSecond, trueMbps, accuracy: 0.000_000_1)
        XCTAssertLessThan(estimate.megabitsPerSecond, 20)
    }

    func testTransportTimingDoesNotMistakeConnectionLatencyForASpeedDrop() throws {
        let seconds = Double(payloadBytes) * 8 / 25_000_000
        let estimate = try ThroughputEstimator.estimate(bytesReceived: payloadBytes, requestDurationSeconds: 5, transport: metrics(duration: seconds))
        XCTAssertEqual(estimate.megabitsPerSecond, 25, accuracy: 0.000_000_1)
        XCTAssertGreaterThan(estimate.megabitsPerSecond, 20)
    }

    func testExactly20MbpsRemainsAtHealthyThreshold() throws {
        let seconds = Double(payloadBytes) * 8 / 20_000_000
        let estimate = try ThroughputEstimator.estimate(bytesReceived: payloadBytes, requestDurationSeconds: seconds + 0.1, transport: metrics(duration: seconds))
        XCTAssertEqual(estimate.megabitsPerSecond, 20)
        XCTAssertFalse(estimate.megabitsPerSecond < 20)
    }

    func testMissingMetricsFallbackUsesEntireRequestIncludingLatency() throws {
        let transportSeconds = Double(payloadBytes) * 8 / 100_000_000
        let requestSeconds = transportSeconds + 0.4
        let estimate = try ThroughputEstimator.estimate(bytesReceived: payloadBytes, requestDurationSeconds: requestSeconds, transport: nil)
        XCTAssertEqual(estimate.megabitsPerSecond, 67.108864 / requestSeconds, accuracy: 0.000_000_001)
        XCTAssertLessThan(estimate.megabitsPerSecond, 100)
        XCTAssertEqual(estimate.durationSeconds, requestSeconds)
        XCTAssertEqual(estimate.source, "request")
    }

    func testCachedAndLocalMetricsAreRejectedWithoutFallback() {
        assertRejected(transport: metrics(duration: 0.5, network: false), expected: .nonNetworkLoad)
    }

    func testTransportCountMustMatchCompletedPayloadExactly() {
        for mismatch in [-1, 0, payloadBytes - 1, payloadBytes + 1] {
            assertRejected(transport: metrics(bytes: mismatch, duration: 0.5), expected: .transportByteCountMismatch)
        }
    }

    func testExactlyOneTransactionIsRequired() {
        for count in [-1, 0, 2, 3] {
            assertRejected(transport: metrics(duration: 0.5, transactions: count), expected: .invalidTransactionCount)
        }
    }

    func testInvalidTransportDurationsRejectInsteadOfUsingValidRequestFallback() {
        for seconds in [0, -1, 0.000_001, Double.nan, .infinity, -.infinity] {
            assertRejected(transport: metrics(duration: seconds), expected: .invalidTransportDuration)
        }
    }

    func testInvalidRequestDurationsRejectEvenWithValidTransportMetrics() {
        for seconds in [0, -1, 0.000_001, Double.nan, .infinity, -.infinity] {
            assertRejected(request: seconds, transport: metrics(duration: 0.5), expected: .invalidRequestDuration)
            assertRejected(request: seconds, transport: nil, expected: .invalidRequestDuration)
        }
    }

    func testEmptyOrNegativePayloadCannotProduceAnEstimate() {
        for bytes in [0, -1] {
            assertRejected(bytes: bytes, transport: nil, expected: .invalidByteCount)
        }
    }

    func testTransportLongerThanRequestRejectsBeyondDocumentedClockTolerance() {
        assertRejected(transport: metrics(duration: 1.011), expected: .transportDurationExceedsRequest)
        assertRejected(request: 0.05, transport: metrics(duration: 0.052), expected: .transportDurationExceedsRequest)
    }

    func testSmallClockGranularityDifferenceKeepsConservativeTransportDuration() throws {
        let estimate = try ThroughputEstimator.estimate(bytesReceived: payloadBytes, requestDurationSeconds: 1, transport: metrics(duration: 1.005))
        XCTAssertEqual(estimate.durationSeconds, 1.005)
        XCTAssertLessThan(estimate.megabitsPerSecond, 67.108864)
        XCTAssertEqual(estimate.source, "transport")
    }
}
