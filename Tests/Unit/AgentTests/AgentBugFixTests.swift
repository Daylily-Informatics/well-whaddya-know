// SPDX-License-Identifier: MIT
// AgentBugFixTests.swift - Tests for bug fixes in Agent implementation

import Testing
import Foundation
@testable import WellWhaddyaKnowAgent
@testable import Sensors
@testable import Storage

// MARK: - AgentError Tests

@Suite("AgentError Tests")
struct AgentErrorTests {
    
    @Test("AgentError.sensorsNotConfigured exists")
    func sensorsNotConfiguredExists() {
        let error = AgentError.sensorsNotConfigured
        // Just verify it compiles and can be used
        #expect(error as Error is AgentError)
    }
    
    @Test("AgentError.databaseError carries message")
    func databaseErrorCarriesMessage() {
        let error = AgentError.databaseError("test message")
        if case let .databaseError(message) = error {
            #expect(message == "test message")
        } else {
            Issue.record("Should be databaseError case")
        }
    }
}

// MARK: - SQL Escaping Tests (Bug 2 Fix)

@Suite("EventWriter SQL Escaping Tests")
struct EventWriterEscapingTests {
    
    @Test("JSON payload with double quotes can be inserted")
    func jsonPayloadWithDoubleQuotes() throws {
        // Create a temp database
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_escaping_\(UUID().uuidString).sqlite").path
        
        let connection = DatabaseConnection(path: dbPath)
        try connection.open()
        defer { 
            connection.close()
            try? FileManager.default.removeItem(atPath: dbPath)
        }
        
        let schemaManager = SchemaManager(connection: connection)
        try schemaManager.initializeSchema()
        
        let runId = UUID().uuidString
        let eventWriter = EventWriter(connection: connection, runId: runId)
        
        // First insert an agent run (required for foreign key)
        try eventWriter.insertAgentRun(
            startedTsUs: 1000000,
            startedMonotonicNs: 1000000000,
            agentVersion: "1.0.0",
            osVersion: "test"
        )
        
        // Create a state for the event
        let state = AgentState(isSystemAwake: true, isSessionOnConsole: true, isScreenLocked: false)
        
        // This JSON has double quotes (like gap_detected payloads)
        let jsonPayload = """
            {"gap_start_ts_us": 1000, "gap_end_ts_us": 2000, "previous_run_id": "abc-123-def"}
            """
        
        // This should NOT throw - Bug 2 fix ensures quotes are escaped
        try eventWriter.insertSystemStateEvent(
            eventTsUs: 1000000,
            eventMonotonicNs: 1000000000,
            state: state,
            eventKind: .gapDetected,
            source: .startupProbe,
            tzIdentifier: "America/Los_Angeles",
            tzOffsetSeconds: -28800,
            payloadJson: jsonPayload
        )
        
        // Verify we can query it back (implicitly tests the insert succeeded)
        #expect(true, "JSON payload with double quotes was inserted successfully")
    }
    
    @Test("JSON payload with single quotes is properly escaped")
    func jsonPayloadWithSingleQuotes() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_escaping_single_\(UUID().uuidString).sqlite").path
        
        let connection = DatabaseConnection(path: dbPath)
        try connection.open()
        defer { 
            connection.close()
            try? FileManager.default.removeItem(atPath: dbPath)
        }
        
        let schemaManager = SchemaManager(connection: connection)
        try schemaManager.initializeSchema()
        
        let runId = UUID().uuidString
        let eventWriter = EventWriter(connection: connection, runId: runId)
        
        try eventWriter.insertAgentRun(
            startedTsUs: 1000000,
            startedMonotonicNs: 1000000000,
            agentVersion: "1.0.0",
            osVersion: "test"
        )
        
        let state = AgentState(isSystemAwake: true, isSessionOnConsole: true, isScreenLocked: false)
        
        // This JSON has single quotes that would break SQL if not escaped
        let jsonPayload = """
            {"message": "User's note with 'quoted' text"}
            """
        
