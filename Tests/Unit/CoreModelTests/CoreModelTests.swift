// SPDX-License-Identifier: MIT
// CoreModelTests.swift - Unit tests for CoreModel domain types

import Testing
@testable import CoreModel

// MARK: - Value Type Tests

@Suite("TimestampUTC Tests")
struct TimestampUTCTests {
    @Test("TimestampUTC construction and equality")
    func timestampConstruction() {
        let ts1 = TimestampUTC(1_000_000)
        let ts2 = TimestampUTC(1_000_000)
        let ts3 = TimestampUTC(2_000_000)
        
        #expect(ts1 == ts2)
        #expect(ts1 != ts3)
        #expect(ts1.microseconds == 1_000_000)
    }
    
    @Test("TimestampUTC comparison")
    func timestampComparison() {
        let ts1 = TimestampUTC(1_000_000)
        let ts2 = TimestampUTC(2_000_000)
        
        #expect(ts1 < ts2)
        #expect(ts2 > ts1)
    }
}

@Suite("MonotonicTimestamp Tests")
struct MonotonicTimestampTests {
    @Test("MonotonicTimestamp construction and equality")
    func monotonicConstruction() {
        let mt1 = MonotonicTimestamp(1_000_000_000)
        let mt2 = MonotonicTimestamp(1_000_000_000)
        let mt3 = MonotonicTimestamp(2_000_000_000)
        
        #expect(mt1 == mt2)
        #expect(mt1 != mt3)
        #expect(mt1.nanoseconds == 1_000_000_000)
    }
    
    @Test("MonotonicTimestamp comparison")
    func monotonicComparison() {
        let mt1 = MonotonicTimestamp(1_000_000_000)
        let mt2 = MonotonicTimestamp(2_000_000_000)
        
        #expect(mt1 < mt2)
        #expect(mt2 > mt1)
    }
}

@Suite("TimeRange Tests")
struct TimeRangeTests {
    @Test("TimeRange valid construction")
    func validConstruction() throws {
        let range = try TimeRange(startUs: 1_000_000, endUs: 2_000_000)
        
        #expect(range.startUs == 1_000_000)
        #expect(range.endUs == 2_000_000)
        #expect(range.durationUs == 1_000_000)
        #expect(range.durationSeconds == 1.0)
    }
    
    @Test("TimeRange throws on invalid range (end <= start)")
    func invalidRangeThrows() {
        #expect(throws: TimeRange.Error.self) {
            _ = try TimeRange(startUs: 2_000_000, endUs: 1_000_000)
        }
    }
    
    @Test("TimeRange throws on zero-length range")
    func zeroLengthThrows() {
        #expect(throws: TimeRange.Error.self) {
            _ = try TimeRange(startUs: 1_000_000, endUs: 1_000_000)
        }
    }
    
    @Test("TimeRange equality")
    func rangeEquality() throws {
        let range1 = try TimeRange(startUs: 1_000_000, endUs: 2_000_000)
        let range2 = try TimeRange(startUs: 1_000_000, endUs: 2_000_000)
        let range3 = try TimeRange(startUs: 1_000_000, endUs: 3_000_000)
        
        #expect(range1 == range2)
        #expect(range1 != range3)
    }
}

// MARK: - Domain Type Tests

@Suite("Identity Tests")
struct IdentityTests {
    @Test("Identity construction and equality")
    func identityConstruction() {
        let id1 = Identity(
            machineId: "uuid-1",
            username: "testuser",
            uid: 501,
            createdTsUs: 1_000_000,
            appGroupId: "com.test.group"
        )
        let id2 = Identity(
            machineId: "uuid-1",
            username: "testuser",
            uid: 501,
            createdTsUs: 1_000_000,
            appGroupId: "com.test.group"
        )
        
        #expect(id1 == id2)
        #expect(id1.identityId == 1)  // Default value
        #expect(id1.machineId == "uuid-1")
    }
}

@Suite("AgentRun Tests")
struct AgentRunTests {
    @Test("AgentRun construction and equality")
    func agentRunConstruction() {
        let run1 = AgentRun(
            runId: "run-uuid-1",
            startedTsUs: 1_000_000,
            startedMonotonicNs: 1_000_000_000,
            agentVersion: "1.0.0",
            osVersion: "14.0"
        )
        let run2 = AgentRun(
            runId: "run-uuid-1",
            startedTsUs: 1_000_000,
            startedMonotonicNs: 1_000_000_000,
            agentVersion: "1.0.0",
            osVersion: "14.0"
        )
        
        #expect(run1 == run2)
        #expect(run1.runId == "run-uuid-1")
    }
}

