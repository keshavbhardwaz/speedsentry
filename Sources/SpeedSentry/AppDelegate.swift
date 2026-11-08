import AppKit
import SwiftUI
import Network
import CoreWLAN
import ServiceManagement
import SpeedSentryCore
@preconcurrency import UserNotifications
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let defaults = UserDefaults.standard
    private var probe = SpeedProbe()
    private var insights: InsightsStore?
    private var connectionTimer: Timer?
    private var connectionTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private var networkName = "Detecting network"
    private var currentSSID: String?
    private var networkIdentity: String?
    private var expensiveNetwork = false
    private var connectionFailures = 0
    private var latestConnection: ConnectionSample?
    private var usingWiFi = false
    private var wifiInterfaceName: String?
    private var wifiTimer: Timer?
    private var wifiReading = WiFiSignalReading(state: .unavailable)
    private var wifiPolicy = WiFiSignalPolicy()
    private var wifiWarningPanel: NSPanel?
    private var wifiAlertsEnabled: Bool {
        get { defaults.object(forKey: "wifiSignalAlertsEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "wifiSignalAlertsEnabled") }
    }
    private var wifiThreshold: Int {
        get { let value = defaults.integer(forKey: "wifiWeakThresholdDBm"); return [-70, -75, -80].contains(value) ? value : -75 }
        set { defaults.set(newValue, forKey: "wifiWeakThresholdDBm") }
    }
    private var wifiIsWeak: Bool { wifiPolicy.activeEpisode != nil && wifiReading.rssiDBm != nil }
    private var dashboardWindow: NSWindow?
    private let dashboardModel = DashboardModel()
    private var smartSchedule: Bool {
        get { defaults.bool(forKey: "smartSchedule") }
        set { defaults.set(newValue, forKey: "smartSchedule") }
    }
    private var profiles: [NetworkProfile] {
        get { (defaults.data(forKey: "networkProfiles").flatMap { try? JSONDecoder().decode([NetworkProfile].self, from: $0) } ?? []).filter(\.isValid) }
        set { if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: "networkProfiles") } }
    }
    private var activeProfile: NetworkProfile? {
        MonitoringPolicy.profile(profiles: profiles, ssid: currentSSID,
            manualID: defaults.string(forKey: "manualProfileID").flatMap(UUID.init(uuidString:)))
    }
    private var effectiveThreshold: Double { activeProfile?.thresholdMbps ?? threshold }
    private var speedTestsBlocked: Bool { activeProfile?.pauseSpeedTests == true || expensiveNetwork }
    private var effectiveInterval: TimeInterval { MonitoringPolicy.speedInterval(smart: smartSchedule, configured: interval) }
    private var stale: Bool { MonitoringPolicy.isStale(latest?.timestamp, now: Date(), interval: effectiveInterval) }
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
    private let preview = CommandLine.arguments.contains("--preview") || Bundle.main.bundleIdentifier?.hasSuffix(".preview") == true

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

    private var lowDataMode: Bool {
        get { defaults.bool(forKey: "lowDataMode") }
        set { if !preview { defaults.set(newValue, forKey: "lowDataMode") } }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent duplicate probes and concurrent writes when a second copy is opened.
        if !preview, let identifier = Bundle.main.bundleIdentifier,
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
                insights = try InsightsStore(directoryURL: HistoryStore.defaultDirectoryURL)
                lastAttempt = latest?.timestamp
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
        if preview { showDashboard(); return }
        if let error = storageError {
            showError("Monitoring could not start", "SpeedSentry could not open its history. Your existing files have been preserved.\n\n\(error)\n\nUse Open Log Folder to inspect or back up the files, then restart the app.")
            return
        }
        requestNotifications(openSettingsIfDenied: false)
        startNetworkMonitoring()
        // First path update starts monitoring after metered-network policy is known.
    }

    func applicationWillTerminate(_ notification: Notification) {
        generation += 1
        pendingAutomaticCheck = false
        timer?.invalidate()
        wakeTask?.cancel()
        checkTask?.cancel()
        probe.cancel()
        connectionTask?.cancel(); uploadTask?.cancel(); connectionTimer?.invalidate(); pathMonitor.cancel()
        wifiTimer?.invalidate(); wifiWarningPanel?.orderOut(nil)
        try? insights?.interrupt()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func menuWillOpen(_ menu: NSMenu) {
        if !preview, !paused, !isSleeping { updateWiFiSignal() }
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
        } else if uploadTask != nil {
            symbol = "arrow.up.circle"; title = "↑…"; color = .labelColor
        } else if connectionFailures >= 2 {
            symbol = "wifi.exclamationmark"; title = "Offline?"; color = .systemRed
        } else if storageError != nil {
            symbol = "exclamationmark.triangle"
            title = "Log!"
            color = .systemOrange
        } else if let result = latest {
            if let speed = result.megabitsPerSecond {
                symbol = speed < effectiveThreshold ? "exclamationmark.triangle.fill" : "arrow.down.circle"
                title = Self.speed(speed, threshold: effectiveThreshold) + (stale ? " ·" : "")
                color = speed < effectiveThreshold ? .systemOrange : .labelColor
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
        let displaySymbol = wifiIsWeak && !paused && !isSleeping && storageError == nil && connectionFailures < 2 ? "wifi.exclamationmark" : symbol
        button.image = NSImage(systemSymbolName: displaySymbol, accessibilityDescription: "SpeedSentry download speed")
        button.imagePosition = .imageLeading
        button.contentTintColor = wifiIsWeak && !paused && !isSleeping ? .systemOrange : color
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.title = " \(title)\(wifiIsWeak && !paused && !isSleeping ? " · Wi-Fi!" : "")"
        button.setAccessibilityLabel("SpeedSentry: \(title)\(stale ? ", stale result" : ""), Wi-Fi: \(wifiReading.summary)")
        let last = latest.map { ISTDate.string($0.timestamp) } ?? "No checks yet"
        button.toolTip = "SpeedSentry · Download Mbps\nLast check: \(last)\nAlert below \(Self.thresholdText(effectiveThreshold)) Mbps · Every \(Int(effectiveInterval / 60)) minutes\n\(stale ? "Result is stale" : "Result is recent") · \(networkName)\nWi-Fi signal: \(wifiReading.summary)"
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        label("SpeedSentry", bold: true)
        label("Wi-Fi signal: \(wifiReading.summary)")
        if wifiIsWeak { label("Move closer to the access point or switch Wi-Fi networks") }
        label("Network: \(networkName) · Profile: \(activeProfile?.name ?? "Default")")
        if speedTestsBlocked { label("Full tests paused on this profile or metered network") }
        if stale, latest != nil { label("Download result is stale · run Check Now to refresh") }
        if let connection = latestConnection {
            label(connection.reachable ? "HTTPS response: \(Int(connection.latencyMilliseconds ?? 0)) ms" : "Connection check: both endpoints unreachable")
            label("Connection checked: \(ISTDate.string(connection.timestamp))")
        }
        if let upload = insights?.snapshot.uploads.last {
            label("Last upload: \(upload.megabitsPerSecond.map { String(format: "%.1f Mbps", $0) } ?? "Unavailable") · \(ISTDate.string(upload.timestamp))")
        }
        if let result = latest {
            label(result.megabitsPerSecond.map { "Download: \(Self.speed($0, threshold: effectiveThreshold)) Mbps" } ?? "Download check unavailable")
            label("Checked: \(ISTDate.string(result.timestamp))")
            if let failure = result.errorDescription { label(String(failure.prefix(110))) }
        } else {
            label("Download: waiting for first check")
        }
        if activeProfile != nil { label("Alert threshold from active profile: \(Self.thresholdText(effectiveThreshold)) Mbps") }
        if let error = storageError { label("Logging error: \(String(error.prefix(90)))") }
        if isChecking { label("Checking now…") }
        else if paused { label(preview ? "Preview · monitoring paused" : "Monitoring paused") }
        else if let date = nextCheck { label("Next: \(ISTDate.string(date))") }
        menu.addItem(.separator())
        action("Check Now", #selector(manualCheck), key: "r", enabled: !isChecking && uploadTask == nil && !speedTestsBlocked && !preview && store != nil && insights != nil)
        action("Test Upload Now (4 MiB)", #selector(testUpload), enabled: !preview && !isChecking && uploadTask == nil && !speedTestsBlocked && store != nil)
        action("History & Daily Reports…", #selector(showDashboard))
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
        submenu("Default Alert Below: \(Self.thresholdText(threshold)) Mbps", thresholds)
        let intervals = NSMenu()
        for minutes in [5, 10, 15, 30, 60] {
            let item = NSMenuItem(title: "\(minutes) minutes", action: #selector(setInterval(_:)), keyEquivalent: "")
            item.target = self
            item.tag = minutes
            item.state = interval == Double(minutes * 60) ? .on : .off
            item.isEnabled = !preview
            intervals.addItem(item)
        }
        submenu("Fixed Schedule: \(Int(interval / 60)) Minutes", intervals)
        action("Smart Schedule (hourly speed, minute connection)", #selector(toggleSmartSchedule), enabled: !preview, checked: smartSchedule)
        let profileMenu = NSMenu()
        let defaultProfile = NSMenuItem(title: "Default (global threshold)", action: #selector(selectProfile(_:)), keyEquivalent: "")
        defaultProfile.target = self; defaultProfile.representedObject = ""; defaultProfile.state = activeProfile == nil ? .on : .off
        profileMenu.addItem(defaultProfile)
        for profile in profiles {
            let item = NSMenuItem(title: "\(profile.name) · \(Self.thresholdText(profile.thresholdMbps)) Mbps\(profile.pauseSpeedTests ? " · tests paused" : "")", action: #selector(selectProfile(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = profile.id.uuidString; item.state = activeProfile?.id == profile.id ? .on : .off
            profileMenu.addItem(item)
        }
        submenu("Network Profiles", profileMenu)
        action("Add / Edit Current Network Profile…", #selector(editProfile), enabled: !preview)
        action("Delete Active Profile", #selector(deleteProfile), enabled: !preview && activeProfile != nil)
        action("Wi-Fi Signal Alerts", #selector(toggleWiFiAlerts), enabled: !preview, checked: wifiAlertsEnabled)
        let wifiThresholds = NSMenu()
        for value in [-70, -75, -80] {
            let item = NSMenuItem(title: "\(value) dBm or lower", action: #selector(setWiFiThreshold(_:)), keyEquivalent: "")
            item.target = self; item.tag = value; item.state = wifiThreshold == value ? .on : .off; item.isEnabled = !preview
            wifiThresholds.addItem(item)
        }
        submenu("Weak Wi-Fi Alert: \(wifiThreshold) dBm", wifiThresholds)
        action("Low Data Mode", #selector(toggleLowDataMode), enabled: !preview, checked: lowDataMode)
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
        guard !paused, !isSleeping, storageError == nil, store != nil, !speedTestsBlocked else { return }
        let target = date.addingTimeInterval(effectiveInterval)
        nextCheck = target
        let scheduled = Timer(fire: max(target, Date().addingTimeInterval(1)), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.requestAutomaticCheck()
            }
        }
        scheduled.tolerance = 10
        RunLoop.main.add(scheduled, forMode: .common)
        timer = scheduled
    }

    private func checkNow() {
        guard !preview, !isSleeping, !isChecking, uploadTask == nil, !speedTestsBlocked, store != nil, insights != nil else { return }
        connectionTask?.cancel(); connectionTask = nil
        probe = SpeedProbe(lowDataMode: lowDataMode)
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
                let event = try self.store?.record(result, thresholdMbps: self.effectiveThreshold)
                self.storageError = nil
                if self.nextCheck == nil { self.scheduleNext(from: self.lastAttempt ?? Date()) }
                if let event { self.notify(event) }
            } catch {
                self.timer?.invalidate()
                self.nextCheck = nil
                self.storageError = error.localizedDescription
                self.showError("History could not be saved", "Automatic monitoring has stopped so incidents are not lost silently. Check available disk space and the log folder, then use Check Now to retry or restart SpeedSentry.\n\n\(error.localizedDescription)")
            }
            self.refreshDashboard()
            self.render()
        }
    }

    @objc private func manualCheck() { checkNow() }

    @objc private func toggleLowDataMode() {
        lowDataMode.toggle()
        // Apply to the next check; never replace or cancel an in-flight probe.
        render()
    }

    private func requestAutomaticCheck() {
        guard !preview, !paused, !isSleeping, storageError == nil, store != nil, !speedTestsBlocked else { return }
        if uploadTask != nil { pendingAutomaticCheck = true; return }
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
            stopConnectionMonitoring()
            generation += 1
            pendingAutomaticCheck = false
            timer?.invalidate()
            nextCheck = nil
            checkTask?.cancel()
            probe.cancel()
        } else {
            startConnectionMonitoring()
            // If cancellation is still unwinding, finishCheck starts the pending check.
            requestAutomaticCheck()
        }
        render()
    }

    @objc private func willSleep() {
        isSleeping = true
        stopConnectionMonitoring()
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
        startConnectionMonitoring()
        let wakeGeneration = generation
        wakeTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 3_000_000_000) }
            catch { return }
            guard let self, !self.paused, !self.isSleeping, self.generation == wakeGeneration, self.storageError == nil else { return }
            self.wakeTask = nil
            if self.isChecking { self.requestAutomaticCheck() }
            else if let last = self.lastAttempt, Date().timeIntervalSince(last) < self.effectiveInterval {
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
                let speed = recoverySpeed.map { "Download: \(Self.speed($0, threshold: self.effectiveThreshold)) Mbps. " } ?? ""
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
        alert.messageText = "SpeedSentry \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0")"
        alert.informativeText = "Download checks use up to 72 MiB (8 MiB in Low Data Mode). Smart Schedule checks speed hourly, about 1.8 GB/day maximum payload if continuously awake; fixed ten-minute checks can use 10.9 GB/day. One-minute connection checks use small HTTPS requests; their response time includes DNS, TLS and server time, and is not ICMP ping.\n\nWi-Fi signal is read locally every 10 seconds while monitoring. Two readings at or below the selected threshold show one large warning; two readings 8 dBm above the threshold clear it. macOS may make readings unavailable. No Wi-Fi scans or automatic network switches run.\n\nUploads run only on demand and send 4 MiB of generated data to Cloudflare. Metered networks and paused profiles block full tests. Profiles can match a Wi-Fi name when macOS exposes it, otherwise select manually.\n\nDownload, upload and incident history stays local for 90 days; raw connection samples for seven days. All displayed/exported times use IST. Cloudflare and Apple receive your IP during connection tests. No tests during sleep. Brief drops can be missed. Hold Command and drag to reposition the menu bar item."
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

extension AppDelegate {
    private func refreshDashboard() {
        dashboardModel.history = store?.history ?? HistorySnapshot()
        if preview {
            let now = Date()
            var samples: [SpeedSentryCore.Measurement] = []
            for i in 0..<168 {
                let date = now.addingTimeInterval(Double(i - 167) * 3600)
                let speed: Double = i % 31 == 0 ? 14 : Double(80 + i % 23)
                samples.append(SpeedSentryCore.Measurement(timestamp: date, megabitsPerSecond: speed, bytesReceived: SpeedProbe.downloadBytes, errorDescription: nil))
            }
            dashboardModel.history = HistorySnapshot(measurements: samples)
        }
        dashboardModel.insights = insights?.snapshot ?? InsightsSnapshot()
        dashboardModel.threshold = effectiveThreshold
        dashboardModel.wifi = wifiReading
        dashboardModel.wifiEpisode = wifiPolicy.activeEpisode
    }
    @objc private func showDashboard() {
        refreshDashboard()
        if dashboardWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 730), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "SpeedSentry · History & Reports (IST)"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: DashboardView(model: dashboardModel, export: { [weak self] report in self?.exportReport(report) }))
            window.center(); dashboardWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); dashboardWindow?.makeKeyAndOrderFront(nil)
    }
    private func exportReport(_ report: DailyReport) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "SpeedSentry-\(String(ISTDate.string(report.start).prefix(10)))-IST.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try report.text.write(to: url, atomically: true, encoding: .utf8) }
        catch { showError("Report export failed", error.localizedDescription) }
    }
    @objc private func toggleSmartSchedule() {
        smartSchedule.toggle(); scheduleNext(from: lastAttempt ?? Date()); render()
    }
    private func startConnectionMonitoring() {
        connectionTimer?.invalidate()
        guard !preview, !paused, !isSleeping, storageError == nil, insights != nil else { return }
        startWiFiSignalMonitoring()
        runConnectionCheck()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.runConnectionCheck() }
        }
        timer.tolerance = 5; RunLoop.main.add(timer, forMode: .common); connectionTimer = timer
    }
    private func stopConnectionMonitoring() {
        stopWiFiSignalMonitoring()
        connectionTimer?.invalidate(); connectionTimer = nil
        connectionTask?.cancel(); connectionTask = nil
        uploadTask?.cancel(); uploadTask = nil
        connectionFailures = 0
        do { try insights?.interrupt() } catch { insightsFailed(error) }
    }
    private func runConnectionCheck() {
        render() // Refresh staleness even when full tests are blocked.
        guard !preview, !paused, !isSleeping, !isChecking, uploadTask == nil, connectionTask == nil, storageError == nil else { return }
        let token = generation
        connectionTask = Task { [weak self] in
            let sample = await ConnectionProbe().measure()
            guard let self, !Task.isCancelled, token == self.generation else { return }
            self.connectionTask = nil; self.latestConnection = sample
            self.connectionFailures = sample.reachable ? 0 : self.connectionFailures + 1
            do {
                let event = try self.insights?.record(sample)
                if let event { self.notifyConnection(event) }
                self.refreshDashboard()
            } catch { self.insightsFailed(error); return }
            if self.smartSchedule, MonitoringPolicy.shouldEscalate(failures: self.connectionFailures,
                latencyMilliseconds: sample.latencyMilliseconds, lastSpeedAttempt: self.lastAttempt, now: sample.timestamp) {
                self.requestAutomaticCheck()
            }
            self.render()
        }
    }
    private func insightsFailed(_ error: Error) {
        insights = nil
        storageError = "Insights (restart to retry): \(error.localizedDescription)"
        timer?.invalidate(); connectionTimer?.invalidate(); nextCheck = nil
        render()
    }
    private func notifyConnection(_ event: ConnectionEvent) {
        Task { [weak self] in
            guard let self else { return }
            await self.notificationAuthorizationTask?.value
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            let id: String
            switch event {
            case .started(let outage):
                id = "connection-\(outage.id)"; content.title = "Connection checks are failing"
                content.body = "Both test providers failed twice. First observed: \(ISTDate.string(outage.startedAt)). Check Wi-Fi, VPN or your ISP."
                content.sound = .default
            case .recovered(let outage):
                id = "connection-recovery-\(outage.id)"; content.title = "Connection checks recovered"
                content.body = "Observed: \(ISTDate.string(outage.endedAt ?? Date()))"
            }
            do { try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) }
            catch { self.notificationError = error.localizedDescription }
        }
    }
    @objc private func testUpload() {
        guard !preview, !isSleeping, !isChecking, uploadTask == nil, !speedTestsBlocked, store != nil, insights != nil else { return }
        connectionTask?.cancel(); connectionTask = nil
        let token = generation
        uploadTask = Task { [weak self] in
            let result = await UploadProbe().measure()
            guard let self, !Task.isCancelled, token == self.generation else { return }
            self.uploadTask = nil
            do { try self.insights?.record(result); self.refreshDashboard() }
            catch { self.insightsFailed(error) }
            self.render()
            if self.pendingAutomaticCheck { self.pendingAutomaticCheck = false; self.requestAutomaticCheck() }
            else if self.nextCheck.map({ $0 <= Date() }) ?? true { self.scheduleNext() }
            self.showDashboard()
        }
        render()
    }
    private func startNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let kind = path.usesInterfaceType(.wifi) ? "Wi-Fi" : path.usesInterfaceType(.wiredEthernet) ? "Ethernet" : "Other network"
            let metered = path.isExpensive || path.isConstrained
            Task { @MainActor [weak self] in
                guard let self else { return }
                let ssid = path.usesInterfaceType(.wifi) ? CWWiFiClient.shared().interface()?.ssid() : nil
                let identity = "\(kind)|\(ssid ?? "unknown")|\(metered)"
                self.usingWiFi = path.usesInterfaceType(.wifi)
                self.wifiInterfaceName = path.availableInterfaces.first(where: { $0.type == .wifi })?.name
                self.currentSSID = ssid; self.networkName = ssid ?? kind
                self.expensiveNetwork = metered
                guard self.networkIdentity != identity else { return }
                let wasKnown = self.networkIdentity != nil
                self.networkIdentity = identity
                if wasKnown { self.networkSettingsChanged() }
                else if !self.paused {
                    self.startConnectionMonitoring()
                    if !self.speedTestsBlocked { self.checkNow() }
                }
                self.render()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "app.speedsentry.network"))
    }
    private func networkSettingsChanged() {
        generation += 1; pendingAutomaticCheck = false
        checkTask?.cancel(); probe.cancel()
        stopConnectionMonitoring(); latestConnection = nil
        timer?.invalidate(); nextCheck = nil
        startConnectionMonitoring()
        scheduleNext(from: lastAttempt ?? Date())
        refreshDashboard(); render()
    }
    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard !preview else { return }
        let id = sender.representedObject as? String ?? ""
        // Selecting Default also removes automatic matching for this SSID.
        if let ssid = currentSSID {
            profiles = profiles.map { profile in
                var updated = profile
                if profile.ssid == ssid { updated.ssid = nil }
                if profile.id.uuidString == id { updated.ssid = ssid }
                return updated
            }
        }
        defaults.set(id, forKey: "manualProfileID"); networkSettingsChanged()
    }
    @objc private func editProfile() {
        let existing = activeProfile
        let alert = NSAlert(); alert.messageText = existing == nil ? "New network profile" : "Edit network profile"
        alert.informativeText = "Set a download alert threshold and pause full tests for hotspots.\n\(currentSSID == nil ? "Wi-Fi name unavailable: select this profile manually after changing networks." : "Matches current Wi-Fi name automatically when macOS exposes it.")"
        let name = NSTextField(string: existing?.name ?? networkName)
        let thresholdField = NSTextField(string: Self.thresholdText(existing?.thresholdMbps ?? threshold))
        let pause = NSButton(checkboxWithTitle: "Pause download and upload tests", target: nil, action: nil)
        pause.state = existing?.pauseSpeedTests == true ? .on : .off
        let stack = NSStackView(views: [NSTextField(labelWithString: "Profile name"), name, NSTextField(labelWithString: "Alert below (Mbps)"), thresholdField, pause])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 150); name.widthAnchor.constraint(equalToConstant: 350).isActive = true
        thresholdField.widthAnchor.constraint(equalToConstant: 350).isActive = true
        alert.accessoryView = stack; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let value = Double(thresholdField.stringValue) else { showError("Invalid threshold", "Enter a number greater than 0 and up to 10,000 Mbps."); return }
        let profile = NetworkProfile(id: existing?.id ?? UUID(), name: name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), ssid: currentSSID, thresholdMbps: value, pauseSpeedTests: pause.state == .on)
        guard profile.isValid else { showError("Invalid profile", "Enter a name and a threshold greater than 0 and up to 10,000 Mbps."); return }
        profiles = profiles.filter { $0.id != profile.id && (currentSSID == nil || $0.ssid != currentSSID) } + [profile]
        defaults.set(profile.id.uuidString, forKey: "manualProfileID"); networkSettingsChanged()
    }
    @objc private func deleteProfile() {
        guard let profile = activeProfile else { return }
        profiles = profiles.filter { $0.id != profile.id }; defaults.removeObject(forKey: "manualProfileID")
        networkSettingsChanged()
    }
}