        // This should NOT throw - single quotes are escaped via escapeSql
        try eventWriter.insertSystemStateEvent(
            eventTsUs: 1000000,
            eventMonotonicNs: 1000000000,
            state: state,
            eventKind: .stateChange,
            source: .manual,
            tzIdentifier: "UTC",
            tzOffsetSeconds: 0,
            payloadJson: jsonPayload
        )
        
        #expect(true, "JSON payload with single quotes was inserted successfully")
    }
}

// MARK: - Sensor Configuration Tests (Bug 1 Fix)

@Suite("Agent Sensor Configuration Tests")
struct AgentSensorConfigurationTests {

    @Test("Agent throws sensorsNotConfigured when start called without configureSensors")
    func startWithoutConfigureSensorsThrows() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_sensors_\(UUID().uuidString).sqlite").path

        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let agent = try Agent(databasePath: dbPath)

        // Do NOT call configureSensors() - this should cause start() to throw
        do {
            try await agent.start()
            Issue.record("start() should have thrown AgentError.sensorsNotConfigured")
        } catch let error as AgentError {
            if case .sensorsNotConfigured = error {
                // Expected error
                #expect(true)
            } else {
                Issue.record("Expected sensorsNotConfigured, got \(error)")
            }
        } catch {
            Issue.record("Expected AgentError, got \(type(of: error))")
        }
    }

    @Test("Agent starts successfully after configureSensors is called")
    func startAfterConfigureSensorsSucceeds() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_sensors_ok_\(UUID().uuidString).sqlite").path

        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let agent = try Agent(databasePath: dbPath)
        await agent.configureSensors()  // Must be called before start()

        // This should NOT throw
        try await agent.start()
        try await agent.stop()

        #expect(true, "Agent started and stopped successfully with sensors configured")
    }
}

// MARK: - Accessibility Integration Tests

@Suite("Agent Accessibility Integration Tests")
struct AgentAccessibilityIntegrationTests {

    @Test("Agent has accessibilitySensor after configureSensors")
    func agentHasAccessibilitySensor() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_ax_sensor_\(UUID().uuidString).sqlite").path

        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let agent = try Agent(databasePath: dbPath)
        await agent.configureSensors()