@Suite("Application Tests")
struct ApplicationTests {
    @Test("Application construction and equality")
    func applicationConstruction() {
        let app1 = Application(
            appId: 1,
            bundleId: "com.test.app",
            displayName: "Test App",
            firstSeenTsUs: 1_000_000
        )
        let app2 = Application(
            appId: 1,
            bundleId: "com.test.app",
            displayName: "Test App",
            firstSeenTsUs: 1_000_000
        )

        #expect(app1 == app2)
        #expect(app1.bundleId == "com.test.app")
    }
}

@Suite("WindowTitle Tests")
struct WindowTitleTests {
    @Test("WindowTitle construction and equality")
    func windowTitleConstruction() {
        let title1 = WindowTitle(
            titleId: 1,
            title: "Test Window",
            firstSeenTsUs: 1_000_000
        )
        let title2 = WindowTitle(
            titleId: 1,
            title: "Test Window",
            firstSeenTsUs: 1_000_000
        )

        #expect(title1 == title2)
        #expect(title1.title == "Test Window")
    }
}

@Suite("Tag Tests")
struct TagTests {
    @Test("Tag construction and equality")
    func tagConstruction() {
        let tag1 = Tag(
            tagId: 1,
            name: "work",
            createdTsUs: 1_000_000
        )
        let tag2 = Tag(
            tagId: 1,
            name: "work",
            createdTsUs: 1_000_000
        )

        #expect(tag1 == tag2)
        #expect(tag1.name == "work")
        #expect(tag1.isActive == true)
    }

    @Test("Tag retired status")
    func tagRetiredStatus() {
        let activeTag = Tag(
            tagId: 1,
            name: "work",
            createdTsUs: 1_000_000,
            retiredTsUs: nil
        )
        let retiredTag = Tag(
            tagId: 2,
            name: "old-project",
            createdTsUs: 1_000_000,
            retiredTsUs: 2_000_000
        )

        #expect(activeTag.isActive == true)
        #expect(retiredTag.isActive == false)
    }
}

// MARK: - Enum Tests

@Suite("SystemStateEventKind Tests")
struct SystemStateEventKindTests {
    @Test("All event kinds have correct raw values")
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
}

@Suite("EventSource Tests")
struct EventSourceTests {
    @Test("All event sources have correct raw values")
    func eventSourceRawValues() {
        #expect(EventSource.startupProbe.rawValue == "startup_probe")
        #expect(EventSource.workspaceNotification.rawValue == "workspace_notification")
        #expect(EventSource.timerPoll.rawValue == "timer_poll")
        #expect(EventSource.iokitPower.rawValue == "iokit_power")
        #expect(EventSource.shutdownHook.rawValue == "shutdown_hook")
        #expect(EventSource.manual.rawValue == "manual")
    }
}

@Suite("TitleStatus Tests CoreModel")
struct TitleStatusCoreModelTests {
    @Test("All title statuses have correct raw values")
    func titleStatusRawValues() {
        #expect(TitleStatus.ok.rawValue == "ok")
        #expect(TitleStatus.noPermission.rawValue == "no_permission")
        #expect(TitleStatus.notSupported.rawValue == "not_supported")
        #expect(TitleStatus.noWindow.rawValue == "no_window")
        #expect(TitleStatus.error.rawValue == "error")
    }
}

@Suite("ActivityEventReason Tests CoreModel")
struct ActivityEventReasonCoreModelTests {
    @Test("All activity reasons have correct raw values")
    func activityReasonRawValues() {
        #expect(ActivityEventReason.workingBegan.rawValue == "working_began")
        #expect(ActivityEventReason.appActivated.rawValue == "app_activated")
        #expect(ActivityEventReason.axTitleChanged.rawValue == "ax_title_changed")
        #expect(ActivityEventReason.axFocusedWindowChanged.rawValue == "ax_focused_window_changed")
        #expect(ActivityEventReason.pollFallback.rawValue == "poll_fallback")
    }
}

@Suite("EditOperation Tests")
struct EditOperationTests {
    @Test("All edit operations have correct raw values")
    func editOperationRawValues() {
        #expect(EditOperation.deleteRange.rawValue == "delete_range")
        #expect(EditOperation.addRange.rawValue == "add_range")
        #expect(EditOperation.tagRange.rawValue == "tag_range")
        #expect(EditOperation.untagRange.rawValue == "untag_range")
        #expect(EditOperation.undoEdit.rawValue == "undo_edit")
    }
}

