import AppKit
import SwiftUI
import SpeedSentryCore

@MainActor
struct WiFiSignalCard: View {
    let reading: WiFiSignalReading
    let warning: Bool
    var body: some View {
        let poor = warning || (reading.rssiDBm.map { $0 <= -75 } ?? false)
        HStack(spacing: 16) {
            Image(systemName: poor ? "wifi.exclamationmark" : "wifi").font(.system(size: 26))
                .foregroundColor(poor ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Wi-Fi signal: \(reading.summary)").font(.headline)
                Text("Checked: \(ISTDate.string(reading.timestamp))").font(.caption).foregroundColor(.secondary)
                if warning { Text("Move closer to your Wi-Fi access point or switch to a stronger network.").foregroundColor(.orange) }
                else if reading.rssiDBm != nil { Text("Closer to 0 dBm means stronger reception. Signal strength is separate from internet speed.").font(.caption).foregroundColor(.secondary) }
            }
            Spacer()
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(index < reading.bars ? (poor ? Color.orange : Color.green) : Color.secondary.opacity(0.2))
                        .frame(width: 8, height: CGFloat(10 + index * 7))
                }
            }.accessibilityLabel(reading.summary)
        }.padding(16).background(Color.secondary.opacity(0.08)).cornerRadius(12)
    }
}

@MainActor
struct WiFiWeakWarningView: View {
    @ObservedObject var model: DashboardModel
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 18) {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 46)).foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your Wi-Fi signal is weak").font(.system(size: 27, weight: .bold))
                    Text(model.wifi.summary).font(.title3.monospacedDigit())
                }
            }
            Text("Move back into your Wi-Fi access area, closer to the router or access point. If you cannot move closer, switch to a stronger Wi-Fi network.")
                .font(.system(size: 17)).fixedSize(horizontal: false, vertical: true)
            if let episode = model.wifiEpisode {
                Text("First observed: \(ISTDate.string(episode.startedAt))").font(.callout).foregroundColor(.secondary)
            }
            HStack {
                Text("This alert closes when the signal recovers.").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Dismiss", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 540)
    }
}
