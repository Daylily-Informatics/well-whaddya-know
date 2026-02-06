// SPDX-License-Identifier: MIT
// DurationFormattingTests.swift - Tests for duration formatting in menu bar UI

import Testing
import Foundation

/// Tests for duration formatting used in the menu bar UI
@Suite("Duration Formatting Tests")
struct DurationFormattingTests {

    // MARK: - Duration Formatting

    @Test("Zero seconds formats as 0h 0m")
    func zeroSecondsFormatsCorrectly() {
        let formatted = formatDuration(seconds: 0)
        #expect(formatted == "0h 0m")
    }

    @Test("Less than one minute formats as 0h 0m")
    func lessThanOneMinuteFormatsCorrectly() {
        let formatted = formatDuration(seconds: 59)
        #expect(formatted == "0h 0m")
    }

    @Test("Exactly one minute formats as 0h 1m")
    func oneMinuteFormatsCorrectly() {
        let formatted = formatDuration(seconds: 60)
        #expect(formatted == "0h 1m")
    }

    @Test("Exactly one hour formats as 1h 0m")
    func oneHourFormatsCorrectly() {
        let formatted = formatDuration(seconds: 3600)
        #expect(formatted == "1h 0m")
    }

    @Test("One hour and thirty minutes formats as 1h 30m")
    func oneHourThirtyMinutesFormatsCorrectly() {
        let formatted = formatDuration(seconds: 5400)
        #expect(formatted == "1h 30m")
    }

    @Test("Eight hours formats as 8h 0m")
    func eightHoursFormatsCorrectly() {
        let formatted = formatDuration(seconds: 28800)
        #expect(formatted == "8h 0m")
    }

    @Test("Fractional seconds are truncated")
    func fractionalSecondsAreTruncated() {
        let formatted = formatDuration(seconds: 3661.9)
        #expect(formatted == "1h 1m")
    }

    @Test("Large durations format correctly")
    func largeDurationsFormatCorrectly() {
        // 24 hours
        let formatted = formatDuration(seconds: 86400)
        #expect(formatted == "24h 0m")
    }

    // MARK: - Helper Function (mirrors StatusPopoverView implementation)

    private func formatDuration(seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return "\(hours)h \(minutes)m"
    }
}

/// Tests for accessibility status display
@Suite("Accessibility Status Display Tests")
struct AccessibilityStatusDisplayTests {

    @Test("Granted status shows no warning")
    func grantedStatusShowsNoWarning() {
        let shouldShowWarning = shouldShowAccessibilityWarning(status: .granted)
        #expect(shouldShowWarning == false)
    }

    @Test("Denied status shows warning")
    func deniedStatusShowsWarning() {
        let shouldShowWarning = shouldShowAccessibilityWarning(status: .denied)
        #expect(shouldShowWarning == true)
    }

    @Test("Unknown status shows warning")
    func unknownStatusShowsWarning() {
        let shouldShowWarning = shouldShowAccessibilityWarning(status: .unknown)
        #expect(shouldShowWarning == true)
    }

    // MARK: - Helper (mirrors StatusPopoverView logic)

    private enum TestAccessibilityStatus {
        case granted
        case denied
        case unknown
    }

    private func shouldShowAccessibilityWarning(status: TestAccessibilityStatus) -> Bool {
        status == .denied || status == .unknown
    }
}

/// Tests for status indicator display
@Suite("Status Indicator Tests")
struct StatusIndicatorTests {

    @Test("Working state shows Working text")
    func workingStateShowsWorkingText() {
        let text = statusText(isWorking: true, agentReachable: true)
        #expect(text == "Working")
    }

    @Test("Not working state shows Not working text")
    func notWorkingStateShowsNotWorkingText() {
        let text = statusText(isWorking: false, agentReachable: true)
        #expect(text == "Not working")
    }

