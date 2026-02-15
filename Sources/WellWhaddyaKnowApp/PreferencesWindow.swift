// SPDX-License-Identifier: MIT
// PreferencesWindow.swift - Preferences window per SPEC.md Section 9.3

import CoreModel
import SwiftUI
import XPCProtocol
import ServiceManagement
import SQLite3
import os.log

private let prefLog = Logger(subsystem: "com.daylily.wellwhaddyaknow", category: "Preferences")

/// Preferences window showing data location, permissions, and settings
struct PreferencesWindow: View {
    @StateObject private var viewModel = PreferencesViewModel()

    var body: some View {
        TabView {
            GeneralPreferencesView(viewModel: viewModel)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            PermissionsPreferencesView(viewModel: viewModel)
                .tabItem {
                    Label("Permissions", systemImage: "lock.shield")
                }

            DiagnosticsPreferencesView(viewModel: viewModel)
                .tabItem {
                    Label("Diagnostics", systemImage: "stethoscope")
                }

            DataPreferencesView(viewModel: viewModel)
                .tabItem {
                    Label("Data", systemImage: "externaldrive")
                }

            AboutPreferencesView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        .task {
            await viewModel.refreshStatus()
        }
    }
}

/// View model for preferences
@MainActor
final class PreferencesViewModel: ObservableObject {
    @Published var dataPath: String = ""
    @Published var dataSize: String = "Unknown"
    @Published var accessibilityGranted: Bool = false
    @Published var agentRunning: Bool = false
    @Published var agentVersion: String = ""
    @Published var agentUptime: TimeInterval = 0
    @Published var agentStatusMessage: String = "Checking..."
    @Published var defaultExportFormat: String = "csv"
    @Published var defaultIncludeTitles: Bool = true
    @Published var isRefreshing: Bool = false

    /// Display timezone identifier. Empty string means "use system default".
    @Published var displayTimezoneId: String = "" {
        didSet {
            UserDefaults.standard.set(
                displayTimezoneId.isEmpty ? nil : displayTimezoneId,
                forKey: Self.displayTimezoneKey
            )
        }
    }

    /// The UserDefaults key for the display timezone preference.
    static let displayTimezoneKey = "com.daylily.wellwhaddyaknow.displayTimezone"

    /// Resolved display timezone (falls back to system when not set or invalid).
    var displayTimezone: TimeZone {
        DisplayTimezoneHelper.preferred
    }

    // Diagnostics properties
    @Published var agentPID: Int? = nil
    @Published var registrationStatusText: String = "Unknown"
    @Published var agentRegistered: Bool = false
    @Published var agentEnabled: Bool = false
    @Published var requiresApproval: Bool = false
    @Published var isPlistMissing: Bool = false
    @Published var isManagedByCLI: Bool = false
    @Published var socketPath: String = ""
    @Published var socketExists: Bool = false
    @Published var ipcConnected: Bool = false
    @Published var dbIntegrityOk: Bool = false
    @Published var dbIntegrityText: String = "Unknown"
    @Published var totalEvents: Int64 = 0
    @Published var earliestEvent: String = "N/A"
    @Published var latestEvent: String = "N/A"
    @Published var totalTrackedTime: String = "N/A"
    @Published var uniqueApps: Int = 0
    @Published var appGroupAccessible: Bool = false
    @Published var isCurrentlyWorking: Bool = false
    /// Agent's own accessibility status (separate from GUI app's permission)
    @Published var agentAccessibilityGranted: Bool = false

    private let xpcClient = XPCClient()

    /// launchd label used by the CLI-installed agent plist
    private let launchdLabel = "com.daylily.wellwhaddyaknow.agent"

    /// Run a shell command and return (exitCode, stdout, stderr).
    /// Mirrors the CLI's `shell()` helper in AgentCommand.swift.
    private nonisolated func shell(_ args: [String]) -> (Int32, String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (1, "", error.localizedDescription)
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }

    func refreshStatus() async {
        isRefreshing = true
        defer { isRefreshing = false }

        // Load display timezone preference
        displayTimezoneId = UserDefaults.standard.string(forKey: Self.displayTimezoneKey) ?? ""

        // Get data path and app group status
        let appGroupId = "group.com.daylily.wellwhaddyaknow"
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) {
            appGroupAccessible = true
            dataPath = containerURL
                .appendingPathComponent("WellWhaddyaKnow")
                .appendingPathComponent("wwk.sqlite")
                .path

            // Get file size
            if let attrs = try? FileManager.default.attributesOfItem(atPath: dataPath),
               let size = attrs[.size] as? Int64 {
                dataSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            }
        } else {
            appGroupAccessible = false
        }

        // IPC socket status
        socketPath = getIPCSocketPath()
        socketExists = FileManager.default.fileExists(atPath: socketPath)

        // Agent lifecycle (SMAppService or CLI-managed)
        let lifecycle = AgentLifecycleManager.shared
        lifecycle.refreshStatus()
        registrationStatusText = lifecycle.statusDescription
        agentRegistered = lifecycle.isRegistered
        agentEnabled = lifecycle.isEnabled
        requiresApproval = lifecycle.requiresApproval
        isPlistMissing = lifecycle.isPlistMissing
        isManagedByCLI = lifecycle.isManagedByCLI

