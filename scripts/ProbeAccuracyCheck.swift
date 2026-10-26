import Foundation

/// Direct runner for the same real-network fixture as LoopbackProbeTests, so
/// Command Line Tools installations can check accuracy without XCTest/Xcode.
@main
private struct ProbeAccuracyCheck {
    private struct CheckFailure: Error, CustomStringConvertible {
        let description: String
    }

    static func main() async throws {
        for (rate, delayCallbacks) in [(100.0, true), (150.0, false), (15.0, false)] {
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let server = try PacedLoopbackServer(bytes: SpeedProbe.downloadBytes, megabitsPerSecond: rate) {
                if delayCallbacks {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
                        queue.addOperation { Thread.sleep(forTimeInterval: 0.50) }
                    }
                }
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            let probe = SpeedProbe(
                configuration: configuration,
                endpoint: server.endpoint,
                expectedBytes: SpeedProbe.downloadBytes,
                delegateQueue: queue
            )
            let measurement = await boundedMeasurement(probe)
            guard let measurement, let measured = measurement.megabitsPerSecond,
                  measurement.errorDescription == nil,
                  measurement.bytesReceived == SpeedProbe.downloadBytes,
                  let transfer = server.waitForTransfer(), transfer.error == nil,
                  transfer.bytesSent == SpeedProbe.downloadBytes else {
                throw CheckFailure(description: "\(rate) Mbps loopback check failed: \(String(describing: measurement?.errorDescription))")
            }
            let actual = transfer.megabitsPerSecond
            guard abs(actual - rate) <= rate * 0.08,
                  abs(measured - actual) <= actual * 0.08 else {
                throw CheckFailure(description: "\(rate) Mbps pacing target, \(actual) Mbps server, \(measured) Mbps measured; outside 8% tolerance.")
            }
            if rate == 150 && measured <= 130 {
                throw CheckFailure(description: "Genuine 150 Mbps transfer was incorrectly capped.")
            }
            if rate == 15 && measured >= 20 {
                throw CheckFailure(description: "15 Mbps transfer crossed the 20 Mbps alert threshold.")
            }
            print(String(format: "PASS target=%.1f Mbps server=%.3f Mbps measured=%.3f Mbps callback_stall=%@ bytes=%d",
                         rate, actual, measured, delayCallbacks ? "500ms" : "none", measurement.bytesReceived))
        }
        try await verifyAdaptiveBurst()
        print("All four paced loopback accuracy checks passed (8% tolerance, no internet).")
    }

    private static func verifyAdaptiveBurst() async throws {
        let confirmationBytes = 64 * 1_024 * 1_024
        let server = try PacedLoopbackServer(responses: [
            .init(bytes: SpeedProbe.downloadBytes, megabitsPerSecond: 250),
            .init(bytes: confirmationBytes, megabitsPerSecond: 100)
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let probe = SpeedProbe(configuration: configuration, endpoint: server.endpoint,
                               expectedBytes: SpeedProbe.downloadBytes, confirmationBytes: confirmationBytes)
        let measurement = await boundedMeasurement(probe, timeoutSeconds: 30)
        guard let measurement, let measured = measurement.megabitsPerSecond,
              measurement.errorDescription == nil,
              let transfers = server.waitForTransfers(count: 2), transfers.count == 2,
              transfers.allSatisfy({ $0.error == nil }),
              transfers.map(\.bytesSent) == [SpeedProbe.downloadBytes, confirmationBytes] else {
            throw CheckFailure(description: "Adaptive loopback confirmation did not complete both responses.")
        }
        let initial = transfers[0].megabitsPerSecond
        let actual = transfers[1].megabitsPerSecond
        let totalBytes = transfers.reduce(0) { $0 + $1.bytesSent }
        guard abs(initial - 250) <= 250 * 0.08, abs(actual - 100) <= 100 * 0.08,
              abs(measured - actual) <= actual * 0.08,
              measurement.bytesReceived == totalBytes else {
            throw CheckFailure(description: "Adaptive check expected 250 Mbps burst then 100 Mbps confirmation; got \(measured) Mbps, \(measurement.bytesReceived) total bytes.")
        }
        print(String(format: "PASS adaptive initial=%.3f Mbps confirmation=%.3f Mbps measured=%.3f Mbps total_bytes=%d (72MiB)",
                     initial, actual, measured, totalBytes))
    }

    private static func boundedMeasurement(_ probe: SpeedProbe, timeoutSeconds: UInt64 = 10) async -> Measurement? {
        await withTaskGroup(of: Measurement?.self) { group in
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
}
