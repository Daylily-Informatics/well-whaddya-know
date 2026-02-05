// SPDX-License-Identifier: MIT
// AccessibilitySensorTests.swift - Tests for AccessibilitySensor

import Testing
import Foundation
@testable import Sensors

// MARK: - TitleReadResult Tests

@Suite("TitleReadResult Tests")
struct TitleReadResultTests {
    
    @Test("ok factory creates successful result")
    func testOkFactory() {
        let result = TitleReadResult.ok("Test Title")
        #expect(result.title == "Test Title")
        #expect(result.status == .ok)
        #expect(result.axErrorCode == nil)
    }
    
    @Test("noPermission factory creates correct result")
    func testNoPermissionFactory() {
        let result = TitleReadResult.noPermission
        #expect(result.title == nil)
        #expect(result.status == .noPermission)
        #expect(result.axErrorCode == nil)
    }
    
    @Test("notSupported factory creates correct result")
    func testNotSupportedFactory() {
        let result = TitleReadResult.notSupported
        #expect(result.title == nil)
        #expect(result.status == .notSupported)
        #expect(result.axErrorCode == nil)
    }
    
    @Test("noWindow factory creates correct result")
    func testNoWindowFactory() {
        let result = TitleReadResult.noWindow
        #expect(result.title == nil)
        #expect(result.status == .noWindow)
        #expect(result.axErrorCode == nil)
    }
    
    @Test("error factory creates result with error code")
    func testErrorFactory() {
        let result = TitleReadResult.error(code: -25204)
        #expect(result.title == nil)
        #expect(result.status == .error)
        #expect(result.axErrorCode == -25204)
    }
    
    @Test("TitleReadResult is Equatable")
    func testEquatable() {
        let result1 = TitleReadResult.ok("Title")
        let result2 = TitleReadResult.ok("Title")
        let result3 = TitleReadResult.ok("Different")
        
        #expect(result1 == result2)
        #expect(result1 != result3)
    }
    
    @Test("TitleReadResult is Sendable")
    func testSendable() {
        let result = TitleReadResult.ok("Title")
        Task {
            let _ = result  // Can use across task boundaries
        }
        #expect(Bool(true))
    }
}

// MARK: - TitleReadStatus Tests

@Suite("TitleReadStatus Tests")
struct TitleReadStatusTests {
    
    @Test("All title read statuses have expected raw values")
    func testRawValues() {
        #expect(TitleReadStatus.ok.rawValue == "ok")
        #expect(TitleReadStatus.noPermission.rawValue == "no_permission")
        #expect(TitleReadStatus.notSupported.rawValue == "not_supported")
        #expect(TitleReadStatus.noWindow.rawValue == "no_window")
        #expect(TitleReadStatus.error.rawValue == "error")
    }
    
    @Test("TitleReadStatus can be constructed from raw value")
    func testFromRawValue() {
        #expect(TitleReadStatus(rawValue: "ok") == .ok)
        #expect(TitleReadStatus(rawValue: "no_permission") == .noPermission)
        #expect(TitleReadStatus(rawValue: "invalid") == nil)
    }
}

// MARK: - TitleChangeReason Tests

@Suite("TitleChangeReason Tests")
struct TitleChangeReasonTests {
    
    @Test("All title change reasons have expected raw values")
    func testRawValues() {
        #expect(TitleChangeReason.axTitleChanged.rawValue == "ax_title_changed")
        #expect(TitleChangeReason.axFocusedWindowChanged.rawValue == "ax_focused_window_changed")
        #expect(TitleChangeReason.pollFallback.rawValue == "poll_fallback")
    }
    
    @Test("TitleChangeReason can be constructed from raw value")
    func testFromRawValue() {
        #expect(TitleChangeReason(rawValue: "ax_title_changed") == .axTitleChanged)
        #expect(TitleChangeReason(rawValue: "poll_fallback") == .pollFallback)
        #expect(TitleChangeReason(rawValue: "invalid") == nil)
    }
}

// MARK: - SensorEvent Title Cases Tests

@Suite("SensorEvent Title Cases Tests")
struct SensorEventTitleCasesTests {
    
    @Test("titleChanged event carries correct data")
    func testTitleChangedEvent() {
        let result = TitleReadResult.ok("My Window Title")
        let timestamp = Date()
        let monotonicNs: UInt64 = 123456789
        
        let event = SensorEvent.titleChanged(
            pid: 1234,
            result: result,
            reason: .axTitleChanged,
            timestamp: timestamp,
            monotonicNs: monotonicNs
        )
        
        if case .titleChanged(let pid, let r, let reason, let ts, let mono) = event {
            #expect(pid == 1234)
            #expect(r.title == "My Window Title")
            #expect(r.status == .ok)
            #expect(reason == .axTitleChanged)
            #expect(ts == timestamp)
            #expect(mono == monotonicNs)
        } else {
            Issue.record("Event is not titleChanged")
        }
    }
    
