// SPDX-License-Identifier: MIT
// SensorTests.swift - Unit tests for the Sensors module

import Testing
import Foundation
@testable import Sensors

// MARK: - Mock Event Handler for Testing

actor MockEventHandler: SensorEventHandler {
    var receivedEvents: [SensorEvent] = []

    nonisolated func handle(_ event: SensorEvent) async {
        await appendEvent(event)
    }

    func appendEvent(_ event: SensorEvent) {
        receivedEvents.append(event)
    }

    func eventCount() -> Int {
        receivedEvents.count
    }
}

/// Dummy handler for sensor initialization tests
struct DummyHandler: SensorEventHandler {
    func handle(_ event: SensorEvent) async {}
}

// MARK: - SensorSource Tests

@Suite("SensorSource Tests")
struct SensorSourceTests {
    
    @Test("SensorSource has expected raw values")
    func sensorSourceRawValues() {
        #expect(SensorSource.startupProbe.rawValue == "startup_probe")
        #expect(SensorSource.workspaceNotification.rawValue == "workspace_notification")
        #expect(SensorSource.timerPoll.rawValue == "timer_poll")
        #expect(SensorSource.iokitPower.rawValue == "iokit_power")
        #expect(SensorSource.shutdownHook.rawValue == "shutdown_hook")
        #expect(SensorSource.manual.rawValue == "manual")
    }
    
    @Test("SensorSource is Sendable")
    func sensorSourceIsSendable() async {
        let source = SensorSource.startupProbe
        let task = Task {
            return source.rawValue
        }
        let result = await task.value
        #expect(result == "startup_probe")
    }
}

// MARK: - SessionState Tests

@Suite("SessionState Tests")
struct SessionStateTests {
    
    @Test("SessionState initialization")
    func sessionStateInit() {
        let timestamp = Date()
        let state = SessionState(
            isOnConsole: true,
            isScreenLocked: false,
            timestamp: timestamp,
            monotonicNs: 12345
        )
        
        #expect(state.isOnConsole == true)
        #expect(state.isScreenLocked == false)
        #expect(state.timestamp == timestamp)
        #expect(state.monotonicNs == 12345)
    }
    
    @Test("SessionState unknown returns conservative defaults")
    func sessionStateUnknown() {
        let unknown = SessionState.unknown
        
        // Per SPEC.md 4.3: unknown should be treated as not working
        #expect(unknown.isOnConsole == false)
        #expect(unknown.isScreenLocked == true)
    }
    
    @Test("SessionState is Equatable")
    func sessionStateEquatable() {
        let timestamp = Date()
        let state1 = SessionState(isOnConsole: true, isScreenLocked: false, timestamp: timestamp, monotonicNs: 100)
        let state2 = SessionState(isOnConsole: true, isScreenLocked: false, timestamp: timestamp, monotonicNs: 100)
        let state3 = SessionState(isOnConsole: false, isScreenLocked: false, timestamp: timestamp, monotonicNs: 100)
        
        #expect(state1 == state2)
        #expect(state1 != state3)
    }
    
    @Test("SessionState is Sendable")
    func sessionStateIsSendable() async {
        let state = SessionState(isOnConsole: true, isScreenLocked: false)
        let task = Task {
            return state.isOnConsole
        }
        let result = await task.value
        #expect(result == true)
    }
}

// MARK: - SensorEvent Tests

@Suite("SensorEvent Tests")
struct SensorEventTests {
    
    @Test("SensorEvent sessionStateChanged carries correct data")
    func sessionStateChangedEvent() {
        let state = SessionState(isOnConsole: true, isScreenLocked: false)
        let event = SensorEvent.sessionStateChanged(state, source: .timerPoll)
        
        if case let .sessionStateChanged(receivedState, source) = event {
            #expect(receivedState.isOnConsole == true)
            #expect(receivedState.isScreenLocked == false)
            #expect(source == .timerPoll)
        } else {
            Issue.record("Event should be sessionStateChanged")
        }
    }
    
    @Test("SensorEvent willSleep carries timestamp")
    func willSleepEvent() {
        let timestamp = Date()
        let event = SensorEvent.willSleep(timestamp: timestamp, monotonicNs: 999)
        
        if case let .willSleep(ts, mono) = event {
            #expect(ts == timestamp)
            #expect(mono == 999)
        } else {
            Issue.record("Event should be willSleep")
        }
    }
    
    @Test("SensorEvent appActivated carries app info")
    func appActivatedEvent() {
        let timestamp = Date()
        let event = SensorEvent.appActivated(
            bundleId: "com.test.app",
            displayName: "Test App",
            pid: 1234,
            timestamp: timestamp,
            monotonicNs: 5678
        )

        if case let .appActivated(bundleId, displayName, pid, ts, mono) = event {
            #expect(bundleId == "com.test.app")
            #expect(displayName == "Test App")
            #expect(pid == 1234)
            #expect(ts == timestamp)
            #expect(mono == 5678)
        } else {
            Issue.record("Event should be appActivated")
        }
    }

    @Test("SensorEvent titleChanged carries title info")
    func titleChangedEvent() {
        let timestamp = Date()
        let event = SensorEvent.titleChanged(
            pid: 1234,
            title: "My Window",
            status: .ok,
            source: .workspaceNotification,
            timestamp: timestamp,
            monotonicNs: 9999
        )

        if case let .titleChanged(pid, title, status, source, ts, mono) = event {
            #expect(pid == 1234)
            #expect(title == "My Window")
            #expect(status == .ok)
            #expect(source == .workspaceNotification)
            #expect(ts == timestamp)
            #expect(mono == 9999)
        } else {
            Issue.record("Event should be titleChanged")
        }
    }

    @Test("SensorEvent accessibilityPermissionChanged carries granted state")
    func accessibilityPermissionChangedEvent() {
        let timestamp = Date()
        let event = SensorEvent.accessibilityPermissionChanged(
            granted: true,
            timestamp: timestamp,
            monotonicNs: 1111
        )

        if case let .accessibilityPermissionChanged(granted, ts, mono) = event {
            #expect(granted == true)
            #expect(ts == timestamp)
            #expect(mono == 1111)
        } else {
            Issue.record("Event should be accessibilityPermissionChanged")
        }
    }
}

// MARK: - TitleCaptureStatus Tests

@Suite("TitleCaptureStatus Tests")
struct TitleCaptureStatusTests {

    @Test("TitleCaptureStatus has expected raw values")
    func titleCaptureStatusRawValues() {
        #expect(TitleCaptureStatus.ok.rawValue == "ok")
        #expect(TitleCaptureStatus.noPermission.rawValue == "no_permission")
        #expect(TitleCaptureStatus.notSupported.rawValue == "not_supported")
        #expect(TitleCaptureStatus.noWindow.rawValue == "no_window")
        #expect(TitleCaptureStatus.error.rawValue == "error")
    }
}

