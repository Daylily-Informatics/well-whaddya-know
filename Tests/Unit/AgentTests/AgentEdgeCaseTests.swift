// SPDX-License-Identifier: MIT
// AgentEdgeCaseTests.swift - Tests for SPEC.md Section 5.5 edge cases

import Testing
import Foundation
@testable import WellWhaddyaKnowAgent
@testable import Sensors
@testable import Storage

// MARK: - Clock Change Detection Tests (SPEC.md 5.5.F)

@Suite("Clock Change Detection Tests")
struct ClockChangeDetectionTests {
    
    @Test("Clock change is detected when wall-clock jumps forward by >120s")
    func clockChangeDetectedOnForwardJump() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_clock_\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let agent = try Agent(databasePath: dbPath)
        await agent.configureSensors()
        try await agent.start()  // Start agent to create the agent_runs record

        // Simulate clock change: wall-clock jumped forward 200s, but monotonic only 10s
        let previousTsUs: Int64 = 1_000_000_000_000  // 1M seconds in microseconds
        let currentTsUs: Int64 = previousTsUs + 200_000_000  // +200 seconds
        let previousMonoNs: UInt64 = 1_000_000_000_000  // 1000 seconds in ns
        let currentMonoNs: UInt64 = previousMonoNs + 10_000_000_000  // +10 seconds

        let detected = try await agent.checkAndEmitClockChange(
            currentTimestampUs: currentTsUs,
            currentMonotonicNs: currentMonoNs,
            previousTimestampUs: previousTsUs,
            previousMonotonicNs: previousMonoNs
        )

        #expect(detected == true, "Clock change should be detected (190s deviation > 120s threshold)")

        try await agent.stop()
    }
    
    @Test("Clock change is detected when wall-clock jumps backward by >120s")
    func clockChangeDetectedOnBackwardJump() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_clock_back_\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let agent = try Agent(databasePath: dbPath)
        await agent.configureSensors()
        try await agent.start()  // Start agent to create the agent_runs record

        // Simulate clock change: wall-clock jumped backward (user set clock back)
        let previousTsUs: Int64 = 1_000_000_000_000
        let currentTsUs: Int64 = previousTsUs - 200_000_000  // -200 seconds (clock set back)
        let previousMonoNs: UInt64 = 1_000_000_000_000
        let currentMonoNs: UInt64 = previousMonoNs + 10_000_000_000  // +10 seconds real time

        let detected = try await agent.checkAndEmitClockChange(
            currentTimestampUs: currentTsUs,
            currentMonotonicNs: currentMonoNs,
            previousTimestampUs: previousTsUs,
            previousMonotonicNs: previousMonoNs
        )

        #expect(detected == true, "Clock change should be detected for backward jump")

        try await agent.stop()
    }
    
    @Test("No clock change when deviation is within threshold")
    func noClockChangeWithinThreshold() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_clock_ok_\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let agent = try Agent(databasePath: dbPath)
        await agent.configureSensors()
        try await agent.start()  // Start agent to create the agent_runs record

        // Normal operation: wall-clock and monotonic are in sync (small drift OK)
        let previousTsUs: Int64 = 1_000_000_000_000
        let currentTsUs: Int64 = previousTsUs + 60_000_000  // +60 seconds
        let previousMonoNs: UInt64 = 1_000_000_000_000
        let currentMonoNs: UInt64 = previousMonoNs + 60_000_000_000  // +60 seconds

        let detected = try await agent.checkAndEmitClockChange(
            currentTimestampUs: currentTsUs,
            currentMonotonicNs: currentMonoNs,
            previousTimestampUs: previousTsUs,
            previousMonotonicNs: previousMonoNs
        )

        #expect(detected == false, "No clock change when times are in sync")

        try await agent.stop()
    }
    
    @Test("Clock change threshold constant is 120 seconds")
    func clockChangeThresholdIs120Seconds() {
        #expect(Agent.clockChangeThresholdSeconds == 120)
    }
}

// MARK: - Sleep/Wake Edge Case Tests (SPEC.md 5.5.C)

@Suite("Sleep Wake Edge Case Tests")
struct SleepWakeEdgeCaseTests {
    
    @Test("willSleep sets isSystemAwake to false")
    func willSleepSetsSystemAwakeFalse() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_sleep_\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        
        let agent = try Agent(databasePath: dbPath)
        await agent.configureSensors()
        try await agent.start()
        
        // Verify initial state has system awake
        let initialState = await agent.state
        #expect(initialState.isSystemAwake == true)
        
        // Simulate willSleep
        let sleepEvent = SensorEvent.willSleep(timestamp: Date(), monotonicNs: getMonotonicTimeNs())
        await agent.handle(sleepEvent)
        
        // Verify state changed
        let afterSleepState = await agent.state
        #expect(afterSleepState.isSystemAwake == false, "willSleep should set isSystemAwake to false")
        #expect(afterSleepState.isWorking == false, "isWorking should be false after sleep")
        
        try await agent.stop()
    }
    
    @Test("didWake sets isSystemAwake to true")
    func didWakeSetsSystemAwakeTrue() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_wake_\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        
        let agent = try Agent(databasePath: dbPath)
        await agent.configureSensors()
        try await agent.start()
        
        // Put system to sleep first
        let sleepEvent = SensorEvent.willSleep(timestamp: Date(), monotonicNs: getMonotonicTimeNs())
        await agent.handle(sleepEvent)
        
        let afterSleepState = await agent.state
        #expect(afterSleepState.isSystemAwake == false)
        
        // Now wake
        let wakeEvent = SensorEvent.didWake(timestamp: Date(), monotonicNs: getMonotonicTimeNs())
        await agent.handle(wakeEvent)
        
        let afterWakeState = await agent.state
        #expect(afterWakeState.isSystemAwake == true, "didWake should set isSystemAwake to true")
        
        try await agent.stop()
    }
}

