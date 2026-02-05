// SPDX-License-Identifier: MIT
// StatusPopoverView.swift - SwiftUI popover content for menu bar UI

import SwiftUI

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
                AgentNotRunningView()
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

            Divider()

            // Action buttons
            ActionButtonsView(viewModel: viewModel)
        }
        .padding()
        .frame(width: 300)
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

/// View shown when agent is not running.
struct AgentNotRunningView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
                .font(.title2)
            Text("Agent not running")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("Start wwkd to track time")
                .font(.caption)
                .foregroundColor(.secondary)
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

/// Action buttons at the bottom of the popover.
struct ActionButtonsView: View {
    @ObservedObject var viewModel: StatusViewModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button("Open Viewer") {
                    // TODO: Open viewer window
                }
                .disabled(true) // Stub
                Button("Export...") {
                    // TODO: Open export dialog
                }
                .disabled(true) // Stub
            }
            HStack(spacing: 8) {
                Button("Preferences...") {
                    // TODO: Open preferences
                }
                .disabled(true) // Stub
                Spacer()
                Button("Quit") {
                    viewModel.quitApp()
                }
            }
        }
    }
}

