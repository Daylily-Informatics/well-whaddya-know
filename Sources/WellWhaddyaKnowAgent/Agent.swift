// SPDX-License-Identifier: MIT
// Agent.swift - Main background agent implementation

import Foundation
import Storage
import Sensors

/// The background agent that tracks system state and emits events.
/// Implements the state machine per SPEC.md Sections 4-5.
public actor Agent: SensorEventHandler {
    
    // MARK: - Configuration
    
    public static let agentVersion = "1.0.0"
    
    // MARK: - State (internal for extensions)

    let runId: String
    var state: AgentState
    let eventWriter: EventWriter
    let connection: DatabaseConnection

    // Sensors
    let sessionSensor: SessionStateSensor
    let sleepWakeSensor: SleepWakeSensor
    let foregroundAppSensor: ForegroundAppSensor

    // Track current foreground app for activity events
    var currentAppId: Int64?
    var currentPid: pid_t = 0
    
    // MARK: - Initialization
    
    public init(databasePath: String) throws {
        self.runId = UUID().uuidString
        self.state = .initial
        
        // Open database connection
        self.connection = DatabaseConnection(path: databasePath)
        try connection.open()
        
        // Initialize schema if needed
        let schemaManager = SchemaManager(connection: connection)
        try schemaManager.initializeSchema()
        
        // Create event writer
        self.eventWriter = EventWriter(connection: connection, runId: runId)
        
        // Create sensors (they will call back into this agent)
        // Note: We pass `self` after initialization via configure()
        self.sessionSensor = SessionStateSensor(handler: DummyHandler())
        self.sleepWakeSensor = SleepWakeSensor(handler: DummyHandler())
        self.foregroundAppSensor = ForegroundAppSensor(handler: DummyHandler())
    }
    
    /// Configure sensors with the actual handler (call after actor init)
    public func configureSensors() {
        // In a real implementation, we'd need to create new sensors with self as handler
        // For now, sensors will be configured separately
    }
    
    // MARK: - Lifecycle (SPEC.md Section 5.2)
    
    /// Start the agent - implements startup sequence per SPEC.md Section 5.2
    public func start() async throws {
        let monotonicNs = getMonotonicTimeNs()
        let timestampUs = getCurrentTimestampUs()
        
        // 1. Generate run_id (done in init)
        // 2. Load identity - TODO: implement identity management
        // 3. Initialize SQLite (done in init)
        
        // Insert agent run record
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        try eventWriter.insertAgentRun(
            startedTsUs: timestampUs,
            startedMonotonicNs: monotonicNs,
            agentVersion: Self.agentVersion,
            osVersion: osVersion
        )
        
        // 4. Probe current session state
        let sessionState = sessionSensor.probeCurrentState()
        state = .fromSessionState(sessionState, isSystemAwake: true)
        
        // 5. Check for crashed runs and emit gap_detected if needed
        try await detectAndEmitGaps(currentTimestampUs: timestampUs, currentMonotonicNs: monotonicNs)
        
        // 6. Emit agent_start event
        try emitSystemStateEvent(
            timestampUs: timestampUs,
            monotonicNs: monotonicNs,
            kind: .agentStart,
            source: .startupProbe
        )
        
        // 7. If working, emit initial activity event
        if state.isWorking {
            try await emitInitialActivityEvent(timestampUs: timestampUs, monotonicNs: monotonicNs)
        }
        
        // Start sensors
        sleepWakeSensor.startObserving()
        foregroundAppSensor.startObserving()
        // Session sensor polling will be started by caller if needed
    }
    
    /// Stop the agent gracefully - implements shutdown per SPEC.md Section 5.5.D
    public func stop() async throws {
        let timestampUs = getCurrentTimestampUs()
        let monotonicNs = getMonotonicTimeNs()
        
        // Stop sensors
        sleepWakeSensor.stopObserving()
        foregroundAppSensor.stopObserving()
        sessionSensor.stopPolling()
        
        // Emit agent_stop event
        try emitSystemStateEvent(
            timestampUs: timestampUs,
            monotonicNs: monotonicNs,
            kind: .agentStop,
            source: .shutdownHook
        )
        
        // Close database
        connection.close()
    }
    
    // MARK: - SensorEventHandler
    
    public func handle(_ event: SensorEvent) async {
        do {
            switch event {
            case .sessionStateChanged(let sessionState, let source):
                try await handleSessionStateChange(sessionState, source: source)
                
            case .willSleep(let timestamp, let monotonicNs):
                try await handleWillSleep(timestamp: timestamp, monotonicNs: monotonicNs)
                
            case .didWake(let timestamp, let monotonicNs):
                try await handleDidWake(timestamp: timestamp, monotonicNs: monotonicNs)
                
            case .willPowerOff(let timestamp, let monotonicNs):
                try await handleWillPowerOff(timestamp: timestamp, monotonicNs: monotonicNs)
                
            case .appActivated(let bundleId, let displayName, let pid, let timestamp, let monotonicNs):
                try await handleAppActivated(
                    bundleId: bundleId,
                    displayName: displayName,
                    pid: pid,
                    timestamp: timestamp,
                    monotonicNs: monotonicNs
                )
            }
        } catch {
            // Log error but don't crash the agent
            print("Error handling sensor event: \(error)")
        }
    }
}

// Temporary dummy handler for sensor initialization
private struct DummyHandler: SensorEventHandler {
    func handle(_ event: SensorEvent) async {}
}

