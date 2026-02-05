// SPDX-License-Identifier: MIT
// DatabaseReader.swift - Read-only database access for CLI

import Foundation
import SQLite3
import CoreModel
import Timeline
import Reporting

/// Read-only database access for CLI commands
final class DatabaseReader {
    private var db: OpaquePointer?
    let path: String

    init(path: String) throws {
        self.path = path
        
        guard FileManager.default.fileExists(atPath: path) else {
            throw CLIError.databaseNotFound(path: path)
        }
        
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            throw CLIError.databaseError(message: msg)
        }
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Identity

    func loadIdentity() throws -> ReportIdentity {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT machine_id, username, uid FROM identity LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else {
            return ReportIdentity(
                machineId: ProcessInfo.processInfo.hostName,
                username: NSUserName(),
                uid: Int(getuid())
            )
        }
        return ReportIdentity(
            machineId: String(cString: sqlite3_column_text(stmt, 0)),
            username: String(cString: sqlite3_column_text(stmt, 1)),
            uid: Int(sqlite3_column_int(stmt, 2))
        )
    }

    // MARK: - Timeline Building

    func buildTimeline(startTsUs: Int64, endTsUs: Int64) throws -> [EffectiveSegment] {
        let systemEvents = try loadSystemStateEvents(start: startTsUs, end: endTsUs)
        let activityEvents = try loadRawActivityEvents(start: startTsUs, end: endTsUs)
        let editEvents = try loadUserEditEvents()

        return buildEffectiveTimeline(
            systemStateEvents: systemEvents,
            rawActivityEvents: activityEvents,
            userEditEvents: editEvents,
            requestedRange: (startTsUs, endTsUs)
        )
    }

    // MARK: - System State Events

    private func loadSystemStateEvents(start: Int64, end: Int64) throws -> [SystemStateEvent] {
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
            throw CLIError.databaseError(message: String(cString: sqlite3_errmsg(db)))
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

    // MARK: - Raw Activity Events

    private func loadRawActivityEvents(start: Int64, end: Int64) throws -> [RawActivityEvent] {
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
            throw CLIError.databaseError(message: String(cString: sqlite3_errmsg(db)))
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

    // MARK: - User Edit Events

    private func loadUserEditEvents() throws -> [UserEditEvent] {
        var events: [UserEditEvent] = []
        let sql = """
            SELECT uee_id, created_ts_us, created_monotonic_ns,
                   author_username, author_uid, client, client_version,
                   op, start_ts_us, end_ts_us,
                   tag_id, tag_name,
                   manual_app_bundle_id, manual_app_name, manual_window_title,
                   note, target_uee_id, payload_json
            FROM user_edit_events
            ORDER BY created_ts_us;
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CLIError.databaseError(message: String(cString: sqlite3_errmsg(db)))
        }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let event = UserEditEvent(
                ueeId: sqlite3_column_int64(stmt, 0),
                createdTsUs: sqlite3_column_int64(stmt, 1),
                createdMonotonicNs: UInt64(sqlite3_column_int64(stmt, 2)),
                authorUsername: String(cString: sqlite3_column_text(stmt, 3)),
                authorUid: Int(sqlite3_column_int(stmt, 4)),
                client: EditClient(rawValue: String(cString: sqlite3_column_text(stmt, 5))) ?? .cli,
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

    // MARK: - Tags

    func loadTags() throws -> [TagRow] {
        var tags: [TagRow] = []
        let sql = "SELECT tag_id, name, created_ts_us, retired_ts_us FROM tags ORDER BY name;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CLIError.databaseError(message: String(cString: sqlite3_errmsg(db)))
        }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let tag = TagRow(
                tagId: sqlite3_column_int64(stmt, 0),
                name: String(cString: sqlite3_column_text(stmt, 1)),
                createdTsUs: sqlite3_column_int64(stmt, 2),
                retiredTsUs: sqlite3_column_type(stmt, 3) != SQLITE_NULL ? sqlite3_column_int64(stmt, 3) : nil
            )
            tags.append(tag)
        }
        return tags
    }

    // MARK: - Database Info

    func getSchemaVersion() throws -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else {
            return 0
        }
        return Int(sqlite3_column_int(stmt, 0))
    }

    func getEventCounts() throws -> (sse: Int64, rae: Int64, uee: Int64, tags: Int64) {
        func count(_ table: String) -> Int64 {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table);", -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return sqlite3_column_int64(stmt, 0)
        }
        return (
            sse: count("system_state_events"),
            rae: count("raw_activity_events"),
            uee: count("user_edit_events"),
            tags: count("tags")
        )
    }

    func getDateRange() throws -> (earliest: Int64?, latest: Int64?) {
        var earliest: Int64?
        var latest: Int64?

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            SELECT MIN(event_ts_us), MAX(event_ts_us) FROM (
                SELECT event_ts_us FROM system_state_events
                UNION ALL
                SELECT event_ts_us FROM raw_activity_events
            );
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else {
            return (nil, nil)
        }
        if sqlite3_column_type(stmt, 0) != SQLITE_NULL {
            earliest = sqlite3_column_int64(stmt, 0)
        }
        if sqlite3_column_type(stmt, 1) != SQLITE_NULL {
            latest = sqlite3_column_int64(stmt, 1)
        }
        return (earliest, latest)
    }

    func verifyIntegrity() throws -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check;", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else {
            return false
        }
        let result = String(cString: sqlite3_column_text(stmt, 0))
        return result == "ok"
    }
}

// MARK: - Tag Row

struct TagRow {
    let tagId: Int64
    let name: String
    let createdTsUs: Int64
    let retiredTsUs: Int64?

    var isRetired: Bool { retiredTsUs != nil }
}