extension AppDelegate {
    private func startWiFiSignalMonitoring() {
        wifiTimer?.invalidate()
        guard !preview, !paused, !isSleeping else { return }
        wifiPolicy = WiFiSignalPolicy(weakThresholdDBm: wifiThreshold)
        updateWiFiSignal()
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateWiFiSignal() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common); wifiTimer = timer
    }
    private func stopWiFiSignalMonitoring() {
        wifiTimer?.invalidate(); wifiTimer = nil
        clearWiFiWarning(); wifiPolicy.reset()
        wifiReading = WiFiSignalReading(state: paused || isSleeping ? .paused : .unavailable)
        dashboardModel.wifi = wifiReading; dashboardModel.wifiEpisode = nil
    }
    private func updateWiFiSignal() {
        guard !preview, !paused, !isSleeping else { return }
        let observation = WiFiSignalReader.read(usingWiFi: usingWiFi, interfaceName: wifiInterfaceName)
        wifiReading = observation.reading
        let previousEpisode = wifiPolicy.activeEpisode
        let event: WiFiSignalEvent?
        if wifiAlertsEnabled { event = wifiPolicy.observe(wifiReading, networkID: observation.networkID) }
        else { wifiPolicy.reset(); event = nil }
        dashboardModel.wifi = wifiReading; dashboardModel.wifiEpisode = wifiPolicy.activeEpisode
        if !wifiIsWeak { wifiWarningPanel?.orderOut(nil) }
        if wifiPolicy.activeEpisode == nil, let previousEpisode {
            removeWiFiNotification(previousEpisode.id)
        }
        if case .started(let episode) = event {
            showWiFiWarning()
            notifyWeakWiFi(episode)
        }
        render()
    }
    private func showWiFiWarning() {
        if wifiWarningPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 596, height: 300), styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "SpeedSentry · Weak Wi-Fi"
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: WiFiWeakWarningView(model: dashboardModel, dismiss: { [weak panel] in panel?.orderOut(nil) }))
            wifiWarningPanel = panel
        }
        wifiWarningPanel?.center()
        wifiWarningPanel?.orderFrontRegardless()
    }
    private func notifyWeakWiFi(_ episode: WiFiWeakEpisode) {
        Task { [weak self] in
            guard let self else { return }
            await self.notificationAuthorizationTask?.value
            guard self.wifiAlertsEnabled, self.wifiPolicy.activeEpisode?.id == episode.id, self.wifiIsWeak else { return }
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional,
                  self.wifiAlertsEnabled, !self.paused, !self.isSleeping,
                  self.wifiPolicy.activeEpisode?.id == episode.id, self.wifiIsWeak else { return }
            let content = UNMutableNotificationContent()
            content.title = "Wi-Fi signal is weak"
            content.body = "\(episode.rssiDBm) dBm. Move closer to your Wi-Fi access point or switch to a stronger Wi-Fi network. First observed: \(ISTDate.string(episode.startedAt))."
            content.sound = .default
            do { try await center.add(UNNotificationRequest(identifier: "weak-wifi-\(episode.id)", content: content, trigger: nil)) }
            catch { self.notificationError = error.localizedDescription }
        }
    }
    private func removeWiFiNotification(_ id: UUID) {
        let identifier = "weak-wifi-\(id)"
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }
    private func clearWiFiWarning() {
        wifiWarningPanel?.orderOut(nil)
        if let episode = wifiPolicy.activeEpisode { removeWiFiNotification(episode.id) }
    }
    @objc private func toggleWiFiAlerts() {
        guard !preview else { return }
        wifiAlertsEnabled.toggle(); clearWiFiWarning(); wifiPolicy.reset()
        updateWiFiSignal()
    }
    @objc private func setWiFiThreshold(_ sender: NSMenuItem) {
        guard !preview, [-70, -75, -80].contains(sender.tag) else { return }
        clearWiFiWarning(); wifiThreshold = sender.tag
        wifiPolicy = WiFiSignalPolicy(weakThresholdDBm: wifiThreshold)
        updateWiFiSignal()
    }
}