        // Check GUI app's own accessibility permission locally.
        // macOS tracks AX permission per-executable, so the GUI app and the
        // agent (wwkd) have independent permission states.
        accessibilityGranted = AXIsProcessTrusted()

        // Query agent via IPC for real status
        do {
            let status = try await xpcClient.getStatus()
            agentRunning = true
            isCurrentlyWorking = status.isWorking
            agentVersion = status.agentVersion
            agentUptime = status.agentUptime
            agentPID = status.agentPID
            agentStatusMessage = "Running (v\(status.agentVersion), uptime \(formatUptime(status.agentUptime)))"
            ipcConnected = true

            // Store agent's AX status separately (for diagnostics)
            switch status.accessibilityStatus {
            case .granted:
                agentAccessibilityGranted = true
            case .denied, .unknown:
                agentAccessibilityGranted = false
            }
        } catch {
            agentRunning = false
            isCurrentlyWorking = false
            agentVersion = ""
            agentUptime = 0
            agentPID = nil
            agentStatusMessage = "Not running"
            agentAccessibilityGranted = false
            ipcConnected = false
        }

        // Database diagnostics (direct read-only)
        await refreshDatabaseDiagnostics()
    }

    private func refreshDatabaseDiagnostics() async {
        guard !dataPath.isEmpty, FileManager.default.fileExists(atPath: dataPath) else {
            dbIntegrityOk = false
            dbIntegrityText = "Database not found"
            return
        }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dataPath, &db, flags, nil) == SQLITE_OK else {
            dbIntegrityOk = false
            dbIntegrityText = "Cannot open database"
            return
        }
        defer { sqlite3_close(db) }

        // Integrity check
        if let result = queryScalarString(db: db!, sql: "PRAGMA integrity_check;") {
            dbIntegrityOk = (result == "ok")
            dbIntegrityText = result == "ok" ? "OK" : result
        }

        // Event counts
        let sseCount = queryScalarInt64(db: db!, sql: "SELECT COUNT(*) FROM system_state_events;") ?? 0
        let raeCount = queryScalarInt64(db: db!, sql: "SELECT COUNT(*) FROM raw_activity_events;") ?? 0
        totalEvents = sseCount + raeCount

        // Date range
        let earliestUs = queryScalarInt64(db: db!, sql: """
            SELECT MIN(ts) FROM (
                SELECT MIN(event_ts_us) AS ts FROM system_state_events
                UNION ALL
                SELECT MIN(event_ts_us) AS ts FROM raw_activity_events
            );
            """)
        let latestUs = queryScalarInt64(db: db!, sql: """
            SELECT MAX(ts) FROM (
                SELECT MAX(event_ts_us) AS ts FROM system_state_events
                UNION ALL
                SELECT MAX(event_ts_us) AS ts FROM raw_activity_events
            );
            """)

        if let e = earliestUs, e > 0 {
            earliestEvent = formatMicrosecondTimestamp(e)
        } else {
            earliestEvent = "N/A"
        }
        if let l = latestUs, l > 0 {
            latestEvent = formatMicrosecondTimestamp(l)
        } else {
            latestEvent = "N/A"
        }

        // Unique applications
        uniqueApps = Int(queryScalarInt64(db: db!, sql: "SELECT COUNT(DISTINCT app_id) FROM raw_activity_events;") ?? 0)

