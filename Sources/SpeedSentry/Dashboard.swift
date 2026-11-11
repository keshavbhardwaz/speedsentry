import AppKit
import SwiftUI
import Charts
import SpeedSentryCore

@MainActor
final class DashboardModel: ObservableObject {
    @Published var history = HistorySnapshot()
    @Published var insights = InsightsSnapshot()
    @Published var threshold = 20.0
    @Published var wifi = WiFiSignalReading(state: .unavailable)
    @Published var wifiEpisode: WiFiWeakEpisode?
    @Published var days = 7
    @Published var day = Date()
}

@MainActor
struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    let export: (DailyReport) -> Void
    private var report: DailyReport { DailyReport(day: model.day, history: model.history, insights: model.insights) }
    var body: some View {
        let end = Date()
        let start = end.addingTimeInterval(-Double(model.days) * 86400)
        let samples = model.history.measurements.filter { $0.timestamp >= start && $0.timestamp <= end }
        let ticks = (0...4).map { start.addingTimeInterval(end.timeIntervalSince(start) * Double($0) / 4) }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Your connection, over time").font(.largeTitle.bold())
                        Text("Download history • all times IST").foregroundColor(.secondary)
                    }
                    Spacer()
                    Picker("History", selection: $model.days) {
                        Text("24 hours").tag(1); Text("7 days").tag(7); Text("30 days").tag(30)
                    }.frame(width: 160)
                }
                WiFiSignalCard(reading: model.wifi, warning: model.wifiEpisode != nil && model.wifi.rssiDBm != nil)
                if samples.isEmpty { Text("No download samples in this period. Run Check Now to get started.").padding() }
                else {
                    Chart {
                        ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                            if let speed = sample.megabitsPerSecond {
                                PointMark(x: .value("Time (IST)", sample.timestamp), y: .value("Download Mbps", speed))
                                    .foregroundStyle(speed < model.threshold ? Color.orange : Color.blue)
                            }
                        }
                        RuleMark(y: .value("Current alert threshold", model.threshold)).foregroundStyle(.orange.opacity(0.5))
                            .annotation(position: .top, alignment: .leading) { Text("Current threshold \(model.threshold, specifier: "%.0f") Mbps").font(.caption) }
                    }
                    // Auto-ranging a single timestamp produces a zero-width time
                    // domain and can omit every tick. Keep the selected history
                    // window visible even before a second sample arrives.
                    .chartXScale(domain: start...end)
                    .chartXAxis {
                        AxisMarks(values: ticks) { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(Self.axisTime(date))
                                        .multilineTextAlignment(.center)
                                }
                            }
                        }
                    }
                    .chartYAxisLabel("Mbps").chartXAxisLabel("Date and time (IST)")
                    .environment(\.timeZone, TimeZone(identifier: "Asia/Kolkata")!)
                    .frame(height: 230)
                    if let latest = samples.last(where: { $0.megabitsPerSecond != nil }) {
                        Text("Latest plotted sample: \(ISTDate.string(latest.timestamp))")
                            .font(.callout.monospacedDigit())
                            .textSelection(.enabled)
                    }
                    Text("Each dot is a successful test; unavailable tests have no speed value. Thresholds may differ by profile. All networks are included.").font(.caption).foregroundColor(.secondary)
                }
                Divider()
                HStack {
                    Text("Daily ISP report").font(.title2.bold())
                    Spacer()
                    DatePicker("Day (IST)", selection: $model.day, in: ...Date(), displayedComponents: .date)
                        .environment(\.timeZone, TimeZone(identifier: "Asia/Kolkata")!)
                        .frame(width: 230)
                    Button("Export report…") { export(report) }
                }
                HStack(spacing: 28) {
                    metric("Minimum Mbps", report.speeds.min())
                    metric("Median Mbps", report.median)
                    metric("Maximum Mbps", report.speeds.max())
                    VStack(alignment: .leading) {
                        Text("Connection checks").foregroundColor(.secondary)
                        Text("\(report.reachableChecks)/\(report.connectionChecks) reachable").font(.title3.monospacedDigit())
                    }
                }
                Text(report.text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Divider()
                Text("Recent speed incidents · network context").font(.title2.bold())
                if model.history.incidents.isEmpty { Text("No speed incidents recorded.").foregroundColor(.secondary) }
                ForEach(Array(model.history.incidents.suffix(30).reversed())) { incident in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(ISTDate.string(incident.startedAt)) · \(incident.kind == .slow ? "Slow download" : "Download unavailable")").font(.headline)
                        Text("At start: \(incident.startNetworkContext?.summary ?? "Network context not recorded")")
                        Text(incident.endedAt.map { "Recovered: \(ISTDate.string($0))" } ?? "Ongoing")
                        if incident.endedAt != nil { Text("At recovery: \(incident.endNetworkContext?.summary ?? "Network context not recorded")") }
                        incidentChanges(start: incident.startedAt, end: incident.endedAt)
                    }.font(.callout).textSelection(.enabled).padding(.vertical, 5)
                }
                Text("Recent connection outages").font(.title2.bold())
                if model.insights.outages.isEmpty { Text("No confirmed connection outages recorded.").foregroundColor(.secondary) }
                ForEach(Array(model.insights.outages.suffix(30).reversed())) { outage in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ISTDate.string(outage.startedAt)).font(.headline)
                        Text(outage.endedAt.map { "\(outage.interrupted ? "Observation ended" : "Recovered"): \(ISTDate.string($0))" } ?? "Ongoing")
                            .foregroundColor(.secondary)
                        Text("At start: \(outage.startNetworkContext?.summary ?? "Network context not recorded")")
                        if outage.endedAt != nil { Text("At end: \(outage.endNetworkContext?.summary ?? "Network context not recorded")") }
                        incidentChanges(start: outage.startedAt, end: outage.endedAt)
                    }.padding(.vertical, 3)
                }
                Text("Network/profile timeline (IST)").font(.title2.bold())
                Text("Observed path and Wi-Fi names help correlate changes; they do not prove the cause. Hidden SSIDs cannot reliably distinguish two Wi-Fi networks. Exports include observed network names.")
                    .font(.caption).foregroundColor(.secondary)
                ForEach(Array(model.insights.networkChanges.filter { $0.timestamp >= start && $0.timestamp <= end }.suffix(100).reversed())) { change in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ISTDate.string(change.timestamp)).font(.headline)
                        Text(change.summary).font(.callout)
                    }.textSelection(.enabled).padding(.vertical, 3)
                }
                Text("Recent uploads").font(.title2.bold())
                ForEach(Array(model.insights.uploads.suffix(10).reversed().enumerated()), id: \.offset) { _, upload in
                    Text("\(ISTDate.string(upload.timestamp)) · \(upload.megabitsPerSecond.map { String(format: "%.2f Mbps", $0) } ?? upload.errorDescription ?? "Unavailable")")
                }
            }.padding(28)
        }.frame(minWidth: 780, minHeight: 580)
    }
    @ViewBuilder private func incidentChanges(start: Date, end: Date?) -> some View {
        let changes = model.insights.networkChanges.filter { $0.timestamp >= start && $0.timestamp <= (end ?? Date()) }
        ForEach(Array(changes.suffix(20))) { change in
            Text("\(ISTDate.string(change.timestamp)) · \(change.summary)").foregroundColor(.secondary)
        }
        if changes.count > 20 { Text("Showing the most recent 20 context events; see the daily report for more.").font(.caption) }
    }
    private static func axisTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        formatter.dateFormat = "dd MMM\nHH:mm"
        return formatter.string(from: date)
    }
    private func metric(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading) {
            Text(title).foregroundColor(.secondary)
            Text(value.map { String(format: "%.1f", $0) } ?? "—").font(.title.monospacedDigit())
        }
    }
}
