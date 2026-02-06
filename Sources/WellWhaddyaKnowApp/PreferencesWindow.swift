// SPDX-License-Identifier: MIT
// PreferencesWindow.swift - Preferences window per SPEC.md Section 9.3

import SwiftUI
import XPCProtocol

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

            DataPreferencesView(viewModel: viewModel)
                .tabItem {
                    Label("Data", systemImage: "externaldrive")
                }

            AboutPreferencesView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 500, height: 420)
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

    private let xpcClient = XPCClient()

    func refreshStatus() async {
        isRefreshing = true
        defer { isRefreshing = false }

        // Get data path
        let appGroupId = "group.com.daylily.wellwhaddyaknow"
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) {
            dataPath = containerURL
                .appendingPathComponent("WellWhaddyaKnow")
                .appendingPathComponent("wwk.sqlite")
                .path

            // Get file size
            if let attrs = try? FileManager.default.attributesOfItem(atPath: dataPath),
               let size = attrs[.size] as? Int64 {
                dataSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            }
        }

        // Query agent via IPC for real status
        do {
            let status = try await xpcClient.getStatus()
            agentRunning = true
            agentVersion = status.agentVersion
            agentUptime = status.agentUptime
            agentStatusMessage = "Running (v\(status.agentVersion), uptime \(formatUptime(status.agentUptime)))"

            switch status.accessibilityStatus {
            case .granted:
                accessibilityGranted = true
            case .denied, .unknown:
                accessibilityGranted = false
            }
        } catch {
            agentRunning = false
            agentVersion = ""
            agentUptime = 0
            agentStatusMessage = "Not running"
            accessibilityGranted = false
        }
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
        // Launch wwkd from the same bundle location
        let agentPath: String
        if let bundlePath = Bundle.main.executablePath {
            let bundleDir = (bundlePath as NSString).deletingLastPathComponent
            agentPath = (bundleDir as NSString).appendingPathComponent("wwkd")
        } else {
            agentPath = "/usr/local/bin/wwkd"
        }

        // Check common locations
        let candidates = [
            agentPath,
            ProcessInfo.processInfo.environment["HOME"].map { "\($0)/projects/daylily/well-whaddya-know/.build/debug/wwkd" } ?? "",
            "/usr/local/bin/wwkd",
        ]

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = []
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            agentStatusMessage = "Starting..."
            // Refresh after a short delay
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await refreshStatus()
            }
            return
        }
        agentStatusMessage = "Cannot find wwkd binary"
    }

    func stopAgent() {
        // Send SIGTERM to wwkd
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-TERM", "-f", "wwkd"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        agentStatusMessage = "Stopping..."
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await refreshStatus()
        }
    }

    func restartAgent() {
        stopAgent()
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            startAgent()
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
