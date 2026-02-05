// SPDX-License-Identifier: MIT
// EventWriter.swift - Database write operations for agent events

import Foundation
import Storage
import SQLite3

/// Handles all database write operations for the agent.
/// The agent is the single writer to the SQLite database.
public final class EventWriter: @unchecked Sendable {
    
    private let connection: DatabaseConnection
    private let runId: String
    
    public init(connection: DatabaseConnection, runId: String) {
        self.connection = connection
        self.runId = runId
    }
    
    // MARK: - Agent Run Management
    
    /// Insert a new agent_runs row for this session
    public func insertAgentRun(startedTsUs: Int64, startedMonotonicNs: UInt64, agentVersion: String, osVersion: String) throws {
        let sql = """
            INSERT INTO agent_runs (run_id, started_ts_us, started_monotonic_ns, agent_version, os_version)
            VALUES ('\(runId)', \(startedTsUs), \(startedMonotonicNs), '\(agentVersion)', '\(osVersion)');
            """
        try connection.execute(sql)
    }
    
    // MARK: - System State Events
    
    /// Insert a system_state_events row
    public func insertSystemStateEvent(
        eventTsUs: Int64,
        eventMonotonicNs: UInt64,
        state: AgentState,
        eventKind: SystemStateEventKind,
        source: SensorSource,
        tzIdentifier: String,
        tzOffsetSeconds: Int,
        payloadJson: String? = nil
    ) throws {
        let payloadValue = payloadJson.map { "'\(escapeSql($0))'" } ?? "NULL"
        
        let sql = """
            INSERT INTO system_state_events (
                run_id, event_ts_us, event_monotonic_ns,
                is_system_awake, is_session_on_console, is_screen_locked, is_working,
                event_kind, source, tz_identifier, tz_offset_seconds, payload_json
            ) VALUES (
                '\(runId)', \(eventTsUs), \(eventMonotonicNs),
                \(state.isSystemAwake ? 1 : 0), \(state.isSessionOnConsole ? 1 : 0), 
                \(state.isScreenLocked ? 1 : 0), \(state.isWorking ? 1 : 0),
                '\(eventKind.rawValue)', '\(source.rawValue)', 
                '\(tzIdentifier)', \(tzOffsetSeconds), \(payloadValue)
            );
            """
        try connection.execute(sql)
    }
    
    // MARK: - Raw Activity Events
    
    /// Ensure an application exists in the applications table, return app_id
    public func ensureApplication(bundleId: String, displayName: String, firstSeenTsUs: Int64) throws -> Int64 {
        // First try to get existing
        guard let db = connection.rawPointer else {
            throw DatabaseError.failedToExecute("Database not open")
        }
        
        var statement: OpaquePointer?
        let selectSql = "SELECT app_id FROM applications WHERE bundle_id = '\(bundleId)';"
        
        if sqlite3_prepare_v2(db, selectSql, -1, &statement, nil) == SQLITE_OK {
            defer { sqlite3_finalize(statement) }
            if sqlite3_step(statement) == SQLITE_ROW {
                return Int64(sqlite3_column_int64(statement, 0))
            }
        }
        
        // Insert new application
        let insertSql = """
            INSERT INTO applications (bundle_id, display_name, first_seen_ts_us)
            VALUES ('\(bundleId)', '\(escapeSql(displayName))', \(firstSeenTsUs));
            """
        try connection.execute(insertSql)
        
        return sqlite3_last_insert_rowid(db)
    }
    
    /// Ensure a window title exists in the window_titles table, return title_id
    public func ensureWindowTitle(title: String, firstSeenTsUs: Int64) throws -> Int64 {
        guard let db = connection.rawPointer else {
            throw DatabaseError.failedToExecute("Database not open")
        }

        let escapedTitle = escapeSql(title)

        // First try to get existing
        var statement: OpaquePointer?
        let selectSql = "SELECT title_id FROM window_titles WHERE title = '\(escapedTitle)';"

        if sqlite3_prepare_v2(db, selectSql, -1, &statement, nil) == SQLITE_OK {
            defer { sqlite3_finalize(statement) }
            if sqlite3_step(statement) == SQLITE_ROW {
                return Int64(sqlite3_column_int64(statement, 0))
            }
        }

        // Insert new window title
        let insertSql = """
            INSERT INTO window_titles (title, first_seen_ts_us)
            VALUES ('\(escapedTitle)', \(firstSeenTsUs));
            """
        try connection.execute(insertSql)

        return sqlite3_last_insert_rowid(db)
    }

    /// Insert a raw_activity_events row
    public func insertRawActivityEvent(
        eventTsUs: Int64,
        eventMonotonicNs: UInt64,
        appId: Int64,
        pid: Int32,
        titleId: Int64?,
        titleStatus: TitleStatus,
        reason: ActivityEventReason,
        isWorking: Bool,
        axErrorCode: Int32? = nil
    ) throws {
        let titleIdValue = titleId.map { String($0) } ?? "NULL"
        let axErrorValue = axErrorCode.map { String($0) } ?? "NULL"
        
        let sql = """
            INSERT INTO raw_activity_events (
                run_id, event_ts_us, event_monotonic_ns,
                app_id, pid, title_id, title_status, reason, is_working, ax_error_code
            ) VALUES (
                '\(runId)', \(eventTsUs), \(eventMonotonicNs),
                \(appId), \(pid), \(titleIdValue), '\(titleStatus.rawValue)', 
                '\(reason.rawValue)', \(isWorking ? 1 : 0), \(axErrorValue)
            );
            """
        try connection.execute(sql)
    }
    
    // MARK: - Gap Detection
    
    /// Find the most recent agent run for gap detection
    public func findPreviousRun() throws -> (runId: String, lastEventTsUs: Int64)? {
        guard let db = connection.rawPointer else {
            throw DatabaseError.failedToExecute("Database not open")
        }
        
        // Find most recent run that isn't the current one
        let sql = """
            SELECT ar.run_id, MAX(sse.event_ts_us) 
            FROM agent_runs ar
            JOIN system_state_events sse ON ar.run_id = sse.run_id
            WHERE ar.run_id != '\(runId)'
            GROUP BY ar.run_id
            ORDER BY ar.started_ts_us DESC
            LIMIT 1;
            """
        
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        
        if sqlite3_step(statement) == SQLITE_ROW {
            let prevRunId = String(cString: sqlite3_column_text(statement, 0))
            let lastTsUs = sqlite3_column_int64(statement, 1)
            return (prevRunId, lastTsUs)
        }
        
        return nil
    }
    
    /// Check if a run has an agent_stop event
    public func hasAgentStopEvent(forRunId checkRunId: String) throws -> Bool {
        guard let db = connection.rawPointer else {
            throw DatabaseError.failedToExecute("Database not open")
        }
        
        let sql = "SELECT 1 FROM system_state_events WHERE run_id = '\(checkRunId)' AND event_kind = 'agent_stop' LIMIT 1;"
        
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        
        return sqlite3_step(statement) == SQLITE_ROW
    }
    
    // MARK: - Helpers
    
    private func escapeSql(_ str: String) -> String {
        str.replacingOccurrences(of: "'", with: "''")
    }
}

import Sensors

