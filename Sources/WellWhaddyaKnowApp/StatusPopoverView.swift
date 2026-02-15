// SPDX-License-Identifier: MIT
// StatusPopoverView.swift - SwiftUI popover content for menu bar UI

import SwiftUI
import AppKit

/// Main popover view displaying current status and controls.
struct StatusPopoverView: View {
    @ObservedObject var viewModel: StatusViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("WellWhaddyaKnow")
                    .font(.headline)
                Spacer()
                StatusIndicator(isWorking: viewModel.isWorking, agentReachable: viewModel.agentReachable)
            }

            Divider()

            // Status section
            if viewModel.agentReachable {
                StatusSection(viewModel: viewModel)
            } else {
                AgentNotRunningView(errorMessage: viewModel.errorMessage)
            }

            // Accessibility warning
            if viewModel.accessibilityStatus == .denied || viewModel.accessibilityStatus == .unknown {
                AccessibilityWarningView(
                    status: viewModel.accessibilityStatus,
                    onOpenSettings: viewModel.openSystemSettings
                )
            }

            Divider()

            // Today's total
            TodayTotalView(totalSeconds: viewModel.todayTotalSeconds)

            // Recent activity
            if !viewModel.recentActivity.isEmpty {
                Divider()
                RecentActivityView(entries: viewModel.recentActivity)
            }

            Divider()

            // Action buttons
            ActionButtonsView(viewModel: viewModel)
        }
        .padding()
        .frame(width: 320)
    }
}

/// Status indicator showing working/not working state.
struct StatusIndicator: View {
    let isWorking: Bool
    let agentReachable: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var statusColor: Color {
        if !agentReachable { return .gray }
        return isWorking ? .green : .orange
    }

    private var statusText: String {
        if !agentReachable { return "Offline" }
        return isWorking ? "Working" : "Not working"
    }
}

/// Status section showing current app and title.
struct StatusSection: View {
    @ObservedObject var viewModel: StatusViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let app = viewModel.currentApp {
                LabeledContent("App:", value: app)
            }
            if let title = viewModel.currentTitle {
                LabeledContent("Title:", value: title)
                    .lineLimit(2)
            }
        }
        .font(.system(.body, design: .monospaced))
    }
}

/// View shown when agent is not running, with specific error details.
struct AgentNotRunningView: View {
    let errorMessage: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
                .font(.title2)
            Text(errorMessage ?? "Agent not running")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

/// Accessibility permission warning view.
struct AccessibilityWarningView: View {
    let status: AccessibilityDisplayStatus
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                Text(warningText)
                    .font(.caption)
            }

            Text("Add this app to System Settings → Privacy & Security → Accessibility:")
                .font(.caption2)
                .foregroundColor(.secondary)

            HStack(spacing: 4) {
                Text(Bundle.main.bundlePath)
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Bundle.main.bundlePath, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .font(.caption2)
                .help("Copy path")
            }

            Button("Open System Settings") {
                onOpenSettings()
            }
            .font(.caption)
        }
        .padding(8)
        .background(Color.yellow.opacity(0.1))
        .cornerRadius(6)
    }

    private var warningText: String {
        switch status {
        case .denied:
            return "Accessibility permission denied. Window titles unavailable."
        case .unknown:
            return "Accessibility permission not checked."
        case .granted:
            return ""
        }
    }
}

/// Today's total working time display.
struct TodayTotalView: View {
    let totalSeconds: Double

    var body: some View {
        HStack {
            Text("Today:")
                .font(.subheadline)
            Spacer()
            Text(formattedDuration)
                .font(.system(.title2, design: .monospaced))
                .fontWeight(.medium)
        }
    }

    private var formattedDuration: String {
        let hours = Int(totalSeconds) / 3600
        let minutes = (Int(totalSeconds) % 3600) / 60
        return "\(hours)h \(minutes)m"
    }
}

/// Recent activity summary showing last 5 active windows.
struct RecentActivityView: View {
    let entries: [RecentActivityEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent Activity")
                .font(.caption)
                .foregroundColor(.secondary)
                .fontWeight(.medium)

            ForEach(entries) { entry in
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.appName)
                            .font(.system(.caption, design: .default))
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text(entry.windowTitle ?? "unavailable")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer()
                    Text(entry.durationText)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

/// Action buttons at the bottom of the popover.
struct ActionButtonsView: View {
    @ObservedObject var viewModel: StatusViewModel

    var body: some View {
        VStack(spacing: 10) {
            // Primary action: tracking toggle (full width, prominent)
            Button {
                Task {
                    await viewModel.toggleTracking()
                }
            } label: {
                HStack {
                    Image(systemName: viewModel.isWorking ? "pause.circle.fill" : "play.circle.fill")
                    Text(viewModel.isWorking ? "Stop Tracking" : "Start Tracking")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.isWorking ? .orange : .green)
            .controlSize(.large)
            .disabled(!viewModel.agentReachable)

            // Navigation row: equal-width buttons
            HStack(spacing: 8) {
                Button {
                    WindowManager.shared.openViewerWindow()
                } label: {
                    Label("Viewer", systemImage: "eye")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    WindowManager.shared.openViewerWindow(tab: .exports)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    WindowManager.shared.openPreferencesWindow()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.regular)

            // Quit: right-aligned, subdued
            HStack {
                Spacer()
                Button(role: .destructive) {
                    viewModel.quitApp()
                } label: {
                    Label("Quit", systemImage: "power")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

/// Manages application windows (viewer and preferences)
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private var viewerWindow: NSWindow?
    private var preferencesWindow: NSWindow?

    private init() {}

    func openViewerWindow(tab: ViewerTab = .timeline) {
        if let window = viewerWindow, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let viewerView = ViewerWindow()
        let hostingController = NSHostingController(rootView: viewerView)
        hostingController.sizingOptions = []

        let window = NSWindow(contentViewController: hostingController)
        window.title = "WellWhaddyaKnow Viewer"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 900, height: 600))
        window.minSize = NSSize(width: 800, height: 500)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        self.viewerWindow = window
    }

    func openPreferencesWindow() {
        if let window = preferencesWindow, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let preferencesView = PreferencesWindow()
        let hostingController = NSHostingController(rootView: preferencesView)
        hostingController.sizingOptions = []

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Preferences"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 560, height: 520))
        window.minSize = NSSize(width: 480, height: 400)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        self.preferencesWindow = window
    }
}
