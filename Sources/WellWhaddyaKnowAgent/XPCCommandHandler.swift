// SPDX-License-Identifier: MIT
// XPCCommandHandler.swift - XPC command handler implementing AgentServiceProtocol

import Foundation
import Storage
import CoreModel
import Timeline
import XPCProtocol
import Reporting
import SQLite3

/// Handles XPC commands for agent operations
public final class XPCCommandHandler: @unchecked Sendable {

    private let connection: DatabaseConnection
    private let runId: String
    private let startTime: Date

    // Author info
    private let authorUsername: String
    private let authorUid: Int
    private let clientVersion: String

    public static let version = BuildVersion.version

    public init(
        connection: DatabaseConnection,
        runId: String,
        authorUsername: String = NSUserName(),
        authorUid: Int = Int(getuid()),
        clientVersion: String = XPCCommandHandler.version
    ) {
        self.connection = connection
        self.runId = runId
        self.startTime = Date()
        self.authorUsername = authorUsername
        self.authorUid = authorUid
        self.clientVersion = clientVersion
    }

    // MARK: - Status API

    /// Get agent status (isWorking state, current app/title)
    public func getStatus(
        isWorking: Bool,
        currentApp: String?,
        currentTitle: String?,
        accessibilityStatus: AccessibilityStatus
    ) -> StatusResponse {
        StatusResponse(
            isWorking: isWorking,
            currentApp: currentApp,
            currentTitle: currentTitle,
            accessibilityStatus: accessibilityStatus,
            agentVersion: Agent.agentVersion,
            agentUptime: Date().timeIntervalSince(startTime),
            agentPID: Int(ProcessInfo.processInfo.processIdentifier)
        )
    }

    // MARK: - Edit Operations

    /// Submit a delete range edit
    public func submitDeleteRange(_ request: DeleteRangeRequest) throws -> Int64 {
        try XPCInputValidation.validateTimeRange(startTsUs: request.startTsUs, endTsUs: request.endTsUs)
        return try insertUserEditEvent(
            op: .deleteRange,
            startTsUs: request.startTsUs,
            endTsUs: request.endTsUs,
            note: request.note
        )
    }

    /// Submit an add range edit
    /// Per SPEC.md Section 9.2: also emits tag_range events for each tag in request.tags
    public func submitAddRange(_ request: AddRangeRequest) throws -> Int64 {
        try XPCInputValidation.validateTimeRange(startTsUs: request.startTsUs, endTsUs: request.endTsUs)

        // First, insert the add_range event
        let addRangeId = try insertUserEditEvent(
            op: .addRange,
            startTsUs: request.startTsUs,
            endTsUs: request.endTsUs,
            manualAppBundleId: request.bundleId,
            manualAppName: request.appName,
            manualWindowTitle: request.title,
            note: request.note
        )

        // Then, emit tag_range events for each tag (per SPEC.md Section 9.2)
        for tagName in request.tags {
            // Validate tag name
            try XPCInputValidation.validateTagName(tagName)

            // Find or create the tag
            var tagId = try findTagId(name: tagName)
            if tagId == nil {
                // Auto-create tag if it doesn't exist
                tagId = try createTagInternal(name: tagName)
            }

            // Insert tag_range event with same time range as the add_range
            _ = try insertUserEditEvent(
                op: .tagRange,
                startTsUs: request.startTsUs,
                endTsUs: request.endTsUs,
                tagId: tagId,
                tagName: tagName
            )
        }

        return addRangeId
    }