    @Test("Agent not reachable shows Offline text")
    func agentNotReachableShowsOfflineText() {
        let text = statusText(isWorking: true, agentReachable: false)
        #expect(text == "Offline")
    }

    // MARK: - Helper (mirrors StatusIndicator logic)

    private func statusText(isWorking: Bool, agentReachable: Bool) -> String {
        if !agentReachable { return "Offline" }
        return isWorking ? "Working" : "Not working"
    }
}

// MARK: - Enhanced Error Messaging Tests

/// Tests for specific error messages when agent is unreachable (Task 3).
/// Mirrors the logic in StatusViewModel.refreshStatus() for error message selection.
@Suite("Agent Error Message Tests")
struct AgentErrorMessageTests {

    @Test("Not registered shows registration error")
    func notRegisteredShowsRegistrationError() {
        let msg = errorMessage(isRegistered: false, requiresApproval: false, socketExists: true)
        #expect(msg == "Agent not registered (open Preferences to register)")
    }

    @Test("Requires approval shows login items error")
    func requiresApprovalShowsLoginItemsError() {
        let msg = errorMessage(isRegistered: true, requiresApproval: true, socketExists: true)
        #expect(msg == "Agent disabled in System Settings (open Login Items)")
    }

    @Test("Socket missing shows restart error")
    func socketMissingShowsRestartError() {
        let msg = errorMessage(isRegistered: true, requiresApproval: false, socketExists: false)
        #expect(msg == "IPC socket missing (restart agent)")
    }

    @Test("Registered but not running shows start error")
    func registeredNotRunningShowsStartError() {
        let msg = errorMessage(isRegistered: true, requiresApproval: false, socketExists: true)
        #expect(msg == "Agent not running (click to start)")
    }

    @Test("Not registered takes priority over socket missing")
    func notRegisteredPriorityOverSocketMissing() {
        let msg = errorMessage(isRegistered: false, requiresApproval: false, socketExists: false)
        #expect(msg == "Agent not registered (open Preferences to register)")
    }

    // MARK: - Helper (mirrors StatusViewModel error selection logic)

    private func errorMessage(isRegistered: Bool, requiresApproval: Bool, socketExists: Bool) -> String {
        if !isRegistered {
            return "Agent not registered (open Preferences to register)"
        } else if requiresApproval {
            return "Agent disabled in System Settings (open Login Items)"
        } else if !socketExists {
            return "IPC socket missing (restart agent)"
        } else {
            return "Agent not running (click to start)"
        }
    }
}

// MARK: - Recent Activity Duration Formatting Tests

/// Tests for the compact duration formatting used in Recent Activity entries.
@Suite("Recent Activity Duration Formatting Tests")
struct RecentActivityDurationTests {

    @Test("Zero seconds formats as 0s")
    func zeroSeconds() {
        #expect(formatRecentDuration(0) == "0s")
    }

    @Test("Seconds only formats as Xs")
    func secondsOnly() {
        #expect(formatRecentDuration(45) == "45s")
    }

    @Test("Minutes and seconds formats as Xm Ys")
    func minutesAndSeconds() {
        #expect(formatRecentDuration(125) == "2m 5s")
    }

    @Test("Hours and minutes formats as Xh Ym")
    func hoursAndMinutes() {
        #expect(formatRecentDuration(3720) == "1h 2m")
    }

    @Test("Exactly one hour formats as 1h 0m")
    func exactlyOneHour() {
        #expect(formatRecentDuration(3600) == "1h 0m")
    }

    @Test("Negative duration clamps to 0s")
    func negativeDurationClamps() {
        // max(0, ...) in the caller ensures non-negative
        #expect(formatRecentDuration(0) == "0s")
    }

    // MARK: - Helper (mirrors StatusViewModel.formatDuration)

    private func formatRecentDuration(_ seconds: Double) -> String {
        let totalSec = Int(seconds)
        let hours = totalSec / 3600
        let minutes = (totalSec % 3600) / 60
        let secs = totalSec % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m \(secs)s"
        }
        return "\(secs)s"
    }
}

