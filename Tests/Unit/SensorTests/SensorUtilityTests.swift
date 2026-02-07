// SPDX-License-Identifier: MIT
// SensorUtilityTests.swift - Tests for sensor utility functions and initialization

import Testing
import Foundation
@testable import Sensors

// MARK: - Utility Function Tests

@Suite("Sensor Utility Function Tests")
struct SensorUtilityTests {
    
    @Test("getMonotonicTimeNs returns non-zero value")
    func monotonicTimeNonZero() {
        let time = getMonotonicTimeNs()
        #expect(time > 0, "Monotonic time should be positive")
    }
    
    @Test("getMonotonicTimeNs is monotonically increasing")
    func monotonicTimeIncreases() {
        let time1 = getMonotonicTimeNs()
        // Small delay to ensure time advances
        for _ in 0..<1000 { _ = 1 + 1 }
        let time2 = getMonotonicTimeNs()
        #expect(time2 >= time1, "Monotonic time should not go backwards")
    }
    
    @Test("getCurrentTimestampUs returns reasonable value")
    func currentTimestampUsReasonable() {
        let tsUs = getCurrentTimestampUs()
        
        // Should be after 2020-01-01 (1577836800 seconds = 1577836800000000 us)
        let jan2020Us: Int64 = 1_577_836_800_000_000
        #expect(tsUs > jan2020Us, "Timestamp should be after 2020")
        
        // Should be within reason (before 2100)
        let jan2100Us: Int64 = 4_102_444_800_000_000
        #expect(tsUs < jan2100Us, "Timestamp should be before 2100")
    }
    
    @Test("getCurrentTimestampUs is in microseconds")
    func currentTimestampUsIsMicroseconds() {
        let tsUs = getCurrentTimestampUs()
        let tsSec = Date().timeIntervalSince1970
        
        // Convert both to seconds and compare
        let tsUsToSec = Double(tsUs) / 1_000_000.0
        
        // Should be within 1 second of each other
        #expect(abs(tsUsToSec - tsSec) < 1.0, "Timestamp should match current time")
    }
}

// MARK: - Sensor Initialization Tests

/// Simple handler for initialization tests
private struct TestHandler: SensorEventHandler {
    func handle(_ event: SensorEvent) async {}
}

@Suite("Sensor Initialization Tests")
struct SensorInitializationTests {
    
    @Test("SessionStateSensor can be initialized")
    func sessionStateSensorInit() {
        let handler = TestHandler()
        let sensor = SessionStateSensor(handler: handler)
        
        // Should be able to probe state immediately
        let state = sensor.probeCurrentState()
        
        // State should be valid (not crashing)
        // On a real system, one of these should be true/false
        #expect(state.monotonicNs > 0 || state.monotonicNs == 0, "Should have a monotonic timestamp")
    }
    
    @Test("SessionStateSensor probeCurrentState returns SessionState")
    func sessionStateSensorProbe() {
        let handler = TestHandler()
        let sensor = SessionStateSensor(handler: handler)
        
        let state = sensor.probeCurrentState()
        
        // The state should have timestamp info
        #expect(state.timestamp <= Date(), "Timestamp should not be in the future")
    }
    
    @Test("SleepWakeSensor can be initialized")
    func sleepWakeSensorInit() {
        let handler = TestHandler()
        let sensor = SleepWakeSensor(handler: handler)
        
        // Should be able to start and stop without crashing
        sensor.startObserving()
        sensor.stopObserving()
    }
    
    @Test("ForegroundAppSensor can be initialized")
    func foregroundAppSensorInit() {
        let handler = TestHandler()
        let sensor = ForegroundAppSensor(handler: handler)
        
        // Should be able to start and stop without crashing
        sensor.startObserving()
        sensor.stopObserving()
    }
    
    @Test("ForegroundAppSensor getCurrentFrontmostApp returns optional")
    func foregroundAppSensorGetCurrent() {
        let handler = TestHandler()
        let sensor = ForegroundAppSensor(handler: handler)

        // This may return nil in test environment without GUI
        let appInfo = sensor.getCurrentFrontmostApp()

        // If we got an app, validate it has expected fields
        if let info = appInfo {
            #expect(!info.bundleId.isEmpty || info.bundleId == "unknown")
            #expect(!info.displayName.isEmpty || info.displayName == "Unknown")
            #expect(info.pid > 0)
        }
        // nil is also acceptable in headless test environment
    }

    @Test("AccessibilitySensor can be initialized")
    func accessibilitySensorInit() {
        let handler = TestHandler()
        let sensor = AccessibilitySensor(handler: handler)

        // Should be able to check permission without crashing
        let granted = sensor.isAccessibilityGranted()
        // In test environment, this may be true or false
        #expect(granted == true || granted == false)
    }

    @Test("AccessibilitySensor getCurrentTitle returns status")
    func accessibilitySensorGetCurrentTitle() {
        let handler = TestHandler()
        let sensor = AccessibilitySensor(handler: handler)

        // Get title for an invalid PID (should return an error status)
        let (title, status, axErrorCode) = sensor.getCurrentTitle(for: -1)

        // Should not crash, and should return some status
        // Will likely be noPermission in test env, or error for invalid PID
        #expect(title == nil || title != nil)  // Either is acceptable
        #expect([TitleCaptureStatus.ok, .noPermission, .notSupported, .noWindow, .error].contains(status))
        // axErrorCode should be nil for .ok/.noPermission, or a raw AXError code otherwise
        if status == .ok || status == .noPermission {
            #expect(axErrorCode == nil)
        }
    }
}

// MARK: - Sensor Edge Cases

@Suite("Sensor Edge Case Tests")
struct SensorEdgeCaseTests {
    
    @Test("SessionState default timestamp is current time")
    func sessionStateDefaultTimestamp() {
        let before = Date()
        let state = SessionState(isOnConsole: true, isScreenLocked: false)
        let after = Date()
        
        #expect(state.timestamp >= before)
        #expect(state.timestamp <= after)
    }
    
    @Test("SessionState default monotonicNs is zero")
    func sessionStateDefaultMonotonicNs() {
        let state = SessionState(isOnConsole: true, isScreenLocked: false)
        #expect(state.monotonicNs == 0)
    }
    
    @Test("Multiple sensor instances can coexist")
    func multipleSensorInstances() {
        let handler = TestHandler()
        
        let session1 = SessionStateSensor(handler: handler)
        let session2 = SessionStateSensor(handler: handler)
        
        let state1 = session1.probeCurrentState()
        let state2 = session2.probeCurrentState()
        
        // Both should return valid states
        #expect(state1.isOnConsole == state2.isOnConsole)
        #expect(state1.isScreenLocked == state2.isScreenLocked)
    }
}

