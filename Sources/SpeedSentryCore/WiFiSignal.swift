import Foundation

public enum WiFiSignalState: String, Sendable { case connected, unavailable, notUsingWiFi, paused }

public struct WiFiSignalReading: Equatable, Sendable {
    public let timestamp: Date
    public let state: WiFiSignalState
    public let rssiDBm: Int?

    public init(timestamp: Date = Date(), state: WiFiSignalState, rssiDBm: Int? = nil) {
        self.timestamp = timestamp
        // CoreWLAN returns zero for errors/disassociation. Never treat that as a strong signal.
        let valid = rssiDBm.flatMap { (-120 ... -1).contains($0) ? $0 : nil }
        self.state = state == .connected && valid == nil ? .unavailable : state
        self.rssiDBm = state == .connected ? valid : nil
    }
    public var quality: String {
        guard let rssi = rssiDBm else {
            switch state {
            case .paused: return "Monitoring paused"
            case .notUsingWiFi: return "Wi-Fi is not the active connection"
            default: return "Signal unavailable from macOS"
            }
        }
        switch rssi {
        case -55 ... -1: return "Excellent"
        case -67 ... -56: return "Good"
        case -74 ... -68: return "Fair"
        case -84 ... -75: return "Weak"
        default: return "Very weak"
        }
    }
    public var bars: Int {
        guard let rssi = rssiDBm else { return 0 }
        if rssi >= -55 { return 4 }; if rssi >= -67 { return 3 }; if rssi >= -74 { return 2 }
        return rssi >= -84 ? 1 : 0
    }
    public var summary: String { rssiDBm.map { "\(quality) · \($0) dBm" } ?? quality }
}

public struct WiFiWeakEpisode: Equatable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let rssiDBm: Int
}
public enum WiFiSignalEvent: Equatable { case started(WiFiWeakEpisode), recovered }

/// Debounces readings and latches a warning until a sustained recovery. Unknown
/// readings never count as a recovery and never generate an alert on their own.
public struct WiFiSignalPolicy {
    public let weakThresholdDBm: Int
    public var recoveryThresholdDBm: Int { weakThresholdDBm + 8 }
    public private(set) var activeEpisode: WiFiWeakEpisode?
    private var pendingWeakAt: Date?
    private var pendingRecoveryAt: Date?
    private var lastSampleAt: Date?
    private var networkID: String?

    public init(weakThresholdDBm: Int = -75) {
        self.weakThresholdDBm = [-70, -75, -80].contains(weakThresholdDBm) ? weakThresholdDBm : -75
    }
    public mutating func reset() {
        activeEpisode = nil; pendingWeakAt = nil; pendingRecoveryAt = nil
        lastSampleAt = nil; networkID = nil
    }
    @discardableResult
    public mutating func observe(_ reading: WiFiSignalReading, networkID: String) -> WiFiSignalEvent? {
        if self.networkID != networkID { reset(); self.networkID = networkID }
        if reading.state == .paused || reading.state == .notUsingWiFi { reset(); return nil }
        if let last = lastSampleAt {
            let gap = reading.timestamp.timeIntervalSince(last)
            if gap <= 0 || gap > 25 { pendingWeakAt = nil; pendingRecoveryAt = nil }
        }
        lastSampleAt = reading.timestamp
        guard reading.timestamp.timeIntervalSince1970.isFinite, let rssi = reading.rssiDBm else {
            pendingWeakAt = nil; pendingRecoveryAt = nil; return nil
        }
        if activeEpisode == nil {
            if rssi <= weakThresholdDBm {
                if let since = pendingWeakAt, reading.timestamp.timeIntervalSince(since) >= 8 {
                    let episode = WiFiWeakEpisode(id: UUID(), startedAt: since, rssiDBm: rssi)
                    activeEpisode = episode; pendingWeakAt = nil; return .started(episode)
                }
                if pendingWeakAt == nil { pendingWeakAt = reading.timestamp }
            } else { pendingWeakAt = nil }
        } else {
            if rssi >= recoveryThresholdDBm {
                if let since = pendingRecoveryAt, reading.timestamp.timeIntervalSince(since) >= 8 {
                    activeEpisode = nil; pendingRecoveryAt = nil; return .recovered
                }
                if pendingRecoveryAt == nil { pendingRecoveryAt = reading.timestamp }
            } else { pendingRecoveryAt = nil }
        }
        return nil
    }
}
