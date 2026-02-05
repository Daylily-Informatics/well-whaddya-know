// SPDX-License-Identifier: MIT
// Agent.swift - Main background agent implementation

import Foundation
import Storage
import Sensors

/// Errors that can occur in the Agent
public enum AgentError: Error {
    case sensorsNotConfigured
    case databaseError(String)
}

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

    // Sensors - created in configureSensors() after actor init completes
    // so we can pass `self` as the handler
    var sessionSensor: SessionStateSensor?
    var sleepWakeSensor: SleepWakeSensor?
    var foregroundAppSensor: ForegroundAppSensor?
    var accessibilitySensor: AccessibilitySensor?

    // Track current foreground app for activity events
    var currentAppId: Int64?
    var currentPid: pid_t = 0

    // Track accessibility permission state
    var hasAccessibilityPermission: Bool = false

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

        // Sensors are created in configureSensors() after actor init completes
        // This allows us to pass `self` as the handler
        self.sessionSensor = nil
        self.sleepWakeSensor = nil
        self.foregroundAppSensor = nil
    }

    /// Configure sensors with the Agent as their handler.
    /// Must be called after init() completes, before start().
    /// This two-phase initialization is required because Swift actors
    /// cannot pass `self` during their own initialization.
    public func configureSensors() {
        self.sessionSensor = SessionStateSensor(handler: self)
        self.sleepWakeSensor = SleepWakeSensor(handler: self)
        self.foregroundAppSensor = ForegroundAppSensor(handler: self)
        self.accessibilitySensor = AccessibilitySensor(handler: self)
        self.hasAccessibilityPermission = AccessibilitySensor.checkPermission()
    }
    
    // MARK: - Lifecycle (SPEC.md Section 5.2)

    /// Start the agent - implements startup sequence per SPEC.md Section 5.2
    public func start() async throws {
        // Ensure sensors are configured before starting
        guard let sessionSensor = sessionSensor,
              let sleepWakeSensor = sleepWakeSensor,
              let foregroundAppSensor = foregroundAppSensor,
              let _ = accessibilitySensor else {
            throw AgentError.sensorsNotConfigured
        }

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

        // Start sensors - they will call back into this agent via handle()
        sleepWakeSensor.startObserving()
        foregroundAppSensor.startObserving()
        // Session sensor polling will be started by caller if needed
    }

    /// Stop the agent gracefully - implements shutdown per SPEC.md Section 5.5.D
    public func stop() async throws {
        let timestampUs = getCurrentTimestampUs()
        let monotonicNs = getMonotonicTimeNs()

        // Stop sensors (safe to call even if nil)
        sleepWakeSensor?.stopObserving()
        foregroundAppSensor?.stopObserving()
        sessionSensor?.stopPolling()
        accessibilitySensor?.stopObserving()

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

            case .titleChanged(let pid, let result, let reason, let timestamp, let monotonicNs):
                try await handleTitleChanged(
                    pid: pid,
                    result: result,
                    reason: reason,
                    timestamp: timestamp,
                    monotonicNs: monotonicNs
                )

            case .accessibilityPermissionChanged(let granted, let timestamp, let monotonicNs):
                try await handleAccessibilityPermissionChanged(
                    granted: granted,
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
