import Foundation
import XCTest
@testable import SpeedSentryCore

final class LoopbackProbeTests: XCTestCase {
    func test100MbpsRemainsAccurateWhenDelegateCallbacksAreBuffered() async throws {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let stalled = expectation(description: "Delegate queue was deliberately stalled")
        let server = try PacedLoopbackServer(bytes: SpeedProbe.downloadBytes, megabitsPerSecond: 100) {
            // Let the HTTP response callback run, then buffer data callbacks for
            // most of the 0.67-second payload transfer. The transport
            // continues on the real loopback socket while callbacks wait.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
                queue.addOperation {
                    stalled.fulfill()
                    Thread.sleep(forTimeInterval: 0.50)
                }
            }
        }
        let result = await measure(server: server, delegateQueue: queue)
        await fulfillment(of: [stalled], timeout: 2)
        try verify(result, server: server, targetMbps: 100)
    }

    func testGenuine150MbpsTransferIsNotClampedTo100Mbps() async throws {
        let server = try PacedLoopbackServer(bytes: SpeedProbe.downloadBytes, megabitsPerSecond: 150)
        let result = await measure(server: server)
        try verify(result, server: server, targetMbps: 150)
        XCTAssertGreaterThan(try XCTUnwrap(result?.megabitsPerSecond), 130)
    }

    func test15MbpsTransferRemainsBelow20MbpsAlertThreshold() async throws {
        let server = try PacedLoopbackServer(bytes: SpeedProbe.downloadBytes, megabitsPerSecond: 15)
        let result = await measure(server: server)
        try verify(result, server: server, targetMbps: 15)
        XCTAssertLessThan(try XCTUnwrap(result?.megabitsPerSecond), 20)
    }

    func testAdaptiveConfirmationRejectsInitial250MbpsBurstOn100MbpsTransfer() async throws {
        let confirmationBytes = 64 * 1_024 * 1_024
        let server = try PacedLoopbackServer(responses: [
            .init(bytes: SpeedProbe.downloadBytes, megabitsPerSecond: 250),
            .init(bytes: confirmationBytes, megabitsPerSecond: 100)
        ])
        let result = await measure(server: server, confirmationBytes: confirmationBytes, timeoutSeconds: 30)
        try verifyAdaptive(result, server: server, initialMbps: 250, sustainedMbps: 100)
    }

    func testAdaptiveConfirmationPreservesGenuine150MbpsTransfer() async throws {
        let confirmationBytes = 64 * 1_024 * 1_024
        let server = try PacedLoopbackServer(responses: [
            .init(bytes: SpeedProbe.downloadBytes, megabitsPerSecond: 150),
            .init(bytes: confirmationBytes, megabitsPerSecond: 150)
        ])
        let result = await measure(server: server, confirmationBytes: confirmationBytes, timeoutSeconds: 30)
        try verifyAdaptive(result, server: server, initialMbps: 150, sustainedMbps: 150)
        XCTAssertGreaterThan(try XCTUnwrap(result?.megabitsPerSecond), 130)
    }

    private func measure(server: PacedLoopbackServer, delegateQueue: OperationQueue? = nil,
                         confirmationBytes: Int? = nil, timeoutSeconds: UInt64 = 10) async -> SpeedSentryCore.Measurement? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let probe = SpeedProbe(
            configuration: configuration,
            endpoint: server.endpoint,
            expectedBytes: SpeedProbe.downloadBytes,
            delegateQueue: delegateQueue,
            confirmationBytes: confirmationBytes
        )
        return await withTaskGroup(of: SpeedSentryCore.Measurement?.self) { group in
            group.addTask { await probe.measure() }
            group.addTask {
                do { try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000) }
                catch { return nil }
                probe.cancel()
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func verifyAdaptive(_ result: SpeedSentryCore.Measurement?, server: PacedLoopbackServer,
                                initialMbps: Double, sustainedMbps: Double) throws {
        let result = try XCTUnwrap(result, "Adaptive local check exceeded its 30-second bound.")
        XCTAssertNil(result.errorDescription)
        let transfers = try XCTUnwrap(server.waitForTransfers(count: 2))
        XCTAssertEqual(transfers.count, 2)
        XCTAssertEqual(transfers.map(\.bytesSent), [SpeedProbe.downloadBytes, 64 * 1_024 * 1_024])
        XCTAssertNil(transfers[0].error)
        XCTAssertNil(transfers[1].error)
        XCTAssertEqual(transfers[0].megabitsPerSecond, initialMbps, accuracy: initialMbps * 0.08)
        XCTAssertEqual(transfers[1].megabitsPerSecond, sustainedMbps, accuracy: sustainedMbps * 0.08)
        let totalBytes = transfers.reduce(0) { $0 + $1.bytesSent }
        XCTAssertEqual(result.bytesReceived, totalBytes)
        XCTAssertEqual(try XCTUnwrap(result.megabitsPerSecond), transfers[1].megabitsPerSecond,
                       accuracy: transfers[1].megabitsPerSecond * 0.08)
    }

    private func verify(_ result: SpeedSentryCore.Measurement?, server: PacedLoopbackServer, targetMbps: Double) throws {
        let result = try XCTUnwrap(result, "Local check exceeded its 10-second bound.")
        XCTAssertNil(result.errorDescription)
        XCTAssertEqual(result.bytesReceived, SpeedProbe.downloadBytes)
        let measured = try XCTUnwrap(result.megabitsPerSecond)
        let actual = try XCTUnwrap(server.waitForTransfer())
        XCTAssertNil(actual.error)
        XCTAssertEqual(actual.bytesSent, SpeedProbe.downloadBytes)
        // Absolute pacing normally stays much closer than this; 8% allows for
        // shared CI scheduling jitter while still catching the 100→150 bias.
        XCTAssertEqual(actual.megabitsPerSecond, targetMbps, accuracy: targetMbps * 0.08)
        XCTAssertEqual(measured, actual.megabitsPerSecond, accuracy: actual.megabitsPerSecond * 0.08)
    }
}
