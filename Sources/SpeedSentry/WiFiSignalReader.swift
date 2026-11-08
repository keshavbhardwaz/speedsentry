import Foundation
import CoreWLAN
import SpeedSentryCore

/// Reads the active interface only. No network scan, location request, network
/// switch or personal data upload is needed to obtain the current signal.
enum WiFiSignalReader {
    static func read(usingWiFi: Bool, interfaceName: String?) -> (reading: WiFiSignalReading, networkID: String) {
        guard usingWiFi else { return (WiFiSignalReading(state: .notUsingWiFi), "not-wifi") }
        guard let interface = CWWiFiClient.shared().interface(withName: interfaceName), interface.powerOn() else {
            return (WiFiSignalReading(state: .unavailable), interfaceName ?? "wifi")
        }
        let key = "\(interface.interfaceName ?? "wifi")|\(interface.ssid() ?? "hidden")"
        return (WiFiSignalReading(state: .connected, rssiDBm: interface.rssiValue()), key)
    }
}