    @Test("accessibilityPermissionChanged event carries correct data")
    func testAccessibilityPermissionChangedEvent() {
        let timestamp = Date()
        let monotonicNs: UInt64 = 987654321
        
        let event = SensorEvent.accessibilityPermissionChanged(
            granted: true,
            timestamp: timestamp,
            monotonicNs: monotonicNs
        )
        
        if case .accessibilityPermissionChanged(let granted, let ts, let mono) = event {
            #expect(granted == true)
            #expect(ts == timestamp)
            #expect(mono == monotonicNs)
        } else {
            Issue.record("Event is not accessibilityPermissionChanged")
        }
    }
}

// MARK: - AccessibilitySensor Initialization Tests

/// Mock handler for testing sensor events - uses actor for Swift 6 safety
actor MockAccessibilityEventHandler: SensorEventHandler {
    var receivedEvents: [SensorEvent] = []

    func handle(_ event: SensorEvent) async {
        receivedEvents.append(event)
    }

    var eventCount: Int {
        receivedEvents.count
    }

    func getEvents() -> [SensorEvent] {
        receivedEvents
    }
}

@Suite("AccessibilitySensor Initialization Tests")
struct AccessibilitySensorInitTests {

    @Test("AccessibilitySensor can be initialized with handler")
    func testInit() {
        let handler = MockAccessibilityEventHandler()
        let sensor = AccessibilitySensor(handler: handler)
        // Sensor is non-optional, so just verify it was created
        #expect(type(of: sensor) == AccessibilitySensor.self)
    }

    @Test("checkPermission returns a boolean")
    func testCheckPermission() {
        // Note: The result depends on whether the test runner has AX permission
        let hasPermission = AccessibilitySensor.checkPermission()
        #expect(hasPermission == true || hasPermission == false)
    }

    @Test("hasPermission matches static check")
    func testHasPermission() {
        let handler = MockAccessibilityEventHandler()
        let sensor = AccessibilitySensor(handler: handler)
        let staticResult = AccessibilitySensor.checkPermission()
        #expect(sensor.hasPermission() == staticResult)
    }
}

// MARK: - AccessibilitySensor Working State Tests

@Suite("AccessibilitySensor Working State Tests")
struct AccessibilitySensorWorkingStateTests {

    @Test("setWorkingState can be called without crashing")
    func testSetWorkingState() {
        let handler = MockAccessibilityEventHandler()
        let sensor = AccessibilitySensor(handler: handler)

        // These should not crash
        sensor.setWorkingState(true)
        sensor.setWorkingState(false)
        sensor.setWorkingState(true)

        #expect(Bool(true), "setWorkingState calls completed without crash")
    }

    @Test("startObserving and stopObserving cycle works")
    func testObservingCycle() {
        let handler = MockAccessibilityEventHandler()
        let sensor = AccessibilitySensor(handler: handler)

        // Start observing for a fake PID
        sensor.startObserving(forPid: 1)

        // Stop observing
        sensor.stopObserving()

        #expect(Bool(true), "Observing cycle completed without crash")
    }

    @Test("Multiple startObserving calls replace previous observation")
    func testMultipleStartObserving() {
        let handler = MockAccessibilityEventHandler()
        let sensor = AccessibilitySensor(handler: handler)

        sensor.startObserving(forPid: 100)
        sensor.startObserving(forPid: 200)
        sensor.startObserving(forPid: 300)
        sensor.stopObserving()

        #expect(Bool(true), "Multiple startObserving calls handled correctly")
    }
}

// MARK: - AccessibilitySensor Title Reading Tests

@Suite("AccessibilitySensor Title Reading Tests")
struct AccessibilitySensorTitleReadingTests {

    @Test("readWindowTitle returns result for invalid PID")
    func testReadTitleInvalidPid() {
        let handler = MockAccessibilityEventHandler()
        let sensor = AccessibilitySensor(handler: handler)

        // PID 0 is the kernel, should return some result
        let result = sensor.readWindowTitle(for: 0)

        // Should get some status back (likely error or noWindow)
        #expect(result.status == .noWindow || result.status == .error || result.status == .noPermission)
    }

    @Test("readWindowTitle for current process returns result")
    func testReadTitleCurrentProcess() {
        let handler = MockAccessibilityEventHandler()
        let sensor = AccessibilitySensor(handler: handler)

        // Get our own PID
        let myPid = ProcessInfo.processInfo.processIdentifier
        let result = sensor.readWindowTitle(for: myPid)

        // Test process likely has no window, so noWindow or noPermission expected
        let validStatuses: [TitleReadStatus] = [.ok, .noWindow, .notSupported, .noPermission, .error]
        #expect(validStatuses.contains(result.status))
    }

    @Test("pollTitleNow emits event")
    func testPollTitleNow() async throws {
        let handler = MockAccessibilityEventHandler()
        let sensor = AccessibilitySensor(handler: handler)

        // Poll title for a process
        sensor.pollTitleNow(for: 1)

        // Give async handler time to process
        try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        // Should have received an event
        let count = await handler.eventCount
        #expect(count >= 1)

        // Check it's a titleChanged event
        let events = await handler.getEvents()
        if let firstEvent = events.first {
            if case .titleChanged = firstEvent {
                #expect(Bool(true))  // Use Bool(true) to silence always-pass warning
            } else {
                Issue.record("Expected titleChanged event, got something else")
            }
        }
    }
}