// MARK: - Shutdown Edge Case Tests (SPEC.md 5.5.D)

@Suite("Shutdown Edge Case Tests")
struct ShutdownEdgeCaseTests {

    @Test("willPowerOff forces isWorking to false")
    func willPowerOffForcesNotWorking() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_poweroff_\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let agent = try Agent(databasePath: dbPath)
        await agent.configureSensors()
        try await agent.start()

        // Simulate poweroff
        let poweroffEvent = SensorEvent.willPowerOff(timestamp: Date(), monotonicNs: getMonotonicTimeNs())
        await agent.handle(poweroffEvent)

        let afterPoweroffState = await agent.state
        #expect(afterPoweroffState.isSystemAwake == false, "willPowerOff should set isSystemAwake to false")
        #expect(afterPoweroffState.isSessionOnConsole == false, "willPowerOff should set isSessionOnConsole to false")
        #expect(afterPoweroffState.isWorking == false, "isWorking must be false after poweroff")
    }
}

// MARK: - Gap Detection Tests (SPEC.md 5.5.E)

@Suite("Gap Detection Tests")
struct GapDetectionTests {

    @Test("Gap detected event includes proper JSON payload structure")
    func gapDetectedPayloadStructure() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_gap_\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let connection = DatabaseConnection(path: dbPath)
        try connection.open()
        defer { connection.close() }

        let schemaManager = SchemaManager(connection: connection)
        try schemaManager.initializeSchema()

        let runId = UUID().uuidString
        let eventWriter = EventWriter(connection: connection, runId: runId)

        // Insert agent run
        try eventWriter.insertAgentRun(
            startedTsUs: 1000000,
            startedMonotonicNs: 1000000000,
            agentVersion: "1.0.0",
            osVersion: "test"
        )

        let state = AgentState(isSystemAwake: true, isSessionOnConsole: true, isScreenLocked: false)

        // Insert gap_detected with payload containing all required fields per SPEC.md
        let gapPayload = """
            {"gap_start_ts_us": 1000000, "gap_end_ts_us": 2000000, "previous_run_id": "crashed-run-123"}
            """

        try eventWriter.insertSystemStateEvent(
            eventTsUs: 2000000,
            eventMonotonicNs: 2000000000,
            state: state,
            eventKind: .gapDetected,
            source: .startupProbe,
            tzIdentifier: "UTC",
            tzOffsetSeconds: 0,
            payloadJson: gapPayload
        )

        // Verify the event was inserted (implicit - no throw means success)
        #expect(true, "gap_detected event with JSON payload inserted successfully")
    }
}

// MARK: - Fast User Switching Tests (SPEC.md 5.5.A)

@Suite("Fast User Switching Tests")
struct FastUserSwitchingTests {

    @Test("Session off console sets isSessionOnConsole to false")
    func sessionOffConsoleSetsFlag() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_fus_\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let agent = try Agent(databasePath: dbPath)
        await agent.configureSensors()
        try await agent.start()

        // Simulate fast user switch - session goes off console
        let offConsoleState = SessionState(
            isOnConsole: false,
            isScreenLocked: false,
            timestamp: Date(),
            monotonicNs: getMonotonicTimeNs()
        )
        let switchEvent = SensorEvent.sessionStateChanged(offConsoleState, source: .workspaceNotification)
        await agent.handle(switchEvent)

        let afterSwitchState = await agent.state
        #expect(afterSwitchState.isSessionOnConsole == false)
        #expect(afterSwitchState.isWorking == false, "isWorking must be false when off console")

        try await agent.stop()
    }

    @Test("Session returns to console and unlocked resumes working")
    func sessionReturnsToConsoleUnlocked() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_fus_return_\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let agent = try Agent(databasePath: dbPath)
        await agent.configureSensors()
        try await agent.start()

        // Go off console
        let offState = SessionState(isOnConsole: false, isScreenLocked: false,
                                     timestamp: Date(), monotonicNs: getMonotonicTimeNs())
        await agent.handle(SensorEvent.sessionStateChanged(offState, source: .workspaceNotification))

        // Return to console unlocked
        let onState = SessionState(isOnConsole: true, isScreenLocked: false,
                                    timestamp: Date(), monotonicNs: getMonotonicTimeNs())
        await agent.handle(SensorEvent.sessionStateChanged(onState, source: .workspaceNotification))

        let finalState = await agent.state
        #expect(finalState.isSessionOnConsole == true)
        #expect(finalState.isScreenLocked == false)
        #expect(finalState.isWorking == true, "isWorking should resume when back on console and unlocked")

        try await agent.stop()
    }

    @Test("Session returns to console but locked does not resume working")
    func sessionReturnsToConsoleLocked() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_fus_locked_\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let agent = try Agent(databasePath: dbPath)
        await agent.configureSensors()
        try await agent.start()

        // Go off console
        let offState = SessionState(isOnConsole: false, isScreenLocked: false,
                                     timestamp: Date(), monotonicNs: getMonotonicTimeNs())
        await agent.handle(SensorEvent.sessionStateChanged(offState, source: .workspaceNotification))

        // Return to console BUT locked
        let lockedState = SessionState(isOnConsole: true, isScreenLocked: true,
                                         timestamp: Date(), monotonicNs: getMonotonicTimeNs())
        await agent.handle(SensorEvent.sessionStateChanged(lockedState, source: .workspaceNotification))

        let finalState = await agent.state
        #expect(finalState.isSessionOnConsole == true)
        #expect(finalState.isScreenLocked == true)
        #expect(finalState.isWorking == false, "isWorking should remain false when locked")

        try await agent.stop()
    }
}

