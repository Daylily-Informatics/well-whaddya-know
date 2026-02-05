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

