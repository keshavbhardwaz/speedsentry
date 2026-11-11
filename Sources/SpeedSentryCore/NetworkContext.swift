import Foundation

/// Observed system path, not proof of the route used by an individual request.
public struct NetworkContext: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case wifi, ethernet, cellular, other }
    public let kind: Kind
    public let interfaceName: String?
    public let ssid: String?
    public let rssiDBm: Int?
    public let pathAvailable: Bool
    public let metered: Bool
    public let profileName: String
    public let thresholdMbps: Double

    public init(kind: Kind, interfaceName: String?, ssid: String? = nil, rssiDBm: Int? = nil,
                pathAvailable: Bool = true, metered: Bool = false, profileName: String = "Default", thresholdMbps: Double = 20) {
        self.kind = kind; self.interfaceName = interfaceName
        self.ssid = kind == .wifi && ssid?.isEmpty == false ? ssid : nil
        self.rssiDBm = kind == .wifi ? rssiDBm.flatMap { (-120 ... -1).contains($0) ? $0 : nil } : nil
        self.pathAvailable = pathAvailable; self.metered = metered
        self.profileName = profileName; self.thresholdMbps = thresholdMbps
    }

    /// RSSI fluctuations are samples, not network changes. A hidden SSID is never
    /// inferred from a manual profile or carried over from an earlier reading.
    public func hasSameIdentity(as other: NetworkContext) -> Bool {
        kind == other.kind && interfaceName == other.interfaceName && ssid == other.ssid
            && pathAvailable == other.pathAvailable && metered == other.metered
            && profileName == other.profileName && thresholdMbps == other.thresholdMbps
    }

    public var summary: String {
        let transport: String
        switch kind {
        case .wifi: transport = "Wi-Fi · SSID: \(ssid ?? "unavailable")"
        case .ethernet: transport = "Ethernet"
        case .cellular: transport = "Cellular"
        case .other: transport = "Other network"
        }
        return "\(transport) · Interface: \(interfaceName ?? "unavailable")"
            + (rssiDBm.map { " · \($0) dBm" } ?? "")
            + " · Profile: \(profileName) · Below \(thresholdMbps) Mbps"
            + (pathAvailable ? "" : " · Path unavailable") + (metered ? " · Metered" : "")
    }

    public var isValid: Bool {
        thresholdMbps.isFinite && thresholdMbps > 0
            && (rssiDBm.map { kind == .wifi && (-120 ... -1).contains($0) } ?? true)
            && (ssid == nil || kind == .wifi)
    }
}

public struct NetworkChange: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let previous: NetworkContext?
    public let current: NetworkContext
    public init(id: UUID = UUID(), timestamp: Date, previous: NetworkContext?, current: NetworkContext) {
        self.id = id; self.timestamp = timestamp; self.previous = previous; self.current = current
    }
    public var summary: String {
        previous.map { "Context changed: \($0.summary) → \(current.summary)" }
            ?? "Monitoring baseline: \(current.summary)"
    }
}