        // Total tracked time (all-time) using working intervals from system_state_events
        // Only count up to "now" if the agent is currently working
        let allTimeTotalSec = queryTotalWorkingTime(db: db!, isCurrentlyWorking: isCurrentlyWorking)
        totalTrackedTime = formatDuration(allTimeTotalSec)
    }

    func revealInFinder() {
        if !dataPath.isEmpty {
            let url = URL(fileURLWithPath: dataPath)
            NSWorkspace.shared.selectFile(dataPath, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Path to the running .app bundle (what macOS tracks for GUI AX permission).
    var appBundlePath: String {
        Bundle.main.bundlePath
    }

    /// Best-guess path to the wwkd agent binary.
    /// For Homebrew installs the layout is: PREFIX/WellWhaddyaKnow.app  +  PREFIX/bin/wwkd
    /// For dev builds it falls back to the MacOS directory inside the bundle.
    var agentBinaryPath: String {
        let bundleURL = URL(fileURLWithPath: Bundle.main.bundlePath)
        // Homebrew layout: PREFIX/WellWhaddyaKnow.app → PREFIX/bin/wwkd
        let siblingBin = bundleURL.deletingLastPathComponent()
            .appendingPathComponent("bin")
            .appendingPathComponent("wwkd")
        if FileManager.default.fileExists(atPath: siblingBin.path) {
            return siblingBin.path
        }
        // Embedded in bundle: .app/Contents/MacOS/wwkd
        let embeddedBin = bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
            .appendingPathComponent("wwkd")
        if FileManager.default.fileExists(atPath: embeddedBin.path) {
            return embeddedBin.path
        }
        // Fallback: check PATH via `which`
        let (code, out, _) = shell(["which", "wwkd"])
        if code == 0, !out.isEmpty {
            return out
        }
        return "(not found)"
    }

    func revealAppInFinder() {
        NSWorkspace.shared.selectFile(
            appBundlePath,
            inFileViewerRootedAtPath: URL(fileURLWithPath: appBundlePath).deletingLastPathComponent().path
        )
    }

    func revealAgentInFinder() {
        let path = agentBinaryPath
        guard path != "(not found)" else { return }
        NSWorkspace.shared.selectFile(
            path,
            inFileViewerRootedAtPath: URL(fileURLWithPath: path).deletingLastPathComponent().path
        )
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func requestAccessibilityPermission() {
        // Trigger the system prompt via AXIsProcessTrustedWithOptions
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true] as CFDictionary
        let granted = AXIsProcessTrustedWithOptions(options)
        accessibilityGranted = granted
    }

    // MARK: - launchd Helpers

    /// Check whether the launchd service is currently loaded (bootstrapped).
    private nonisolated func isServiceLoaded() -> Bool {
        let (code, _, _) = shell(["launchctl", "list", launchdLabel])
        return code == 0
    }

    /// Locate the wwkd binary: sibling to running app → Homebrew paths → PATH
    private nonisolated func findWwkdBinary() -> String? {
        let bundlePath = Bundle.main.bundlePath
        let bundleURL = URL(fileURLWithPath: bundlePath)
        // Dev build: .build/release/WellWhaddyaKnow.app → .build/release/wwkd
        let siblingDev = bundleURL.deletingLastPathComponent()
            .appendingPathComponent("wwkd")
        if FileManager.default.isExecutableFile(atPath: siblingDev.path) {
            return siblingDev.path
        }
        // Homebrew layout: PREFIX/WellWhaddyaKnow.app → PREFIX/bin/wwkd
        let siblingBin = bundleURL.deletingLastPathComponent()
            .appendingPathComponent("bin")
            .appendingPathComponent("wwkd")
        if FileManager.default.isExecutableFile(atPath: siblingBin.path) {
            return siblingBin.path
        }
        // Embedded in bundle: .app/Contents/MacOS/wwkd
        let embeddedBin = bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
            .appendingPathComponent("wwkd")
        if FileManager.default.isExecutableFile(atPath: embeddedBin.path) {
            return embeddedBin.path
        }
        // Standard Homebrew locations
        for candidate in ["/opt/homebrew/bin/wwkd", "/usr/local/bin/wwkd"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        // PATH lookup
        let (code, out, _) = shell(["which", "wwkd"])
        if code == 0, !out.isEmpty {
            return out
        }
        return nil
    }

    /// Generate launchd plist XML content for the wwkd agent
    private nonisolated func generatePlistContent(wwkdPath: String) -> String {
        let label = launchdLabel
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>Program</key>
            <string>\(wwkdPath)</string>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>
            <key>StandardOutPath</key>
            <string>/tmp/\(label).stdout.log</string>
            <key>StandardErrorPath</key>
            <string>/tmp/\(label).stderr.log</string>
            <key>ProcessType</key>
            <string>Background</string>
        </dict>
        </plist>
        """
    }

    /// Create the plist at ~/Library/LaunchAgents/ and bootstrap it.
    /// Returns true on success.
    @discardableResult
    private nonisolated func createAndInstallPlist() -> Bool {
        guard let wwkdPath = findWwkdBinary() else {
            prefLog.error("Cannot find wwkd binary — unable to create plist")
            return false
        }
        let plistPath = AgentLifecycleManager.cliPlistPath
        let launchAgentDir = (plistPath as NSString).deletingLastPathComponent

        // Create ~/Library/LaunchAgents/ if needed
        try? FileManager.default.createDirectory(
            atPath: launchAgentDir, withIntermediateDirectories: true
        )

        // Bootout existing service if somehow loaded
        if isServiceLoaded() {
            _ = shell(["launchctl", "bootout", "gui/\(getuid())", plistPath])
        }

        // Write plist
        let content = generatePlistContent(wwkdPath: wwkdPath)
        do {
            try content.write(toFile: plistPath, atomically: true, encoding: .utf8)
            prefLog.info("Created plist at \(plistPath) → wwkd: \(wwkdPath)")
        } catch {
            prefLog.error("Failed to write plist: \(error)")
            return false
        }

        // Bootstrap
        let (code, _, err) = shell([
            "launchctl", "bootstrap", "gui/\(getuid())", plistPath,
        ])
        if code != 0 {
            prefLog.error("launchctl bootstrap failed: \(err)")
        }
        return code == 0
    }

    /// Bootstrap an existing CLI plist into launchd so kickstart/kill commands work.
    /// Returns true on success.
    @discardableResult
    private nonisolated func bootstrapCLIPlist() -> Bool {
        let plist = AgentLifecycleManager.cliPlistPath
        guard FileManager.default.fileExists(atPath: plist) else { return false }
        let (code, _, err) = shell([
            "launchctl", "bootstrap", "gui/\(getuid())", plist,
        ])
        if code != 0 {
            prefLog.error("launchctl bootstrap failed: \(err)")
        }
        return code == 0
    }

    /// Ensure the launchd service is loaded.
    /// 1. If already loaded → return true
    /// 2. If CLI plist exists → bootstrap it
    /// 3. Otherwise → create plist + bootstrap
    private nonisolated func ensureServiceLoaded() -> Bool {
        if isServiceLoaded() { return true }
        prefLog.info("Service not loaded — attempting bootstrap")
        if bootstrapCLIPlist() { return true }
        prefLog.info("No plist to bootstrap — creating one")
        return createAndInstallPlist()
    }

    // MARK: - Agent Control

    func startAgent() {
        agentStatusMessage = "Starting..."
        prefLog.info("Starting agent via launchctl kickstart")

        // Clean up stale socket before starting
        let sock = getIPCSocketPath()
        if FileManager.default.fileExists(atPath: sock) {
            try? FileManager.default.removeItem(atPath: sock)
            prefLog.info("Removed stale socket before agent start")
        }

        let label = launchdLabel
        Task.detached { [weak self] in
            guard let self else { return }

            // Ensure service is loaded (creates plist if needed)
            let loaded = self.ensureServiceLoaded()
            if !loaded {
                prefLog.error("Cannot start agent: service not loaded and all bootstrap methods failed")
                _ = await MainActor.run { [weak self] in
                    self?.agentStatusMessage = "Start failed: wwkd binary not found"
                }
                return
            }

            let (code, _, err) = self.shell([
                "launchctl", "kickstart", "-k",
                "gui/\(getuid())/\(label)",
            ])
            prefLog.info("launchctl kickstart exited with status \(code)")
            if code != 0 {
                prefLog.error("launchctl kickstart failed: \(err)")
            }

            try? await Task.sleep(nanoseconds: 2_000_000_000)
            _ = await MainActor.run { [weak self] in
                Task { await self?.refreshStatus() }
            }
        }
    }

    func stopAgent() {
        agentStatusMessage = "Stopping..."
        prefLog.info("Stopping agent via launchctl kill")
        let label = launchdLabel
        Task.detached { [weak self] in
            guard let self else { return }

            var stopped = false
            if self.isServiceLoaded() {
                let (code, _, err) = self.shell([
                    "launchctl", "kill", "SIGTERM",
                    "gui/\(getuid())/\(label)",
                ])
                prefLog.info("launchctl kill exited with status \(code)")
                stopped = (code == 0)
                if code != 0 {
                    prefLog.error("launchctl kill failed: \(err)")
                }
            } else {
                prefLog.info("Service not loaded in launchd, skipping launchctl kill")
            }

            // Fallback: pkill if launchctl kill didn't work or service wasn't loaded
            if !stopped {
                let (pkCode, _, _) = self.shell(["pkill", "-x", "wwkd"])
                if pkCode == 0 {
                    prefLog.info("Stopped agent via pkill fallback")
                }
            }

            // Clean up socket after stop
            let sock = getIPCSocketPath()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if FileManager.default.fileExists(atPath: sock) {
                try? FileManager.default.removeItem(atPath: sock)
                prefLog.info("Removed socket after agent stop")
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
            _ = await MainActor.run { [weak self] in
                Task { await self?.refreshStatus() }
            }
        }
    }

    func restartAgent() {
        agentStatusMessage = "Restarting..."
        prefLog.info("Restarting agent via launchctl kickstart -k")
        let label = launchdLabel
        Task.detached { [weak self] in
            guard let self else { return }

            // Bootstrap first if service is not loaded
            let loaded = self.ensureServiceLoaded()
            if !loaded {
                prefLog.error("Cannot restart agent: service not loaded and bootstrap failed")
                _ = await MainActor.run { [weak self] in
                    self?.agentStatusMessage = "Restart failed: service not loaded (no plist?)"
                }
                return
            }

            let (code, _, err) = self.shell([
                "launchctl", "kickstart", "-k",
                "gui/\(getuid())/\(label)",
            ])
            prefLog.info("launchctl kickstart -k exited with status \(code)")
            if code != 0 {
                prefLog.error("launchctl kickstart -k failed: \(err)")
            }

            try? await Task.sleep(nanoseconds: 2_000_000_000)
            _ = await MainActor.run { [weak self] in
                Task { await self?.refreshStatus() }
            }
        }
    }

    func openAgentLogs() {
        // Open Console.app filtered to wwkd
        let script = """
        tell application "Console"
            activate
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    func registerAgent() {
        let lifecycle = AgentLifecycleManager.shared

        // Try ensureServiceLoaded which handles:
        //   1. Already loaded → done
        //   2. CLI plist exists → bootstrap it
        //   3. No plist → create one and bootstrap
        let loaded = ensureServiceLoaded()
        if loaded {
            agentStatusMessage = "Agent registered and service loaded"
            prefLog.info("Agent registered successfully")
        } else {
            // Last resort: try SMAppService (only works for signed/notarized bundles)
            do {
                try lifecycle.register()
                agentStatusMessage = "Agent registered via SMAppService"
            } catch {
                agentStatusMessage = "Registration failed: wwkd binary not found"
                prefLog.error("registerAgent: all methods failed — \(error)")
            }
        }

        lifecycle.refreshStatus()
        registrationStatusText = lifecycle.statusDescription
        agentRegistered = lifecycle.isRegistered
        agentEnabled = lifecycle.isEnabled
        requiresApproval = lifecycle.requiresApproval
    }

    func unregisterAgent() {
        let lifecycle = AgentLifecycleManager.shared
        let plistPath = AgentLifecycleManager.cliPlistPath

        if lifecycle.cliPlistExists {
            // CLI plist exists — bootout from launchd and remove the plist
            prefLog.info("CLI plist detected — booting out and removing")

            // Kill the running agent first
            if isServiceLoaded() {
                let (_, _, _) = shell([
                    "launchctl", "bootout",
                    "gui/\(getuid())", plistPath,
                ])
            }
            // Fallback: pkill
            let (_, _, _) = shell(["pkill", "-x", "wwkd"])

            // Remove the plist file
            try? FileManager.default.removeItem(atPath: plistPath)

            // Clean up socket
            let sock = getIPCSocketPath()
            if FileManager.default.fileExists(atPath: sock) {
                try? FileManager.default.removeItem(atPath: sock)
            }

            agentStatusMessage = "Agent unregistered (CLI plist removed)"
        } else {
            // No CLI plist — use SMAppService unregistration
            do {
                try lifecycle.unregister()
            } catch {
                agentStatusMessage = "Unregistration failed: \(error.localizedDescription)"
            }
        }

        lifecycle.refreshStatus()
        registrationStatusText = lifecycle.statusDescription
        agentRegistered = lifecycle.isRegistered
        agentEnabled = lifecycle.isEnabled
        requiresApproval = lifecycle.requiresApproval
    }

    func openLoginItemsSettings() {
        // Auto-register before opening Login Items so the app appears in the list
        if !agentRegistered {
            registerAgent()
        }
        AgentLifecycleManager.shared.openLoginItemsSettings()
    }

    func copyDiagnosticsToClipboard() {
        let lines = [
            "WellWhaddyaKnow Diagnostics",
            "===========================",
            "",
            "Agent Status:",
            "  Registered: \(agentRegistered ? "Yes" : "No")",
            "  Enabled: \(agentEnabled ? "Yes" : "No")",
            "  Running: \(agentRunning ? "Yes" : "No")",
            "  PID: \(agentPID.map { String($0) } ?? "N/A")",
            "  Version: \(agentVersion.isEmpty ? "N/A" : agentVersion)",
            "  Uptime: \(agentRunning ? formatUptime(agentUptime) : "N/A")",
            "  Registration: \(registrationStatusText)",
            "",
            "IPC Status:",
            "  Socket: \(socketPath)",
            "  Socket exists: \(socketExists ? "Yes" : "No")",
            "  Connection: \(ipcConnected ? "OK" : "Failed")",
            "",
            "Database:",
            "  Path: \(dataPath)",
            "  Size: \(dataSize)",
            "  Integrity: \(dbIntegrityText)",
            "  Total events: \(totalEvents)",
            "  Earliest: \(earliestEvent)",
            "  Latest: \(latestEvent)",
            "  Total tracked: \(totalTrackedTime)",
            "  Unique apps: \(uniqueApps)",
            "",
            "Permissions:",
            "  Accessibility (GUI): \(accessibilityGranted ? "Granted" : "Denied")",
            "  Accessibility (Agent): \(agentRunning ? (agentAccessibilityGranted ? "Granted" : "Denied") : "N/A (not running)")",
            "  App Group: \(appGroupAccessible ? "Accessible" : "Not accessible")",
            "",
            "Generated: \(ISO8601DateFormatter().string(from: Date()))",
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Private Helpers

    private func formatUptime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m \(secs)s"
        }
        return "\(secs)s"
    }

    private func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m"
        }
        return "<1m"
    }

    private func formatMicrosecondTimestamp(_ tsUs: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(tsUs) / 1_000_000.0)
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .medium
        fmt.timeZone = DisplayTimezoneHelper.preferred
        return fmt.string(from: date)
    }

    private func queryScalarString(db: OpaquePointer, sql: String) -> String? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let cStr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: cStr)
    }

    private func queryScalarInt64(db: OpaquePointer, sql: String) -> Int64? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private func queryTotalWorkingTime(db: OpaquePointer, isCurrentlyWorking: Bool) -> Double {
        // Sum up working intervals from system_state_events
        let sql = """
            SELECT event_ts_us, is_working FROM system_state_events
            ORDER BY event_ts_us;
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }

        var totalUs: Int64 = 0
        var lastWorkingTs: Int64? = nil

        while sqlite3_step(stmt) == SQLITE_ROW {
            let tsUs = sqlite3_column_int64(stmt, 0)
            let working = sqlite3_column_int(stmt, 1) != 0
            if working {
                if lastWorkingTs == nil {
                    lastWorkingTs = tsUs
                }
            } else {
                if let start = lastWorkingTs {
                    totalUs += tsUs - start
                    lastWorkingTs = nil
                }
            }
        }
        // Only count up to now if the agent reports it is currently working.
        // When paused, the last system_state_event already closed the interval.
        if let start = lastWorkingTs, isCurrentlyWorking {
            let nowUs = Int64(Date().timeIntervalSince1970 * 1_000_000)
            totalUs += nowUs - start
        }
        return Double(totalUs) / 1_000_000.0
    }
}

// MARK: - General Preferences

struct GeneralPreferencesView: View {
    @ObservedObject var viewModel: PreferencesViewModel
    @State private var timezoneSearch: String = ""

    /// Common timezone identifiers, grouped for easy browsing.
    private static let commonTimezones: [String] = {
        // Start with a curated set, then fall back to full list.
        let curated = [
            "US/Eastern", "US/Central", "US/Mountain", "US/Pacific", "US/Alaska", "US/Hawaii",
            "America/New_York", "America/Chicago", "America/Denver", "America/Los_Angeles",
            "America/Anchorage", "America/Phoenix", "America/Toronto", "America/Vancouver",
            "Europe/London", "Europe/Berlin", "Europe/Paris", "Europe/Amsterdam",
            "Europe/Zurich", "Europe/Moscow",
            "Asia/Tokyo", "Asia/Shanghai", "Asia/Kolkata", "Asia/Singapore",
            "Asia/Dubai", "Asia/Hong_Kong",
            "Australia/Sydney", "Australia/Melbourne", "Australia/Perth",
            "Pacific/Auckland", "Pacific/Honolulu",
            "UTC",
        ]
        // Merge curated + all known identifiers, dedup, sort.
        let all = Set(curated + TimeZone.knownTimeZoneIdentifiers)
        return all.sorted()
    }()

    private var filteredTimezones: [String] {
        if timezoneSearch.isEmpty { return Self.commonTimezones }
        let q = timezoneSearch.lowercased()
        return Self.commonTimezones.filter { $0.lowercased().contains(q) }
    }

    var body: some View {
        Form {
            Section("Display Timezone") {
                Picker("Timezone:", selection: $viewModel.displayTimezoneId) {
                    Text("System Default (\(TimeZone.current.identifier))").tag("")
                    ForEach(filteredTimezones, id: \.self) { tzId in
                        Text(tzId).tag(tzId)
                    }
                }
                .frame(maxWidth: .infinity)

                TextField("Filter timezones…", text: $timezoneSearch)
                    .textFieldStyle(.roundedBorder)

                Text("Current: \(DisplayTimezoneHelper.displayLabel)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Export Defaults") {
                Picker("Default format:", selection: $viewModel.defaultExportFormat) {
                    Text("CSV").tag("csv")
                    Text("JSON").tag("json")
                }
                .pickerStyle(.segmented)

                Toggle("Include window titles by default", isOn: $viewModel.defaultIncludeTitles)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Permissions Preferences

struct PermissionsPreferencesView: View {
    @ObservedObject var viewModel: PreferencesViewModel

    var body: some View {
        Form {
            Section("Accessibility Permission") {
                // --- GUI app status ---
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: viewModel.accessibilityGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(viewModel.accessibilityGranted ? .green : .red)
                        Text(viewModel.accessibilityGranted ? "GUI app — permission granted ✓" : "GUI app — permission NOT granted")
                            .fontWeight(.medium)
                        Spacer()
                        if viewModel.isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    HStack(spacing: 4) {
                        Text(viewModel.appBundlePath)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            viewModel.copyToClipboard(viewModel.appBundlePath)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                        .help("Copy path")
                    }
                }

                // --- Agent status ---
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: (viewModel.agentRunning && viewModel.agentAccessibilityGranted)
                              ? "checkmark.circle.fill"
                              : "xmark.circle.fill")
                            .foregroundColor((viewModel.agentRunning && viewModel.agentAccessibilityGranted)
                                             ? .green
                                             : (viewModel.agentRunning ? .orange : .secondary))
                        Text(viewModel.agentRunning
                             ? (viewModel.agentAccessibilityGranted
                                ? "Agent (wwkd) — permission granted ✓"
                                : "Agent (wwkd) — permission NOT granted")
                             : "Agent (wwkd) — not running")
                            .fontWeight(.medium)
                    }
                    HStack(spacing: 4) {
                        Text(viewModel.agentBinaryPath)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if viewModel.agentBinaryPath != "(not found)" {
                            Button {
                                viewModel.copyToClipboard(viewModel.agentBinaryPath)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .font(.caption2)
                            .help("Copy path")
                        }
                    }
                }

                if !viewModel.accessibilityGranted || (viewModel.agentRunning && !viewModel.agentAccessibilityGranted) {
                    Text("Window title capture requires Accessibility permission for BOTH the GUI app and the agent (wwkd). Click \"Request Permission\" first. If that doesn't work, use \"Open System Settings\" and follow the steps below.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    Button("Request Permission") {
                        viewModel.requestAccessibilityPermission()
                    }
                    .disabled(viewModel.accessibilityGranted)

                    Button {
                        Task { await viewModel.refreshStatus() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }

            Section("How to Grant Accessibility (Manual Steps)") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("If \"Request Permission\" didn't show a prompt, add these items manually:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Step 1
                    HStack(alignment: .top, spacing: 6) {
                        Text("1.")
                            .font(.caption)
                            .fontWeight(.bold)
                            .frame(width: 18, alignment: .trailing)
                        Text("Click \"Open System Settings\" below. It opens Privacy & Security → Accessibility.")
                            .font(.caption)
                    }

                    // Step 2
                    HStack(alignment: .top, spacing: 6) {
                        Text("2.")
                            .font(.caption)
                            .fontWeight(.bold)
                            .frame(width: 18, alignment: .trailing)
                        Text("Click the 🔒 lock icon (bottom-left), then click the \"+\" button.")
                            .font(.caption)
                    }

                    // Step 3 — GUI app
                    HStack(alignment: .top, spacing: 6) {
                        Text("3.")
                            .font(.caption)
                            .fontWeight(.bold)
                            .frame(width: 18, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Add the **GUI app**:")
                                .font(.caption)
                            Text(viewModel.appBundlePath)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .truncationMode(.middle)
                            HStack(spacing: 6) {
                                Button {
                                    viewModel.copyToClipboard(viewModel.appBundlePath)
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                .font(.caption2)
                                Button {
                                    viewModel.revealAppInFinder()
                                } label: {
                                    Label("Reveal", systemImage: "folder")
                                }
                                .font(.caption2)
                            }
                        }
                    }

                    // Step 4 — Agent binary
                    HStack(alignment: .top, spacing: 6) {
                        Text("4.")
                            .font(.caption)
                            .fontWeight(.bold)
                            .frame(width: 18, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Add the **agent binary** (wwkd):")
                                .font(.caption)
                            Text(viewModel.agentBinaryPath)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .truncationMode(.middle)
                            if viewModel.agentBinaryPath != "(not found)" {
                                HStack(spacing: 6) {
                                    Button {
                                        viewModel.copyToClipboard(viewModel.agentBinaryPath)
                                    } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }
                                    .font(.caption2)
                                    Button {
                                        viewModel.revealAgentInFinder()
                                    } label: {
                                        Label("Reveal", systemImage: "folder")
                                    }
                                    .font(.caption2)
                                }
                            }
                        }
                    }

                    // Step 5
                    HStack(alignment: .top, spacing: 6) {
                        Text("5.")
                            .font(.caption)
                            .fontWeight(.bold)
                            .frame(width: 18, alignment: .trailing)
                        Text("Toggle BOTH items ON, then come back and click Refresh.")
                            .font(.caption)
                    }
                }

                Button("Open System Settings") {
                    viewModel.openAccessibilitySettings()
                }
            }

            Section("Background Agent") {
                HStack {
                    Image(systemName: viewModel.agentRunning ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(viewModel.agentRunning ? .green : .orange)
                    Text(viewModel.agentStatusMessage)
                        .fontWeight(.medium)
                }

                Text("The background agent (wwkd) must be running to track time.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    Button("Start") {
                        viewModel.startAgent()
                    }
                    .disabled(viewModel.agentRunning)

                    Button("Stop") {
                        viewModel.stopAgent()
                    }
                    .disabled(!viewModel.agentRunning)

                    Button("Restart") {
                        viewModel.restartAgent()
                    }
                    .disabled(!viewModel.agentRunning)

                    Spacer()

                    Button {
                        viewModel.openAgentLogs()
                    } label: {
                        Label("View Logs", systemImage: "doc.text.magnifyingglass")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Diagnostics Preferences

struct DiagnosticsPreferencesView: View {
    @ObservedObject var viewModel: PreferencesViewModel
    @State private var copyFlash: Bool = false

    var body: some View {
        ScrollView {
            Form {
                Section("Agent Status") {
                    if viewModel.isManagedByCLI {
                        // CLI plist owns the launchd label
                        diagRow("Managed by", ok: true, detail: "CLI plist (wwk agent install)")
                        Text("SMAppService registration deferred — CLI plist takes precedence.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if viewModel.isPlistMissing {
                        // Dev build: plist not in bundle, show neutral indicators
                        diagRow("Registered", ok: nil, detail: "N/A — dev build (no LaunchAgent plist)")
                        diagRow("Enabled", ok: nil, detail: "N/A — dev build")
                    } else {
                        diagRow("Registered", ok: viewModel.agentRegistered, detail: viewModel.registrationStatusText)
                        diagRow("Enabled", ok: viewModel.agentEnabled,
                                detail: viewModel.requiresApproval ? "Requires approval in System Settings" : nil)
                    }
                    diagRow("Running", ok: viewModel.agentRunning)
                    LabeledContent("PID:") {
                        Text(viewModel.agentPID.map { String($0) } ?? "N/A")
                            .font(.system(.caption, design: .monospaced))
                    }
                    if viewModel.agentRunning {
                        LabeledContent("Version:") { Text(viewModel.agentVersion).font(.caption) }
                    }
                }

                Section("IPC Status") {
                    LabeledContent("Socket:") {
                        Text(viewModel.socketPath)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    diagRow("Socket exists", ok: viewModel.socketExists)
                    diagRow("IPC connection", ok: viewModel.ipcConnected)
                }

                Section("Database") {
                    LabeledContent("Path:") {
                        Text(viewModel.dataPath)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Size:") { Text(viewModel.dataSize).font(.caption) }
                    diagRow("Integrity", ok: viewModel.dbIntegrityOk, detail: viewModel.dbIntegrityText)
                    LabeledContent("Total events:") { Text("\(viewModel.totalEvents)").font(.system(.caption, design: .monospaced)) }
                    LabeledContent("Earliest:") { Text(viewModel.earliestEvent).font(.caption) }
                    LabeledContent("Latest:") { Text(viewModel.latestEvent).font(.caption) }
                    LabeledContent("Total tracked:") { Text(viewModel.totalTrackedTime).font(.caption) }
                    LabeledContent("Unique apps:") { Text("\(viewModel.uniqueApps)").font(.system(.caption, design: .monospaced)) }
                }

                Section("Permissions") {
                    diagRow("Accessibility (GUI)", ok: viewModel.accessibilityGranted)
                    diagRow("Accessibility (Agent)", ok: viewModel.agentRunning ? viewModel.agentAccessibilityGranted : nil,
                            detail: viewModel.agentRunning ? nil : "agent not running")
                    diagRow("App Group container", ok: viewModel.appGroupAccessible)
                }

                Section("Actions") {
                    HStack(spacing: 8) {
                        Button(viewModel.agentRegistered ? "Unregister Agent" : "Register Agent") {
                            if viewModel.agentRegistered {
                                viewModel.unregisterAgent()
                            } else {
                                viewModel.registerAgent()
                            }
                        }

                        Button("Login Items Settings") {
                            viewModel.openLoginItemsSettings()
                        }

                        Button("Accessibility Settings") {
                            viewModel.openAccessibilitySettings()
                        }
                    }

                    HStack(spacing: 8) {
                        Button {
                            Task { await viewModel.refreshStatus() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }

                        Button {
                            viewModel.copyDiagnosticsToClipboard()
                            copyFlash = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copyFlash = false }
                        } label: {
                            Label(copyFlash ? "Copied!" : "Copy Diagnostics", systemImage: "doc.on.clipboard")
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .padding(.horizontal)
    }

    private func diagRow(_ label: String, ok: Bool?, detail: String? = nil) -> some View {
        HStack {
            if let ok = ok {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(ok ? .green : .red)
                    .font(.caption)
            } else {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            Text(label)
                .font(.caption)
            if let detail = detail {
                Spacer()
                Text(detail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Data Preferences

struct DataPreferencesView: View {
    @ObservedObject var viewModel: PreferencesViewModel
    @State private var showingDeleteConfirmation: Bool = false

    var body: some View {
        Form {
            Section("Data Location") {
                LabeledContent("Database:") {
                    Text(viewModel.dataPath)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                LabeledContent("Size:") {
                    Text(viewModel.dataSize)
                }

                Button("Reveal in Finder") {
                    viewModel.revealInFinder()
                }
            }

            Section("Danger Zone") {
                Button("Delete All Data...", role: .destructive) {
                    showingDeleteConfirmation = true
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .confirmationDialog(
            "Delete All Data?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All Data", role: .destructive) {
                // TODO: Implement data deletion via XPC
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all tracked time data. This action cannot be undone.")
        }
    }
}

// MARK: - About Preferences

struct AboutPreferencesView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.fill")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("WellWhaddyaKnow")
                .font(.title)
                .fontWeight(.bold)

            Text("Version \(BuildVersion.version)")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("A local-only macOS time tracker")
                .font(.body)
                .foregroundColor(.secondary)

            Divider()

            VStack(spacing: 2) {
                Text("\"Time is an illusion, lunchtime doubly so.\"")
                    .font(.system(.callout, design: .serif))
                    .italic()
                    .foregroundColor(.accentColor)
                Text("— Ford Prefect, The Hitchhiker's Guide to the Galaxy")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)

            Divider()

            VStack(spacing: 8) {
                Link("View on GitHub", destination: URL(string: "https://github.com/Daylily-Informatics/well-whaddya-know")!)
                Link("Privacy Policy", destination: URL(string: "https://github.com/Daylily-Informatics/well-whaddya-know/blob/main/PRIVACY.md")!)
            }
            .font(.caption)

            Text("© 2024 Daylily Informatics. MIT License.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}


// MARK: - Display Timezone Helper

/// Shared helper for resolving the user's preferred display timezone.
/// Used by ViewerWindow, PreferencesWindow, TodayTotalCalculator, and exports.
enum DisplayTimezoneHelper {
    /// UserDefaults key (same as PreferencesViewModel.displayTimezoneKey).
    static let key = "com.daylily.wellwhaddyaknow.displayTimezone"

    /// Resolved preferred timezone. Falls back to system timezone if unset or invalid.
    static var preferred: TimeZone {
        if let id = UserDefaults.standard.string(forKey: key),
           !id.isEmpty,
           let tz = TimeZone(identifier: id) {
            return tz
        }
        return TimeZone.current
    }

    /// A Calendar configured with the preferred display timezone.
    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = preferred
        return cal
    }

    /// Human-readable label, e.g. "America/New_York (UTC-5)".
    static var displayLabel: String {
        let tz = preferred
        let offsetSeconds = tz.secondsFromGMT()
        let hours = offsetSeconds / 3600
        let minutes = abs(offsetSeconds % 3600) / 60
        let offsetStr: String
        if minutes == 0 {
            offsetStr = "UTC\(hours >= 0 ? "+" : "")\(hours)"
        } else {
            offsetStr = "UTC\(hours >= 0 ? "+" : "")\(hours):\(String(format: "%02d", minutes))"
        }
        if tz.identifier == TimeZone.current.identifier {
            return "\(tz.identifier) (\(offsetStr)) — System"
        }
        return "\(tz.identifier) (\(offsetStr))"
    }
}