import AppKit
import SpeedSentryCore

if CommandLine.arguments.contains("--version") {
    print("SpeedSentry \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.1")")
} else if CommandLine.arguments.contains("--probe-once") {
    // A diagnostic command: one real, capped download, no app or notification permission.
    Task {
        let result = await SpeedProbe().measure()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(result), let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        exit(result.megabitsPerSecond == nil ? 1 : 0)
    }
    dispatchMain()
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
