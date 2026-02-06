// SPDX-License-Identifier: MIT
// PreferencesWindow.swift - Preferences window per SPEC.md Section 9.3

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
        .frame(minWidth: 560, minHeight: 520)
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

    // Diagnostics properties
    @Published var agentPID: Int? = nil
    @Published var registrationStatusText: String = "Unknown"
    @Published var agentRegistered: Bool = false
    @Published var agentEnabled: Bool = false
    @Published var requiresApproval: Bool = false
    @Published var isPlistMissing: Bool = false
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

    private let xpcClient = XPCClient()

    func refreshStatus() async {
        isRefreshing = true
        defer { isRefreshing = false }

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

        // Agent lifecycle (SMAppService)
        let lifecycle = AgentLifecycleManager.shared
        lifecycle.refreshStatus()
        registrationStatusText = lifecycle.statusDescription
        agentRegistered = lifecycle.isRegistered
        agentEnabled = lifecycle.isEnabled
        requiresApproval = lifecycle.requiresApproval
        isPlistMissing = lifecycle.isPlistMissing

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

            switch status.accessibilityStatus {
            case .granted:
                accessibilityGranted = true
            case .denied, .unknown:
                accessibilityGranted = false
            }
        } catch {
            agentRunning = false
            isCurrentlyWorking = false
            agentVersion = ""
            agentUptime = 0
            agentPID = nil
            agentStatusMessage = "Not running"
            accessibilityGranted = false
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

    func requestAccessibilityPermission() {
        // Trigger the system prompt via AXIsProcessTrustedWithOptions
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true] as CFDictionary
        let granted = AXIsProcessTrustedWithOptions(options)
        accessibilityGranted = granted
    }

    func startAgent() {
        // Clean up stale socket before starting (agent can't bind if orphan socket exists)
        let sock = getIPCSocketPath()
        if FileManager.default.fileExists(atPath: sock) {
            try? FileManager.default.removeItem(atPath: sock)
            prefLog.info("Removed stale socket before agent start")
        }

        // Build candidate paths for the wwkd binary
        let bundleAgentPath: String
        if let bundlePath = Bundle.main.executablePath {
            let bundleDir = (bundlePath as NSString).deletingLastPathComponent
            bundleAgentPath = (bundleDir as NSString).appendingPathComponent("wwkd")
        } else {
            bundleAgentPath = "/usr/local/bin/wwkd"
        }

        let candidates = [
            bundleAgentPath,
            ProcessInfo.processInfo.environment["HOME"].map { "\($0)/projects/daylily/well-whaddya-know/.build/debug/wwkd" } ?? "",
            "/usr/local/bin/wwkd",
        ]

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            prefLog.info("Starting agent from: \(path)")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = []
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                agentStatusMessage = "Starting..."
                prefLog.info("Agent process launched (pid \(process.processIdentifier))")
            } catch {
                prefLog.error("Failed to launch agent at \(path): \(error.localizedDescription)")
                agentStatusMessage = "Launch failed: \(error.localizedDescription)"
            }
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await refreshStatus()
            }
            return
        }
        prefLog.error("Cannot find wwkd binary in any candidate path")
        agentStatusMessage = "Cannot find wwkd binary"
    }

    func stopAgent() {
        agentStatusMessage = "Stopping..."
        prefLog.info("Stopping agent via pkill")
        Task.detached {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            task.arguments = ["-TERM", "wwkd"]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                task.waitUntilExit()
                prefLog.info("pkill exited with status \(task.terminationStatus)")
            } catch {
                prefLog.error("pkill failed: \(error.localizedDescription)")
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
        prefLog.info("Restarting agent")
        Task.detached {
            // Stop
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            task.arguments = ["-TERM", "wwkd"]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()

            // Wait for agent to exit, clean socket
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let sock = getIPCSocketPath()
            if FileManager.default.fileExists(atPath: sock) {
                try? FileManager.default.removeItem(atPath: sock)
            }

            // Start on main actor
            await MainActor.run { [weak self] in
                self?.startAgent()
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
        do {
            try AgentLifecycleManager.shared.register()
        } catch {
            agentStatusMessage = "Registration failed: \(error.localizedDescription)"
        }
        AgentLifecycleManager.shared.refreshStatus()
        registrationStatusText = AgentLifecycleManager.shared.statusDescription
        agentRegistered = AgentLifecycleManager.shared.isRegistered
        agentEnabled = AgentLifecycleManager.shared.isEnabled
        requiresApproval = AgentLifecycleManager.shared.requiresApproval
    }

    func unregisterAgent() {
        do {
            try AgentLifecycleManager.shared.unregister()
        } catch {
            agentStatusMessage = "Unregistration failed: \(error.localizedDescription)"
        }
        AgentLifecycleManager.shared.refreshStatus()
        registrationStatusText = AgentLifecycleManager.shared.statusDescription
        agentRegistered = AgentLifecycleManager.shared.isRegistered
        agentEnabled = AgentLifecycleManager.shared.isEnabled
        requiresApproval = AgentLifecycleManager.shared.requiresApproval
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
            "  Accessibility: \(accessibilityGranted ? "Granted" : "Denied")",
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

    var body: some View {
        Form {
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
                HStack {
                    Image(systemName: viewModel.accessibilityGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(viewModel.accessibilityGranted ? .green : .red)
                    Text(viewModel.accessibilityGranted ? "Permission granted ✓" : "Permission not granted")
                        .fontWeight(.medium)
                    Spacer()
                    if viewModel.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if !viewModel.accessibilityGranted {
                    Text("Window title capture requires Accessibility permission. Click \"Request Permission\" to trigger the system prompt, or open System Settings and add this app manually.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Accessibility permission is active. Window titles are being captured.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    Button("Request Permission") {
                        viewModel.requestAccessibilityPermission()
                    }
                    .disabled(viewModel.accessibilityGranted)

                    Button("Open Settings") {
                        viewModel.openAccessibilitySettings()
                    }

                    Button {
                        Task { await viewModel.refreshStatus() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
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
                    if viewModel.isPlistMissing {
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
                    diagRow("Accessibility", ok: viewModel.accessibilityGranted)
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

            Text("Version 0.1.0")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("A local-only macOS time tracker")
                .font(.body)
                .foregroundColor(.secondary)

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
