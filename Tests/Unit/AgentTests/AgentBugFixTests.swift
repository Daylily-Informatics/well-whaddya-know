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

