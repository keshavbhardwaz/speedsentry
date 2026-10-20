import AppKit
import ServiceManagement
import SpeedSentryCore
@preconcurrency import UserNotifications
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let defaults = UserDefaults.standard
    private let probe = SpeedProbe()
    private var store: HistoryStore?
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?
    private var checkTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var notificationAuthorizationTask: Task<Void, Never>?
    private var pendingAutomaticCheck = false
    private var generation = 0
    private var isChecking = false
    private var isSleeping = false
    private var nextCheck: Date?
    private var lastAttempt: Date?
    private var latest: SpeedSentryCore.Measurement?
    private var storageError: String?
    private var notificationStatus: UNAuthorizationStatus = .notDetermined
    private var notificationError: String?
    // Preview exercises the real menu without network, settings, logs, or permission prompts.
    private let preview = CommandLine.arguments.contains("--preview")

    private var threshold: Double {
        get {
            let value = defaults.double(forKey: "alertThresholdMbps")
            return value.isFinite && value > 0 && value <= 10_000 ? value : 20
        }
        set { defaults.set(newValue, forKey: "alertThresholdMbps") }
    }

    private var interval: TimeInterval {
        get {
            let value = defaults.double(forKey: "checkIntervalSeconds")
            return [300.0, 600, 900, 1800, 3600].contains(value) ? value : 600
        }
        set { defaults.set(newValue, forKey: "checkIntervalSeconds") }
    }

    private var paused: Bool {
        get { preview || defaults.bool(forKey: "monitoringPaused") }
        set { if !preview { defaults.set(newValue, forKey: "monitoringPaused") } }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent duplicate probes and concurrent writes when a second copy is opened.
        if let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        statusItem.menu = menu
        menu.delegate = self
        menu.autoenablesItems = false
        if !preview {
            do {
                store = try HistoryStore(directoryURL: HistoryStore.defaultDirectoryURL)
                latest = store?.history.measurements.last
            } catch {
                storageError = error.localizedDescription
            }
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            refreshNotificationStatus()
        } else {
            latest = Measurement(timestamp: Date(), megabitsPerSecond: 47.8, bytesReceived: 8_388_608, errorDescription: nil)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        render()
        rebuildMenu()
        if preview { return }
        if let error = storageError {
            showError("Monitoring could not start", "SpeedSentry could not open its history. Your existing files have been preserved.\n\n\(error)\n\nUse Open Log Folder to inspect or back up the files, then restart the app.")
            return
        }
        requestNotifications(openSettingsIfDenied: false)
        if !paused { checkNow() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        generation += 1
        pendingAutomaticCheck = false
        timer?.invalidate()
        wakeTask?.cancel()
        checkTask?.cancel()
        probe.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        if !preview { refreshNotificationStatus() }
    }

    private func render() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        let title: String
        let color: NSColor
        if paused || isSleeping {
            symbol = "pause.circle"
            title = preview ? "47.8" : "Paused"
            color = .secondaryLabelColor
        } else if isChecking {
            symbol = "arrow.triangle.2.circlepath"
            title = "…"
            color = .labelColor
        } else if storageError != nil {
            symbol = "exclamationmark.triangle"
            title = "Log!"
            color = .systemOrange
        } else if let result = latest {
            if let speed = result.megabitsPerSecond {
                symbol = speed < threshold ? "exclamationmark.triangle.fill" : "arrow.down.circle"
                title = Self.speed(speed, threshold: threshold)
                color = speed < threshold ? .systemOrange : .labelColor
            } else {
                symbol = "wifi.exclamationmark"
                title = "Error"
                color = .systemRed
            }
        } else {
            symbol = "speedometer"
            title = "—"
            color = .labelColor
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "SpeedSentry download speed")
        button.imagePosition = .imageLeading
        button.contentTintColor = color
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.title = " \(title)"
        button.setAccessibilityLabel("SpeedSentry: \(title) megabits per second")
        let last = latest.map { ISTDate.string($0.timestamp) } ?? "No checks yet"
        button.toolTip = "SpeedSentry · Download Mbps\nLast check: \(last)\nAlert below \(Self.thresholdText(threshold)) Mbps · Every \(Int(interval / 60)) minutes"
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        label("SpeedSentry", bold: true)
        if let result = latest {
            label(result.megabitsPerSecond.map { "Download: \(Self.speed($0, threshold: threshold)) Mbps" } ?? "Download check unavailable")
            label("Checked: \(ISTDate.string(result.timestamp))")
            if let failure = result.errorDescription { label(String(failure.prefix(110))) }
        } else {
            label("Download: waiting for first check")
        }
        if let error = storageError { label("Logging error: \(String(error.prefix(90)))") }
        if isChecking { label("Checking now…") }
        else if paused { label(preview ? "Preview · monitoring paused" : "Monitoring paused") }
        else if let date = nextCheck { label("Next: \(ISTDate.string(date))") }
        menu.addItem(.separator())
        action("Check Now", #selector(manualCheck), key: "r", enabled: !isChecking && !preview && store != nil)
        action(paused ? "Resume Monitoring" : "Pause Monitoring", #selector(togglePause), enabled: !preview && store != nil)
        menu.addItem(.separator())
        let incidents = NSMenu()
        let recentIncidents = Array((store?.history.incidents ?? []).suffix(8).reversed())
        for incident in recentIncidents {
            let state = incident.endedAt == nil ? "Ongoing" : "Recovered"
            let low = incident.lowestMbps.map { " · low \(Self.speed($0, threshold: incident.thresholdMbps)) Mbps" } ?? " · unavailable"
            let item = NSMenuItem(title: "\(ISTDate.string(incident.startedAt))\(low) · \(state)", action: nil, keyEquivalent: "")
            let detail = NSMenu()
            detail.autoenablesItems = false
            label("Started: \(ISTDate.string(incident.startedAt))", to: detail)
            label(incident.endedAt.map { "Recovered: \(ISTDate.string($0))" } ?? "Recovery not yet observed", to: detail)
            item.submenu = detail
            incidents.addItem(item)
        }
        if incidents.items.isEmpty { label("No incidents recorded", to: incidents) }
        submenu("Recent Incidents (IST)", incidents)
        action("Export History as CSV…", #selector(exportHistory), enabled: store != nil)
        action("Open Log Folder", #selector(openLogs), enabled: !preview)
        menu.addItem(.separator())
        let thresholds = NSMenu()
        for value in [10, 20, 50, 100] {
            let item = NSMenuItem(title: "\(value) Mbps", action: #selector(setThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value
            item.state = threshold == Double(value) ? .on : .off
            item.isEnabled = !preview
            thresholds.addItem(item)
        }
        let custom = NSMenuItem(title: "Custom…", action: #selector(customThreshold), keyEquivalent: "")
        custom.target = self
        custom.isEnabled = !preview
        thresholds.addItem(custom)
        submenu("Alert Below: \(Self.thresholdText(threshold)) Mbps", thresholds)
        let intervals = NSMenu()
        for minutes in [5, 10, 15, 30, 60] {
            let item = NSMenuItem(title: "\(minutes) minutes", action: #selector(setInterval(_:)), keyEquivalent: "")
            item.target = self
            item.tag = minutes
            item.state = interval == Double(minutes * 60) ? .on : .off
            item.isEnabled = !preview
            intervals.addItem(item)
        }
        submenu("Check Every: \(Int(interval / 60)) Minutes", intervals)
        action("Launch at Login", #selector(toggleLogin), enabled: !preview,
               checked: !preview && SMAppService.mainApp.status == .enabled)
        let notificationsTitle: String
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: notificationsTitle = "Notifications: Allowed…"
        case .denied: notificationsTitle = "Notifications: Off — Enable…"
        default: notificationsTitle = "Enable Notifications…"
        }
        action(notificationsTitle, #selector(notificationPreferences), enabled: !preview)
        if let error = notificationError { label("Notification error: \(String(error.prefix(80)))") }
        menu.addItem(.separator())
        action("About SpeedSentry", #selector(about))
        action("Quit SpeedSentry", #selector(quit), key: "q")
    }

    private func label(_ title: String, bold: Bool = false, to targetMenu: NSMenu? = nil) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if bold { item.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]) }
        (targetMenu ?? menu).addItem(item)
    }

    private func action(_ title: String, _ selector: Selector, key: String = "", enabled: Bool = true, checked: Bool = false) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        item.state = checked ? .on : .off
        menu.addItem(item)
    }

    private func submenu(_ title: String, _ submenu: NSMenu) {
        submenu.autoenablesItems = false
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    private func scheduleNext(from date: Date = Date()) {
        timer?.invalidate()
        nextCheck = nil
        guard !paused, !isSleeping, storageError == nil, store != nil else { return }
        let target = date.addingTimeInterval(interval)
        nextCheck = target
        let scheduled = Timer(fire: max(target, Date().addingTimeInterval(1)), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.requestAutomaticCheck()
            }
        }
        scheduled.tolerance = 10
        RunLoop.main.add(scheduled, forMode: .common)
        timer = scheduled
    }

    private func checkNow() {
        guard !preview, !isSleeping, !isChecking, store != nil else { return }
        isChecking = true
        lastAttempt = Date()
        if !paused { scheduleNext(from: lastAttempt!) }
        let currentGeneration = generation
        render()
        checkTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.probe.measure()
            defer { self.finishCheck() }
            guard !Task.isCancelled, currentGeneration == self.generation else { return }
            self.latest = result
            do {
                let event = try self.store?.record(result, thresholdMbps: self.threshold)
                self.storageError = nil
                if self.nextCheck == nil { self.scheduleNext(from: self.lastAttempt ?? Date()) }
                if let event { self.notify(event) }
            } catch {
                self.timer?.invalidate()
                self.nextCheck = nil
                self.storageError = error.localizedDescription
                self.showError("History could not be saved", "Automatic monitoring has stopped so incidents are not lost silently. Check available disk space and the log folder, then use Check Now to retry or restart SpeedSentry.\n\n\(error.localizedDescription)")
            }
            self.render()
        }
    }

    @objc private func manualCheck() { checkNow() }

    private func requestAutomaticCheck() {
        guard !preview, !paused, !isSleeping, storageError == nil, store != nil else { return }
        if isChecking { pendingAutomaticCheck = true }
        else { checkNow() }
    }

    private func finishCheck() {
        isChecking = false
        checkTask = nil
        render()
        if pendingAutomaticCheck {
            pendingAutomaticCheck = false
            requestAutomaticCheck()
        }
    }

    @objc private func togglePause() {
        guard !preview else { return }
        paused.toggle()
        wakeTask?.cancel()
        if paused {
            generation += 1
            pendingAutomaticCheck = false
            timer?.invalidate()
            nextCheck = nil
            checkTask?.cancel()
            probe.cancel()
        } else {
            // If cancellation is still unwinding, finishCheck starts the pending check.
            requestAutomaticCheck()
        }
        render()
    }

    @objc private func willSleep() {
        isSleeping = true
        generation += 1
        pendingAutomaticCheck = false
        wakeTask?.cancel()
        checkTask?.cancel()
        probe.cancel()
        timer?.invalidate()
        nextCheck = nil
        render()
    }

    @objc private func didWake() {
        isSleeping = false
        wakeTask?.cancel()
        guard !paused, storageError == nil else { render(); return }
        let wakeGeneration = generation
        wakeTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 3_000_000_000) }
            catch { return }
            guard let self, !self.paused, !self.isSleeping, self.generation == wakeGeneration, self.storageError == nil else { return }
            self.wakeTask = nil
            if self.isChecking { self.requestAutomaticCheck() }
            else if let last = self.lastAttempt, Date().timeIntervalSince(last) < self.interval {
                self.scheduleNext(from: last)
            } else { self.requestAutomaticCheck() }
            self.render()
        }
    }

    @objc private func setThreshold(_ sender: NSMenuItem) {
        guard !preview else { return }
        threshold = Double(sender.tag)
        render()
        // Existing episodes retain the threshold that opened them; classify on the next check.
    }

    @objc private func customThreshold() {
        guard !preview else { return }
        let alert = NSAlert()
        alert.messageText = "Alert threshold in Mbps"
        alert.informativeText = "Notify when a download sample falls strictly below this value. The new threshold applies to the next check."
        let field = NSTextField(string: Self.thresholdText(threshold))
        field.frame = NSRect(x: 0, y: 0, width: 250, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let value = Double(field.stringValue), value.isFinite, value > 0, value <= 10_000 else {
            showError("Invalid threshold", "Enter a number greater than 0 and up to 10,000 Mbps.")
            return
        }
        threshold = value
        render()
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard !preview else { return }
        interval = Double(sender.tag * 60)
        scheduleNext(from: lastAttempt ?? Date())
        render()
    }

    @objc private func exportHistory() {
        guard let store else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SpeedSentry-history-IST.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.exportCSV(to: url) }
        catch { showError("Export failed", error.localizedDescription) }
    }

    @objc private func openLogs() { NSWorkspace.shared.open(HistoryStore.defaultDirectoryURL) }

    @objc private func toggleLogin() {
        guard !preview else { return }
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { showError("Could not change Launch at Login", "Keep SpeedSentry in Applications, then try again.\n\n\(error.localizedDescription)") }
    }

    private func refreshNotificationStatus() {
        Task { [weak self] in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            self?.notificationStatus = settings.authorizationStatus
        }
    }

    private func requestNotifications(openSettingsIfDenied: Bool) {
        guard !preview, notificationAuthorizationTask == nil else { return }
        notificationAuthorizationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.notificationAuthorizationTask = nil }
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                do {
                    _ = try await center.requestAuthorization(options: [.alert, .sound])
                    self.notificationError = nil
                } catch {
                    self.notificationError = error.localizedDescription
                }
                self.notificationStatus = await center.notificationSettings().authorizationStatus
            } else {
                self.notificationStatus = settings.authorizationStatus
                if openSettingsIfDenied, let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications?id=app.speedsentry.mac") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    @objc private func notificationPreferences() { requestNotifications(openSettingsIfDenied: true) }

    private func notify(_ event: IncidentEvent) {
        let permissionTask = notificationAuthorizationTask
        let recoverySpeed = latest?.megabitsPerSecond
        Task { [weak self] in
            // Keep the first incident alert until the startup permission prompt resolves.
            await permissionTask?.value
            guard let self else { return }
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            self.notificationStatus = settings.authorizationStatus
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            let identifier: String
            switch event {
            case .started(let incident):
                identifier = "incident-\(incident.id.uuidString)"
                content.title = incident.kind == .unavailable ? "Internet speed check unavailable" : "Internet speed dropped"
                let speed = incident.lowestMbps.map {
                    "Download: \(Self.speed($0, threshold: incident.thresholdMbps)) Mbps (alert threshold: \(Self.thresholdText(incident.thresholdMbps)) Mbps)."
                } ?? "Could not measure download speed. Check your connection or try again."
                content.body = "\(speed)\nObserved: \(ISTDate.string(incident.startedAt))"
                content.sound = .default
            case .recovered(let incident):
                identifier = "recovery-\(incident.id.uuidString)"
                content.title = "Internet speed recovered"
                let speed = recoverySpeed.map { "Download: \(Self.speed($0, threshold: self.threshold)) Mbps. " } ?? ""
                content.body = "\(speed)Observed: \(ISTDate.string(incident.endedAt ?? Date()))"
            }
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
                self.notificationError = nil
            } catch {
                self.notificationError = error.localizedDescription
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    @objc private func about() {
        let alert = NSAlert()
        alert.messageText = "SpeedSentry \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")"
        alert.informativeText = "A lightweight download speed monitor for your menu bar.\n\nDefault: every 10 minutes; alert below 20 Mbps. Each check downloads up to 8 MiB from Cloudflare (about 1.2 GB/day if awake all day).\n\nThis is a sampled, single-connection estimate. Brief drops between checks may be missed. No checks run during sleep. Failed probes mean the check was unavailable; they do not prove an ISP outage.\n\nHistory stays on this Mac for 90 days. All displayed/exported incident times use IST (Asia/Kolkata). Cloudflare receives your IP as the test provider.\n\nHold Command and drag the menu bar item to reposition it. macOS controls its exact placement."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func showError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func speed(_ value: Double, threshold: Double? = nil) -> String {
        let formatted = String(format: value >= 100 ? "%.0f" : "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
        if let threshold, let rounded = Double(formatted), (value < threshold) != (rounded < threshold) {
            return (value < threshold ? "<" : "≥") + thresholdText(threshold)
        }
        return formatted
    }

    private static func thresholdText(_ value: Double) -> String {
        let text = String(value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}