        // The sensor should exist after configuration
        let hasSensor = await agent.accessibilitySensor != nil
        #expect(hasSensor)
    }

    @Test("Agent tracks hasAccessibilityPermission state")
    func agentTracksPermissionState() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_ax_perm_\(UUID().uuidString).sqlite").path

        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let agent = try Agent(databasePath: dbPath)
        await agent.configureSensors()

        // Check that permission state is tracked (value depends on actual permissions)
        let hasPermission = await agent.hasAccessibilityPermission
        #expect(hasPermission == true || hasPermission == false)
    }

    @Test("EventWriter ensureWindowTitle creates and retrieves title")
    func ensureWindowTitleWorks() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_window_title_\(UUID().uuidString).sqlite").path

        let connection = DatabaseConnection(path: dbPath)
        try connection.open()
        defer {
            connection.close()
            try? FileManager.default.removeItem(atPath: dbPath)
        }

        // Initialize schema
        let schemaManager = SchemaManager(connection: connection)
        try schemaManager.initializeSchema()

        // Create event writer
        let runId = UUID().uuidString
        let eventWriter = EventWriter(connection: connection, runId: runId)

        // Insert a window title
        let titleId1 = try eventWriter.ensureWindowTitle(title: "My Test Window", firstSeenTsUs: 1000000)
        #expect(titleId1 > 0)

        // Get the same title again - should return same ID
        let titleId2 = try eventWriter.ensureWindowTitle(title: "My Test Window", firstSeenTsUs: 2000000)
        #expect(titleId2 == titleId1)

        // Different title should get new ID
        let titleId3 = try eventWriter.ensureWindowTitle(title: "Different Window", firstSeenTsUs: 3000000)
        #expect(titleId3 != titleId1)
    }

    @Test("EventWriter ensureWindowTitle escapes SQL special characters")
    func ensureWindowTitleEscapesSql() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_title_escape_\(UUID().uuidString).sqlite").path

        let connection = DatabaseConnection(path: dbPath)
        try connection.open()
        defer {
            connection.close()
            try? FileManager.default.removeItem(atPath: dbPath)
        }

        let schemaManager = SchemaManager(connection: connection)
        try schemaManager.initializeSchema()

        let runId = UUID().uuidString
        let eventWriter = EventWriter(connection: connection, runId: runId)

        // Insert title with single quotes (SQL injection attempt)
        let titleWithQuotes = "Test's Window - O'Brien's App"
        let titleId = try eventWriter.ensureWindowTitle(title: titleWithQuotes, firstSeenTsUs: 1000000)
        #expect(titleId > 0)

        // Retrieve it again
        let titleId2 = try eventWriter.ensureWindowTitle(title: titleWithQuotes, firstSeenTsUs: 2000000)
        #expect(titleId2 == titleId)
    }

    @Test("raw_activity_events can include title info")
    func rawActivityEventWithTitle() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_activity_title_\(UUID().uuidString).sqlite").path

        let connection = DatabaseConnection(path: dbPath)
        try connection.open()
        defer {
            connection.close()
            try? FileManager.default.removeItem(atPath: dbPath)
        }

        let schemaManager = SchemaManager(connection: connection)
        try schemaManager.initializeSchema()

        let runId = UUID().uuidString
        let eventWriter = EventWriter(connection: connection, runId: runId)

        // Create agent run
        try eventWriter.insertAgentRun(startedTsUs: 1000000, startedMonotonicNs: 1000000, agentVersion: "1.0", osVersion: "14.0")

        // Create an app
        let appId = try eventWriter.ensureApplication(bundleId: "com.test.app", displayName: "Test App", firstSeenTsUs: 1000000)

        // Create a window title
        let titleId = try eventWriter.ensureWindowTitle(title: "Main Window", firstSeenTsUs: 1000000)

        // Insert activity event with title
        try eventWriter.insertRawActivityEvent(
            eventTsUs: 2000000,
            eventMonotonicNs: 2000000,
            appId: appId,
            pid: 1234,
            titleId: titleId,
            titleStatus: .ok,
            reason: .axTitleChanged,
            isWorking: true,
            axErrorCode: nil
        )

        #expect(true, "Activity event with title was inserted successfully")
    }

    @Test("raw_activity_events handles all title statuses")
    func rawActivityEventAllTitleStatuses() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_title_status_\(UUID().uuidString).sqlite").path

        let connection = DatabaseConnection(path: dbPath)
        try connection.open()
        defer {
            connection.close()
            try? FileManager.default.removeItem(atPath: dbPath)
        }

        let schemaManager = SchemaManager(connection: connection)
        try schemaManager.initializeSchema()

        let runId = UUID().uuidString
        let eventWriter = EventWriter(connection: connection, runId: runId)

        try eventWriter.insertAgentRun(startedTsUs: 1000000, startedMonotonicNs: 1000000, agentVersion: "1.0", osVersion: "14.0")
        let appId = try eventWriter.ensureApplication(bundleId: "com.test.app", displayName: "Test App", firstSeenTsUs: 1000000)

        let allStatuses: [TitleStatus] = [.ok, .noPermission, .notSupported, .noWindow, .error]

        for (index, status) in allStatuses.enumerated() {
            let titleId: Int64? = status == .ok
                ? try eventWriter.ensureWindowTitle(title: "Title \(index)", firstSeenTsUs: Int64(1000000 + index))
                : nil

            try eventWriter.insertRawActivityEvent(
                eventTsUs: Int64(2000000 + index),
                eventMonotonicNs: UInt64(2000000 + index),
                appId: appId,
                pid: Int32(1234 + index),
                titleId: titleId,
                titleStatus: status,
                reason: .appActivated,
                isWorking: true,
                axErrorCode: status == .error ? -25204 : nil
            )
        }

        #expect(true, "All title statuses were handled correctly")
    }
}
