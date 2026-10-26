import Foundation

struct TransportTiming: Equatable, Sendable {
    let durationSeconds: Double
    // Delivered/decoded payload bytes, excluding protocol framing; the probe validates identity encoding.
    let bytesReceived: Int64
    let isNetworkLoad: Bool
    let transactionCount: Int
}

struct ThroughputEstimate: Equatable, Sendable {
    let megabitsPerSecond: Double
    let durationSeconds: Double
    let source: String
}

enum ThroughputEstimationError: LocalizedError, Equatable {
    case invalidByteCount
    case invalidRequestDuration
    case nonNetworkLoad
    case invalidTransactionCount
    case transportByteCountMismatch
    case invalidTransportDuration
    case transportDurationExceedsRequest
    case invalidResult

    var errorDescription: String? {
        switch self {
        case .invalidByteCount:
            return "Speed check received no measurable payload."
        case .invalidRequestDuration:
            return "Speed check request duration is invalid or too short to measure reliably."
        case .nonNetworkLoad:
            return "Speed check was served from a cache or another non-network source."
        case .invalidTransactionCount:
            return "Speed check must contain exactly one network transaction."
        case .transportByteCountMismatch:
            return "Speed check transport byte count does not match the completed payload."
        case .invalidTransportDuration:
            return "Speed check transport duration is invalid or too short to measure reliably."
        case .transportDurationExceedsRequest:
            return "Speed check transport duration exceeds the measured request duration."
        case .invalidResult:
            return "Speed check could not produce a finite, positive download estimate."
        }
    }
}

enum ThroughputEstimator {
    // Reject sub-millisecond samples without imposing a speed limit on valid transfers.
    static let minimumDurationSeconds = 0.001

    static func estimate(
        bytesReceived: Int,
        requestDurationSeconds: Double,
        transport: TransportTiming?
    ) throws -> ThroughputEstimate {
        guard bytesReceived > 0 else { throw ThroughputEstimationError.invalidByteCount }
        guard validDuration(requestDurationSeconds) else {
            throw ThroughputEstimationError.invalidRequestDuration
        }

        let duration: Double
        let source: String
        if let transport {
            guard transport.isNetworkLoad else { throw ThroughputEstimationError.nonNetworkLoad }
            guard transport.transactionCount == 1 else { throw ThroughputEstimationError.invalidTransactionCount }
            guard transport.bytesReceived == Int64(bytesReceived) else {
                throw ThroughputEstimationError.transportByteCountMismatch
            }
            guard validDuration(transport.durationSeconds) else {
                throw ThroughputEstimationError.invalidTransportDuration
            }
            // Metrics use wall-clock dates; allow at most 1 ms or 1% clock granularity drift.
            let tolerance = max(0.001, requestDurationSeconds * 0.01)
            guard transport.durationSeconds - requestDurationSeconds <= tolerance else {
                throw ThroughputEstimationError.transportDurationExceedsRequest
            }
            duration = transport.durationSeconds
            source = "transport"
        } else {
            // The full request includes connection latency, making this fallback conservative.
            duration = requestDurationSeconds
            source = "request"
        }

        // Mbps is decimal megabits; completed payload bytes are never warmup-subtracted.
        let megabitsPerSecond = Double(bytesReceived) * 8 / duration / 1_000_000
        guard megabitsPerSecond.isFinite, megabitsPerSecond > 0 else {
            throw ThroughputEstimationError.invalidResult
        }
        return ThroughputEstimate(megabitsPerSecond: megabitsPerSecond, durationSeconds: duration, source: source)
    }

    private static func validDuration(_ seconds: Double) -> Bool {
        seconds.isFinite && seconds >= minimumDurationSeconds
    }
}