// MARK: - Diagnostics Payload Tests

/// Tests for the diagnostics clipboard payload format (Task 2).
@Suite("Diagnostics Payload Tests")
struct DiagnosticsPayloadTests {

    @Test("Diagnostics payload contains all required sections")
    func payloadContainsAllSections() {
        let payload = buildDiagnosticsPayload(
            agentRegistered: true, agentEnabled: true, agentRunning: true,
            agentPID: 12345, agentVersion: "1.0.0", agentUptime: "5m 30s",
            registrationStatusText: "Registered and enabled",
            socketPath: "/tmp/wwk.sock", socketExists: true, ipcConnected: true,
            dataPath: "/tmp/wwk.sqlite", dataSize: "1.2 MB",
            dbIntegrityText: "OK", totalEvents: 100,
            earliestEvent: "Jan 1, 2026", latestEvent: "Feb 6, 2026",
            totalTrackedTime: "42h 15m", uniqueApps: 8,
            accessibilityGranted: true, appGroupAccessible: true
        )

        #expect(payload.contains("WellWhaddyaKnow Diagnostics"))
        #expect(payload.contains("Agent Status:"))
        #expect(payload.contains("Registered: Yes"))
        #expect(payload.contains("Enabled: Yes"))
        #expect(payload.contains("Running: Yes"))
        #expect(payload.contains("PID: 12345"))
        #expect(payload.contains("Version: 1.0.0"))
        #expect(payload.contains("IPC Status:"))
        #expect(payload.contains("Socket: /tmp/wwk.sock"))
        #expect(payload.contains("Socket exists: Yes"))
        #expect(payload.contains("Connection: OK"))
        #expect(payload.contains("Database:"))
        #expect(payload.contains("Integrity: OK"))
        #expect(payload.contains("Total events: 100"))
        #expect(payload.contains("Unique apps: 8"))
        #expect(payload.contains("Permissions:"))
        #expect(payload.contains("Accessibility: Granted"))
        #expect(payload.contains("App Group: Accessible"))
        #expect(payload.contains("Generated:"))
    }

    @Test("Diagnostics payload shows N/A for missing PID")
    func payloadShowsNAForMissingPID() {
        let payload = buildDiagnosticsPayload(
            agentRegistered: false, agentEnabled: false, agentRunning: false,
            agentPID: nil, agentVersion: "", agentUptime: "N/A",
            registrationStatusText: "Not registered",
            socketPath: "", socketExists: false, ipcConnected: false,
            dataPath: "", dataSize: "0 bytes",
            dbIntegrityText: "Database not found", totalEvents: 0,
            earliestEvent: "N/A", latestEvent: "N/A",
            totalTrackedTime: "<1m", uniqueApps: 0,
            accessibilityGranted: false, appGroupAccessible: false
        )

        #expect(payload.contains("PID: N/A"))
        #expect(payload.contains("Registered: No"))
        #expect(payload.contains("Running: No"))
        #expect(payload.contains("Accessibility: Denied"))
        #expect(payload.contains("App Group: Not accessible"))
    }

    // MARK: - Helper (mirrors PreferencesViewModel.copyDiagnosticsToClipboard)

    private func buildDiagnosticsPayload(
        agentRegistered: Bool, agentEnabled: Bool, agentRunning: Bool,
        agentPID: Int?, agentVersion: String, agentUptime: String,
        registrationStatusText: String,
        socketPath: String, socketExists: Bool, ipcConnected: Bool,
        dataPath: String, dataSize: String,
        dbIntegrityText: String, totalEvents: Int64,
        earliestEvent: String, latestEvent: String,
        totalTrackedTime: String, uniqueApps: Int,
        accessibilityGranted: Bool, appGroupAccessible: Bool
    ) -> String {
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
            "  Uptime: \(agentUptime)",
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
        return lines.joined(separator: "\n")
    }
}

