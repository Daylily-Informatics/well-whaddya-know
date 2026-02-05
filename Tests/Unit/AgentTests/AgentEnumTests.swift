// SPDX-License-Identifier: MIT
// AgentEnumTests.swift - Unit tests for Agent enum types

import Testing
import Foundation
@testable import WellWhaddyaKnowAgent

// MARK: - SystemStateEventKind Tests

@Suite("SystemStateEventKind Tests")
struct SystemStateEventKindTests {
    
    @Test("All event kinds have expected raw values")
    func eventKindRawValues() {
        #expect(SystemStateEventKind.agentStart.rawValue == "agent_start")
        #expect(SystemStateEventKind.agentStop.rawValue == "agent_stop")
        #expect(SystemStateEventKind.stateChange.rawValue == "state_change")
        #expect(SystemStateEventKind.sleep.rawValue == "sleep")
        #expect(SystemStateEventKind.wake.rawValue == "wake")
        #expect(SystemStateEventKind.poweroff.rawValue == "poweroff")
        #expect(SystemStateEventKind.gapDetected.rawValue == "gap_detected")
        #expect(SystemStateEventKind.clockChange.rawValue == "clock_change")
        #expect(SystemStateEventKind.tzChange.rawValue == "tz_change")
        #expect(SystemStateEventKind.accessibilityDenied.rawValue == "accessibility_denied")
        #expect(SystemStateEventKind.accessibilityGranted.rawValue == "accessibility_granted")
    }
    
    @Test("SystemStateEventKind is Sendable")
    func eventKindIsSendable() async {
        let kind = SystemStateEventKind.agentStart
        let task = Task {
            return kind.rawValue
        }
        let result = await task.value
        #expect(result == "agent_start")
    }
    
    @Test("SystemStateEventKind can be constructed from raw value")
    func eventKindFromRawValue() {
        let kind = SystemStateEventKind(rawValue: "gap_detected")
        #expect(kind == .gapDetected)
        
        let invalid = SystemStateEventKind(rawValue: "invalid")
        #expect(invalid == nil)
    }
}

// MARK: - ActivityEventReason Tests

@Suite("ActivityEventReason Tests")
struct ActivityEventReasonTests {
    
    @Test("All activity reasons have expected raw values")
    func activityReasonRawValues() {
        #expect(ActivityEventReason.workingBegan.rawValue == "working_began")
        #expect(ActivityEventReason.appActivated.rawValue == "app_activated")
        #expect(ActivityEventReason.axTitleChanged.rawValue == "ax_title_changed")
        #expect(ActivityEventReason.axFocusedWindowChanged.rawValue == "ax_focused_window_changed")
        #expect(ActivityEventReason.pollFallback.rawValue == "poll_fallback")
    }
    
    @Test("ActivityEventReason is Sendable")
    func activityReasonIsSendable() async {
        let reason = ActivityEventReason.workingBegan
        let task = Task {
            return reason.rawValue
        }
        let result = await task.value
        #expect(result == "working_began")
    }
}

// MARK: - TitleStatus Tests

@Suite("TitleStatus Tests")
struct TitleStatusTests {
    
    @Test("All title statuses have expected raw values")
    func titleStatusRawValues() {
        #expect(TitleStatus.ok.rawValue == "ok")
        #expect(TitleStatus.noPermission.rawValue == "no_permission")
        #expect(TitleStatus.notSupported.rawValue == "not_supported")
        #expect(TitleStatus.noWindow.rawValue == "no_window")
        #expect(TitleStatus.error.rawValue == "error")
    }
    
    @Test("TitleStatus is Sendable")
    func titleStatusIsSendable() async {
        let status = TitleStatus.noWindow
        let task = Task {
            return status.rawValue
        }
        let result = await task.value
        #expect(result == "no_window")
    }
    
    @Test("TitleStatus can be constructed from raw value")
    func titleStatusFromRawValue() {
        let status = TitleStatus(rawValue: "no_permission")
        #expect(status == .noPermission)
        
        let invalid = TitleStatus(rawValue: "invalid")
        #expect(invalid == nil)
    }
}

// MARK: - Edge Cases

@Suite("Agent Enum Edge Cases")
struct AgentEnumEdgeCaseTests {
    
    @Test("Raw values are compatible with SQLite storage")
    func rawValuesAreValidSqlStrings() {
        // Ensure raw values don't contain characters that would break SQL
        let allKinds: [SystemStateEventKind] = [
            .agentStart, .agentStop, .stateChange, .sleep, .wake,
            .poweroff, .gapDetected, .clockChange, .tzChange,
            .accessibilityDenied, .accessibilityGranted
        ]
        
        for kind in allKinds {
            #expect(!kind.rawValue.contains("'"), "Raw value should not contain single quotes")
            #expect(!kind.rawValue.contains("\""), "Raw value should not contain double quotes")
            #expect(!kind.rawValue.contains(";"), "Raw value should not contain semicolons")
        }
    }
    
    @Test("Activity reasons are compatible with SQLite storage")
    func activityReasonsAreValidSqlStrings() {
        let allReasons: [ActivityEventReason] = [
            .workingBegan, .appActivated, .axTitleChanged,
            .axFocusedWindowChanged, .pollFallback
        ]
        
        for reason in allReasons {
            #expect(!reason.rawValue.contains("'"))
            #expect(!reason.rawValue.contains("\""))
            #expect(!reason.rawValue.contains(";"))
        }
    }
}

