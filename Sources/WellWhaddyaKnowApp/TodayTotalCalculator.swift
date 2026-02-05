// SPDX-License-Identifier: MIT
// TodayTotalCalculator.swift - Calculate today's working time from database

import Foundation
import CoreModel
import Timeline
import Reporting
import Storage
import SQLite3

/// Calculates today's total working time by reading the database directly.
/// This is a read-only operation that doesn't require the agent to be running.
@MainActor
final class TodayTotalCalculator {
    
    /// App Group identifier for shared container
    private static let appGroupId = "group.com.daylily.wellwhaddyaknow"
    
    /// Database filename
    private static let dbFilename = "wwk.sqlite"
    
    /// Get the path to the shared database
    static var databasePath: String? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) else {
            return nil
        }
        return containerURL
            .appendingPathComponent("WellWhaddyaKnow")
            .appendingPathComponent(dbFilename)
            .path
    }
    
    /// Calculate today's total working seconds
    /// - Returns: Total working seconds for today, or 0 if unavailable
    static func calculateTodayTotal() async -> Double {
        guard let dbPath = databasePath else {
            return 0.0
        }
        
        // Check if database exists
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return 0.0
        }
        
        // Calculate today's time range in microseconds
        let calendar = Calendar.current
        let now = Date()
        guard let startOfDay = calendar.startOfDay(for: now) as Date? else {
            return 0.0
        }
        let startTsUs = Int64(startOfDay.timeIntervalSince1970 * 1_000_000)
        let endTsUs = Int64(now.timeIntervalSince1970 * 1_000_000)
        
        // Open database read-only
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK else {
            return 0.0
        }
        defer { sqlite3_close(db) }
        
        // Load events and build timeline
        do {
            let systemEvents = try loadSystemStateEvents(db: db!, start: startTsUs, end: endTsUs)
            let activityEvents = try loadRawActivityEvents(db: db!, start: startTsUs, end: endTsUs)
            let editEvents = try loadUserEditEvents(db: db!, start: startTsUs, end: endTsUs)
            
            let segments = buildEffectiveTimeline(
                systemStateEvents: systemEvents,
                rawActivityEvents: activityEvents,
                userEditEvents: editEvents,
                requestedRange: (startTsUs, endTsUs)
            )
            
            return Aggregations.totalWorkingTime(segments: segments)
        } catch {
            return 0.0
        }
    }
    
    // MARK: - Private Query Methods
    
    private static func loadSystemStateEvents(
        db: OpaquePointer,
        start: Int64,
        end: Int64
    ) throws -> [SystemStateEvent] {
        var events: [SystemStateEvent] = []
        let sql = """
            SELECT sse_id, run_id, event_ts_us, event_monotonic_ns,
                   is_system_awake, is_session_on_console, is_screen_locked, is_working,
                   event_kind, source, tz_identifier, tz_offset_seconds, payload_json
            FROM system_state_events
            WHERE event_ts_us >= ? AND event_ts_us < ?
            ORDER BY event_ts_us;
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.failedToExecute(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_int64(stmt, 1, start)
        sqlite3_bind_int64(stmt, 2, end)
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            let event = SystemStateEvent(
                sseId: sqlite3_column_int64(stmt, 0),
                runId: String(cString: sqlite3_column_text(stmt, 1)),
                eventTsUs: sqlite3_column_int64(stmt, 2),
                eventMonotonicNs: UInt64(sqlite3_column_int64(stmt, 3)),
                isSystemAwake: sqlite3_column_int(stmt, 4) != 0,
                isSessionOnConsole: sqlite3_column_int(stmt, 5) != 0,
                isScreenLocked: sqlite3_column_int(stmt, 6) != 0,
                isWorking: sqlite3_column_int(stmt, 7) != 0,
                eventKind: SystemStateEventKind(rawValue: String(cString: sqlite3_column_text(stmt, 8))) ?? .stateChange,
                source: EventSource(rawValue: String(cString: sqlite3_column_text(stmt, 9))) ?? .manual,
                tzIdentifier: String(cString: sqlite3_column_text(stmt, 10)),
                tzOffsetSeconds: Int(sqlite3_column_int(stmt, 11)),
                payloadJson: sqlite3_column_text(stmt, 12).map { String(cString: $0) }
            )
            events.append(event)
        }
        return events
    }
    
    private static func loadRawActivityEvents(
        db: OpaquePointer,
        start: Int64,
        end: Int64
    ) throws -> [RawActivityEvent] {
        var events: [RawActivityEvent] = []
        let sql = """
            SELECT rae.rae_id, rae.run_id, rae.event_ts_us, rae.event_monotonic_ns,
                   rae.app_id, a.bundle_id, a.display_name, rae.pid,
                   rae.title_id, wt.title_text, rae.title_status, rae.reason,
                   rae.is_working, rae.ax_error_code, rae.payload_json
            FROM raw_activity_events rae
            JOIN applications a ON rae.app_id = a.app_id
            LEFT JOIN window_titles wt ON rae.title_id = wt.title_id
            WHERE rae.event_ts_us >= ? AND rae.event_ts_us < ?
            ORDER BY rae.event_ts_us;
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.failedToExecute(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_int64(stmt, 1, start)
        sqlite3_bind_int64(stmt, 2, end)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let event = RawActivityEvent(
                raeId: sqlite3_column_int64(stmt, 0),
                runId: String(cString: sqlite3_column_text(stmt, 1)),
                eventTsUs: sqlite3_column_int64(stmt, 2),
                eventMonotonicNs: UInt64(sqlite3_column_int64(stmt, 3)),
                appId: sqlite3_column_int64(stmt, 4),
                appBundleId: String(cString: sqlite3_column_text(stmt, 5)),
                appDisplayName: String(cString: sqlite3_column_text(stmt, 6)),
                pid: Int32(sqlite3_column_int(stmt, 7)),
                titleId: sqlite3_column_type(stmt, 8) != SQLITE_NULL ? sqlite3_column_int64(stmt, 8) : nil,
                windowTitle: sqlite3_column_type(stmt, 9) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 9)) : nil,
                titleStatus: TitleStatus(rawValue: String(cString: sqlite3_column_text(stmt, 10))) ?? .error,
                reason: ActivityEventReason(rawValue: String(cString: sqlite3_column_text(stmt, 11))) ?? .appActivated,
                isWorking: sqlite3_column_int(stmt, 12) != 0,
                axErrorCode: sqlite3_column_type(stmt, 13) != SQLITE_NULL ? Int32(sqlite3_column_int(stmt, 13)) : nil,
                payloadJson: sqlite3_column_type(stmt, 14) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 14)) : nil
            )
            events.append(event)
        }
        return events
    }

    private static func loadUserEditEvents(
        db: OpaquePointer,
        start: Int64,
        end: Int64
    ) throws -> [UserEditEvent] {
        var events: [UserEditEvent] = []
        // Query matches user_edit_events schema from SPEC.md Section 6.4
        let sql = """
            SELECT uee_id, created_ts_us, created_monotonic_ns,
                   author_username, author_uid, client, client_version,
                   op, start_ts_us, end_ts_us,
                   tag_id, tag_name,
                   manual_app_bundle_id, manual_app_name, manual_window_title,
                   note, target_uee_id, payload_json
            FROM user_edit_events
            WHERE (start_ts_us < ? AND end_ts_us > ?) OR op = 'undo_edit'
            ORDER BY created_ts_us;
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.failedToExecute(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_int64(stmt, 1, end)
        sqlite3_bind_int64(stmt, 2, start)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let event = UserEditEvent(
                ueeId: sqlite3_column_int64(stmt, 0),
                createdTsUs: sqlite3_column_int64(stmt, 1),
                createdMonotonicNs: UInt64(sqlite3_column_int64(stmt, 2)),
                authorUsername: String(cString: sqlite3_column_text(stmt, 3)),
                authorUid: Int(sqlite3_column_int(stmt, 4)),
                client: EditClient(rawValue: String(cString: sqlite3_column_text(stmt, 5))) ?? .ui,
                clientVersion: String(cString: sqlite3_column_text(stmt, 6)),
                op: EditOperation(rawValue: String(cString: sqlite3_column_text(stmt, 7))) ?? .deleteRange,
                startTsUs: sqlite3_column_int64(stmt, 8),
                endTsUs: sqlite3_column_int64(stmt, 9),
                tagId: sqlite3_column_type(stmt, 10) != SQLITE_NULL ? sqlite3_column_int64(stmt, 10) : nil,
                tagName: sqlite3_column_type(stmt, 11) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 11)) : nil,
                manualAppBundleId: sqlite3_column_type(stmt, 12) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 12)) : nil,
                manualAppName: sqlite3_column_type(stmt, 13) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 13)) : nil,
                manualWindowTitle: sqlite3_column_type(stmt, 14) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 14)) : nil,
                note: sqlite3_column_type(stmt, 15) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 15)) : nil,
                targetUeeId: sqlite3_column_type(stmt, 16) != SQLITE_NULL ? sqlite3_column_int64(stmt, 16) : nil,
                payloadJson: sqlite3_column_type(stmt, 17) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 17)) : nil
            )
            events.append(event)
        }
        return events
    }
}