    /// Internal helper to create a tag without throwing if it already exists
    private func createTagInternal(name: String) throws -> Int64 {
        guard let db = connection.rawPointer else {
            throw XPCError.databaseError(message: "Database not open")
        }
        let tsUs = getCurrentTimestampUs()
        let sql = "INSERT INTO tags (name, created_ts_us, sort_order) VALUES ('\(escapeSql(name))', \(tsUs), 0);"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw XPCError.databaseError(message: String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_last_insert_rowid(db)
    }

    /// Submit an undo edit
    public func submitUndoEdit(targetUeeId: Int64) throws -> Int64 {
        // Verify target exists
        guard try userEditEventExists(ueeId: targetUeeId) else {
            throw XPCError.undoTargetNotFound(ueeId: targetUeeId)
        }
        // Check if already undone
        if try isUserEditEventUndone(ueeId: targetUeeId) {
            throw XPCError.undoTargetAlreadyUndone(ueeId: targetUeeId)
        }
        // Get the target's time range for the undo event
        let targetRange = try getUserEditEventRange(ueeId: targetUeeId)
        return try insertUserEditEvent(
            op: .undoEdit,
            startTsUs: targetRange.startTsUs,
            endTsUs: targetRange.endTsUs,
            targetUeeId: targetUeeId
        )
    }

    // MARK: - Tag Operations

    /// Apply a tag to a time range
    public func applyTag(_ request: TagRangeRequest) throws -> Int64 {
        try XPCInputValidation.validateTimeRange(startTsUs: request.startTsUs, endTsUs: request.endTsUs)
        try XPCInputValidation.validateTagName(request.tagName)
        guard let tagId = try findTagId(name: request.tagName) else {
            throw XPCError.tagNotFound(name: request.tagName)
        }
        return try insertUserEditEvent(
            op: .tagRange,
            startTsUs: request.startTsUs,
            endTsUs: request.endTsUs,
            tagId: tagId,
            tagName: request.tagName
        )
    }

    /// Remove a tag from a time range
    public func removeTag(_ request: TagRangeRequest) throws -> Int64 {
        try XPCInputValidation.validateTimeRange(startTsUs: request.startTsUs, endTsUs: request.endTsUs)
        try XPCInputValidation.validateTagName(request.tagName)
        guard let tagId = try findTagId(name: request.tagName) else {
            throw XPCError.tagNotFound(name: request.tagName)
        }
        return try insertUserEditEvent(
            op: .untagRange,
            startTsUs: request.startTsUs,
            endTsUs: request.endTsUs,
            tagId: tagId,
            tagName: request.tagName
        )
    }

    /// List all tags
    public func listTags() throws -> [TagInfo] {
        guard let db = connection.rawPointer else {
            throw XPCError.databaseError(message: "Database not open")
        }
        var tags: [TagInfo] = []
        let sql = "SELECT tag_id, name, created_ts_us, retired_ts_us FROM tags ORDER BY sort_order, name;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw XPCError.databaseError(message: String(cString: sqlite3_errmsg(db)))
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let tagId = sqlite3_column_int64(stmt, 0)
            let name = String(cString: sqlite3_column_text(stmt, 1))
            let createdTsUs = sqlite3_column_int64(stmt, 2)
            let retiredTsUs = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 3)
            tags.append(TagInfo(
                tagId: tagId,
                tagName: name,
                isRetired: retiredTsUs != nil,
                createdTsUs: createdTsUs,
                retiredTsUs: retiredTsUs
            ))
        }
        return tags
    }

    /// Create a new tag
    public func createTag(name: String) throws -> Int64 {
        try XPCInputValidation.validateTagName(name)
        guard let db = connection.rawPointer else {
            throw XPCError.databaseError(message: "Database not open")
        }
        // Check if tag already exists
        if try findTagId(name: name) != nil {
            throw XPCError.tagAlreadyExists(name: name)
        }
        let tsUs = getCurrentTimestampUs()
        let sql = "INSERT INTO tags (name, created_ts_us, sort_order) VALUES ('\(escapeSql(name))', \(tsUs), 0);"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw XPCError.databaseError(message: String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_last_insert_rowid(db)
    }

    /// Retire a tag
    public func retireTag(name: String) throws {
        try XPCInputValidation.validateTagName(name)
        guard let db = connection.rawPointer else {
            throw XPCError.databaseError(message: "Database not open")
        }
        guard try findTagId(name: name) != nil else {
            throw XPCError.tagNotFound(name: name)
        }
        let tsUs = getCurrentTimestampUs()
        let sql = "UPDATE tags SET retired_ts_us = \(tsUs) WHERE name = '\(escapeSql(name))' AND retired_ts_us IS NULL;"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw XPCError.databaseError(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - Export Operations

    /// Export timeline to file
    public func exportTimeline(_ request: ExportRequest) throws {
        try XPCInputValidation.validateTimeRange(startTsUs: request.startTsUs, endTsUs: request.endTsUs)

        // Build effective timeline
        let systemStateEvents = try loadSystemStateEvents(
            startTsUs: request.startTsUs,
            endTsUs: request.endTsUs
        )
        let rawActivityEvents = try loadRawActivityEvents(
            startTsUs: request.startTsUs,
            endTsUs: request.endTsUs
        )
        let userEditEvents = try loadUserEditEvents()

        let segments = buildEffectiveTimeline(
            systemStateEvents: systemStateEvents,
            rawActivityEvents: rawActivityEvents,
            userEditEvents: userEditEvents,
            requestedRange: (startUs: request.startTsUs, endUs: request.endTsUs)
        )

        // Get identity
        let identity = try loadIdentity()

        // Generate output
        let content: String
        switch request.format {
        case .csv:
            content = CSVExporter.export(
                segments: segments,
                identity: identity,
                includeTitles: request.includeTitles
            )
        case .json:
            content = JSONExporter.export(
                segments: segments,
                identity: identity,
                range: (startUs: request.startTsUs, endUs: request.endTsUs),
                includeTitles: request.includeTitles
            )
        }

        // Write atomically (write to temp file, then rename)
        let outputURL = URL(fileURLWithPath: request.outputPath)
        let tempURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")

        do {
            try content.write(to: tempURL, atomically: false, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: tempURL)
        } catch {
            // Clean up temp file if it exists
            try? FileManager.default.removeItem(at: tempURL)
            throw XPCError.exportFailed(message: error.localizedDescription)
        }
    }

    private func loadIdentity() throws -> ReportIdentity {
        guard let db = connection.rawPointer else {
            throw XPCError.databaseError(message: "Database not open")
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT machine_id, username, uid FROM identity LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else {
            // Return default identity if not set
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

    // MARK: - Health / Doctor

    /// Get agent health status
    public func getHealth() throws -> HealthStatus {
        let integrity = try verifyDatabaseIntegrity()
        let counts = try getEventCounts()
        let lastEventTsUs = try getLastEventTimestamp()
        let schemaVersion = try getSchemaVersion()

        return HealthStatus(
            isHealthy: integrity == .ok,
            databaseIntegrity: integrity,
            accessibilityPermission: .unknown,  // Will be set by Agent
            agentUptime: Date().timeIntervalSince(startTime),
            lastEventTsUs: lastEventTsUs,
            schemaVersion: schemaVersion,
            eventCounts: counts
        )
    }

    /// Verify database integrity
    public func verifyDatabase() throws {
        let status = try verifyDatabaseIntegrity()
        if status != .ok {
            throw XPCError.databaseError(message: "Database integrity check failed")
        }
    }

    private func verifyDatabaseIntegrity() throws -> DatabaseIntegrityStatus {
        guard let db = connection.rawPointer else {
            return .unknown
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check;", -1, &stmt, nil) == SQLITE_OK else {
            return .unknown
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            let result = String(cString: sqlite3_column_text(stmt, 0))
            return result == "ok" ? .ok : .corrupted
        }
        return .unknown
    }

    private func getEventCounts() throws -> EventCounts {
        guard let db = connection.rawPointer else {
            throw XPCError.databaseError(message: "Database not open")
        }
        func count(_ table: String) -> Int64 {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table);", -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return sqlite3_column_int64(stmt, 0)
        }
        return EventCounts(
            systemStateEvents: count("system_state_events"),
            rawActivityEvents: count("raw_activity_events"),
            userEditEvents: count("user_edit_events"),
            tags: count("tags")
        )
    }

    private func getLastEventTimestamp() throws -> Int64? {
        guard let db = connection.rawPointer else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT MAX(event_ts_us) FROM system_state_events;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private func getSchemaVersion() throws -> Int {
        guard let db = connection.rawPointer else { return 0 }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: - Private Helpers

    private func findTagId(name: String) throws -> Int64? {
        guard let db = connection.rawPointer else {
            throw XPCError.databaseError(message: "Database not open")
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT tag_id FROM tags WHERE name = '\(escapeSql(name))';"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw XPCError.databaseError(message: String(cString: sqlite3_errmsg(db)))
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int64(stmt, 0)
        }
        return nil
    }

    private func userEditEventExists(ueeId: Int64) throws -> Bool {
        guard let db = connection.rawPointer else {
            throw XPCError.databaseError(message: "Database not open")
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT 1 FROM user_edit_events WHERE uee_id = \(ueeId);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw XPCError.databaseError(message: String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func isUserEditEventUndone(ueeId: Int64) throws -> Bool {
        guard let db = connection.rawPointer else {
            throw XPCError.databaseError(message: "Database not open")
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        // Check if there's an undo_edit targeting this uee_id
        let sql = "SELECT 1 FROM user_edit_events WHERE op = 'undo_edit' AND target_uee_id = \(ueeId);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw XPCError.databaseError(message: String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func getUserEditEventRange(ueeId: Int64) throws -> (startTsUs: Int64, endTsUs: Int64) {
        guard let db = connection.rawPointer else {
            throw XPCError.databaseError(message: "Database not open")
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT start_ts_us, end_ts_us FROM user_edit_events WHERE uee_id = \(ueeId);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw XPCError.databaseError(message: String(cString: sqlite3_errmsg(db)))
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw XPCError.undoTargetNotFound(ueeId: ueeId)
        }
        return (sqlite3_column_int64(stmt, 0), sqlite3_column_int64(stmt, 1))
    }

    private func insertUserEditEvent(
        op: EditOperation,
        startTsUs: Int64,
        endTsUs: Int64,
        tagId: Int64? = nil,
        tagName: String? = nil,
        manualAppBundleId: String? = nil,
        manualAppName: String? = nil,
        manualWindowTitle: String? = nil,
        note: String? = nil,
        targetUeeId: Int64? = nil
    ) throws -> Int64 {
        guard let db = connection.rawPointer else {
            throw XPCError.databaseError(message: "Database not open")
        }
        let tsUs = getCurrentTimestampUs()
        let monotonicNs = getMonotonicTimeNs()

        let tagIdVal = tagId.map { String($0) } ?? "NULL"
        let manualBundleVal = manualAppBundleId.map { "'\(escapeSql($0))'" } ?? "NULL"
        let manualNameVal = manualAppName.map { "'\(escapeSql($0))'" } ?? "NULL"
        let manualTitleVal = manualWindowTitle.map { "'\(escapeSql($0))'" } ?? "NULL"
        let noteVal = note.map { "'\(escapeSql($0))'" } ?? "NULL"
        let targetVal = targetUeeId.map { String($0) } ?? "NULL"

        let sql = """
            INSERT INTO user_edit_events (
                created_ts_us, created_monotonic_ns,
                author_username, author_uid,
                client, client_version,
                op, start_ts_us, end_ts_us,
                tag_id, manual_app_bundle_id, manual_app_name,
                manual_window_title, note, target_uee_id
            ) VALUES (
                \(tsUs), \(monotonicNs),
                '\(escapeSql(authorUsername))', \(authorUid),
                'cli', '\(clientVersion)',
                '\(op.rawValue)', \(startTsUs), \(endTsUs),
                \(tagIdVal), \(manualBundleVal), \(manualNameVal),
                \(manualTitleVal), \(noteVal), \(targetVal)
            );
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw XPCError.databaseError(message: String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_last_insert_rowid(db)
    }

    private func escapeSql(_ str: String) -> String {
        str.replacingOccurrences(of: "'", with: "''")
    }

    private func getCurrentTimestampUs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000_000)
    }

    private func getMonotonicTimeNs() -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let machTime = mach_absolute_time()
        return machTime * UInt64(info.numer) / UInt64(info.denom)
    }

    // MARK: - Data Loading for Timeline

    private func loadSystemStateEvents(startTsUs: Int64, endTsUs: Int64) throws -> [SystemStateEvent] {
        guard let db = connection.rawPointer else {
            throw XPCError.databaseError(message: "Database not open")
        }
        var events: [SystemStateEvent] = []
        let sql = """
            SELECT sse_id, run_id, event_ts_us, event_monotonic_ns,
                   is_system_awake, is_session_on_console, is_screen_locked, is_working,
                   event_kind, source, tz_identifier, tz_offset_seconds, payload_json
            FROM system_state_events
            WHERE event_ts_us >= \(startTsUs) AND event_ts_us < \(endTsUs)
            ORDER BY event_ts_us;
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw XPCError.databaseError(message: String(cString: sqlite3_errmsg(db)))
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let payload = sqlite3_column_type(stmt, 12) == SQLITE_NULL ? nil
                : String(cString: sqlite3_column_text(stmt, 12))
            let kindRaw = String(cString: sqlite3_column_text(stmt, 8))
            let sourceRaw = String(cString: sqlite3_column_text(stmt, 9))
            events.append(SystemStateEvent(
                sseId: sqlite3_column_int64(stmt, 0),
                runId: String(cString: sqlite3_column_text(stmt, 1)),
                eventTsUs: sqlite3_column_int64(stmt, 2),
                eventMonotonicNs: UInt64(sqlite3_column_int64(stmt, 3)),
                isSystemAwake: sqlite3_column_int(stmt, 4) != 0,
                isSessionOnConsole: sqlite3_column_int(stmt, 5) != 0,
                isScreenLocked: sqlite3_column_int(stmt, 6) != 0,
                isWorking: sqlite3_column_int(stmt, 7) != 0,
                eventKind: CoreModel.SystemStateEventKind(rawValue: kindRaw) ?? CoreModel.SystemStateEventKind.stateChange,
                source: CoreModel.EventSource(rawValue: sourceRaw) ?? CoreModel.EventSource.manual,
                tzIdentifier: String(cString: sqlite3_column_text(stmt, 10)),
                tzOffsetSeconds: Int(sqlite3_column_int(stmt, 11)),
                payloadJson: payload
            ))
        }
        return events
    }

    private func loadRawActivityEvents(startTsUs: Int64, endTsUs: Int64) throws -> [RawActivityEvent] {
        guard let db = connection.rawPointer else {
            throw XPCError.databaseError(message: "Database not open")
        }
        var events: [RawActivityEvent] = []
        let sql = """
            SELECT r.rae_id, r.run_id, r.event_ts_us, r.event_monotonic_ns,
                   r.app_id, a.bundle_id, a.display_name, r.pid,
                   r.title_id, w.title, r.title_status, r.reason, r.is_working,
                   r.ax_error_code, r.payload_json
            FROM raw_activity_events r
            JOIN applications a ON r.app_id = a.app_id
            LEFT JOIN window_titles w ON r.title_id = w.title_id
            WHERE r.event_ts_us >= \(startTsUs) AND r.event_ts_us < \(endTsUs)
            ORDER BY r.event_ts_us;
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw XPCError.databaseError(message: String(cString: sqlite3_errmsg(db)))
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let titleId = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 8)
            let title = sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 9))
            let titleStatusRaw = String(cString: sqlite3_column_text(stmt, 10))
            let reasonRaw = String(cString: sqlite3_column_text(stmt, 11))
            let axErr = sqlite3_column_type(stmt, 13) == SQLITE_NULL ? nil : Int32(sqlite3_column_int(stmt, 13))
            let payload = sqlite3_column_type(stmt, 14) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 14))
            events.append(RawActivityEvent(
                raeId: sqlite3_column_int64(stmt, 0),
                runId: String(cString: sqlite3_column_text(stmt, 1)),
                eventTsUs: sqlite3_column_int64(stmt, 2),
                eventMonotonicNs: UInt64(sqlite3_column_int64(stmt, 3)),
                appId: sqlite3_column_int64(stmt, 4),
                appBundleId: String(cString: sqlite3_column_text(stmt, 5)),
                appDisplayName: String(cString: sqlite3_column_text(stmt, 6)),
                pid: Int32(sqlite3_column_int(stmt, 7)),
                titleId: titleId,
                windowTitle: title,
                titleStatus: CoreModel.TitleStatus(rawValue: titleStatusRaw) ?? CoreModel.TitleStatus.noPermission,
                reason: CoreModel.ActivityEventReason(rawValue: reasonRaw) ?? CoreModel.ActivityEventReason.appActivated,
                isWorking: sqlite3_column_int(stmt, 12) != 0,
                axErrorCode: axErr,
                payloadJson: payload
            ))
        }
        return events
    }

    private func loadUserEditEvents() throws -> [UserEditEvent] {
        guard let db = connection.rawPointer else {
            throw XPCError.databaseError(message: "Database not open")
        }
        var events: [UserEditEvent] = []
        let sql = """
            SELECT u.uee_id, u.created_ts_us, u.created_monotonic_ns,
                   u.author_username, u.author_uid, u.client, u.client_version,
                   u.op, u.start_ts_us, u.end_ts_us, u.tag_id, t.name,
                   u.manual_app_bundle_id, u.manual_app_name, u.manual_window_title,
                   u.note, u.target_uee_id, u.payload_json
            FROM user_edit_events u
            LEFT JOIN tags t ON u.tag_id = t.tag_id
            ORDER BY u.created_ts_us;
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw XPCError.databaseError(message: String(cString: sqlite3_errmsg(db)))
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let tagId = sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 10)
            let tagName = sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 11))
            let bundleId = sqlite3_column_type(stmt, 12) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 12))
            let appName = sqlite3_column_type(stmt, 13) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 13))
            let winTitle = sqlite3_column_type(stmt, 14) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 14))
            let note = sqlite3_column_type(stmt, 15) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 15))
            let targetId = sqlite3_column_type(stmt, 16) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 16)
            let payload = sqlite3_column_type(stmt, 17) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 17))
            events.append(UserEditEvent(
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
                tagId: tagId,
                tagName: tagName,
                manualAppBundleId: bundleId,
                manualAppName: appName,
                manualWindowTitle: winTitle,
                note: note,
                targetUeeId: targetId,
                payloadJson: payload
            ))
        }
        return events
    }
}

