// SPDX-License-Identifier: MIT
// XPCTests.swift - Integration tests for XPC protocol and command handler

import Foundation
import SQLite3
import Testing
@testable import XPCProtocol
@testable import WellWhaddyaKnowAgent
@testable import CoreModel
@testable import Storage
@testable import Reporting
@testable import Timeline

// MARK: - Test Fixtures

/// Helper to create a test database and command handler
struct TestContext {
    let tempDir: URL
    let dbPath: String
    let connection: DatabaseConnection
    let handler: XPCCommandHandler
    
    static func create() throws -> TestContext {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let dbPath = tempDir.appendingPathComponent("test.db").path
        let connection = DatabaseConnection(path: dbPath)
        try connection.open()
        
        let schemaManager = SchemaManager(connection: connection)
        try schemaManager.initializeSchema()
        
        let handler = XPCCommandHandler(
            connection: connection,
            runId: "test-run-\(UUID().uuidString)",
            authorUsername: "testuser",
            authorUid: 501,
            clientVersion: "1.0.0-test"
        )
        
        return TestContext(
            tempDir: tempDir,
            dbPath: dbPath,
            connection: connection,
            handler: handler
        )
    }
    
    func cleanup() {
        connection.close()
        try? FileManager.default.removeItem(at: tempDir)
    }
}

// MARK: - Status API Tests

@Suite("Status API Tests")
struct StatusAPITests {
    
    @Test("getStatus returns valid response")
    func testGetStatus() throws {
        let ctx = try TestContext.create()
        defer { ctx.cleanup() }
        
        let response = ctx.handler.getStatus(
            isWorking: true,
            currentApp: "Safari",
            currentTitle: "Test Page",
            accessibilityStatus: .granted
        )
        
        #expect(response.isWorking == true)
        #expect(response.currentApp == "Safari")
        #expect(response.currentTitle == "Test Page")
        #expect(response.accessibilityStatus == .granted)
        #expect(response.agentUptime >= 0)
        #expect(!response.agentVersion.isEmpty)
    }
    
    @Test("getStatus with not working state")
    func testGetStatusNotWorking() throws {
        let ctx = try TestContext.create()
        defer { ctx.cleanup() }

        let response = ctx.handler.getStatus(
            isWorking: false,
            currentApp: nil,
            currentTitle: nil,
            accessibilityStatus: .denied
        )

        #expect(response.isWorking == false)
        #expect(response.currentApp == nil)
        #expect(response.currentTitle == nil)
        #expect(response.accessibilityStatus == .denied)
    }

    @Test("getStatus includes agentPID")
    func testGetStatusIncludesPID() throws {
        let ctx = try TestContext.create()
        defer { ctx.cleanup() }

        let response = ctx.handler.getStatus(
            isWorking: true,
            currentApp: "Xcode",
            currentTitle: "Project.swift",
            accessibilityStatus: .granted
        )

        // agentPID should be the current test process PID
        #expect(response.agentPID != nil)
        #expect(response.agentPID == Int(ProcessInfo.processInfo.processIdentifier))
    }

    @Test("StatusResponse backward compatibility with nil PID")
    func testStatusResponseBackwardCompat() {
        // Construct without agentPID / registrationStatus (defaults to nil)
        let response = StatusResponse(
            isWorking: true,
            currentApp: "Safari",
            currentTitle: nil,
            accessibilityStatus: .granted,
            agentVersion: "1.0.0",
            agentUptime: 60.0
        )
        #expect(response.agentPID == nil)
        #expect(response.registrationStatus == nil)
    }
}

// MARK: - Edit Operation Tests

@Suite("Edit Operation Tests")
struct EditOperationTests {
    
    @Test("submitDeleteRange creates valid edit event")
    func testSubmitDeleteRange() throws {
        let ctx = try TestContext.create()
        defer { ctx.cleanup() }
        
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let request = DeleteRangeRequest(
            startTsUs: now - 3600_000_000,  // 1 hour ago
            endTsUs: now,
            note: "Test deletion"
        )
        
        let ueeId = try ctx.handler.submitDeleteRange(request)
        #expect(ueeId > 0)
    }
    
    @Test("submitDeleteRange rejects invalid time range")
    func testSubmitDeleteRangeInvalidRange() throws {
        let ctx = try TestContext.create()
        defer { ctx.cleanup() }
        
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let request = DeleteRangeRequest(
            startTsUs: now,
            endTsUs: now - 1000,  // End before start
            note: nil
        )
        
        #expect(throws: XPCError.self) {
            _ = try ctx.handler.submitDeleteRange(request)
        }
    }
    
    @Test("submitAddRange creates valid edit event")
    func testSubmitAddRange() throws {
        let ctx = try TestContext.create()
        defer { ctx.cleanup() }

        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let request = AddRangeRequest(
            startTsUs: now - 3600_000_000,
            endTsUs: now,
            appName: "Safari",
            bundleId: "com.apple.Safari",
            title: "Test Page",
            note: "Manual add"
        )

        let ueeId = try ctx.handler.submitAddRange(request)
        #expect(ueeId > 0)
    }

    @Test("submitAddRange with tags creates tag_range events per SPEC.md Section 9.2")
    func testSubmitAddRangeWithTags() throws {
        let ctx = try TestContext.create()
        defer { ctx.cleanup() }

        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let startTs = now - 3600_000_000  // 1 hour ago
        let endTs = now

        // Add range with two tags (tags will be auto-created)
        let request = AddRangeRequest(
            startTsUs: startTs,
            endTsUs: endTs,
            appName: "Safari",
            bundleId: "com.apple.Safari",
            title: "Test Page",
            tags: ["billable", "meeting"],
            note: "Manual add with tags"
        )

        let addRangeId = try ctx.handler.submitAddRange(request)
        #expect(addRangeId > 0)

        // Verify 3 events were created: 1 add_range + 2 tag_range
        guard let db = ctx.connection.rawPointer else {
            Issue.record("Database not open")
            return
        }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT COUNT(*) FROM user_edit_events;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Issue.record("Failed to prepare statement")
            return
        }

        if sqlite3_step(stmt) == SQLITE_ROW {
            let count = sqlite3_column_int64(stmt, 0)
            #expect(count == 3, "Expected 3 events (1 add_range + 2 tag_range), got \(count)")
        }
        sqlite3_finalize(stmt)
        stmt = nil

        // Verify the add_range event exists
        let addRangeSql = "SELECT op FROM user_edit_events WHERE uee_id = \(addRangeId);"
        guard sqlite3_prepare_v2(db, addRangeSql, -1, &stmt, nil) == SQLITE_OK else {
            Issue.record("Failed to prepare add_range check")
            return
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            let op = String(cString: sqlite3_column_text(stmt, 0))
            #expect(op == "add_range")
        }
        sqlite3_finalize(stmt)
        stmt = nil

        // Verify the tag_range events exist
        let tagRangeSql = "SELECT COUNT(*) FROM user_edit_events WHERE op = 'tag_range';"
        guard sqlite3_prepare_v2(db, tagRangeSql, -1, &stmt, nil) == SQLITE_OK else {
            Issue.record("Failed to prepare tag_range check")
            return
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            let count = sqlite3_column_int64(stmt, 0)
            #expect(count == 2, "Expected 2 tag_range events, got \(count)")
        }
        sqlite3_finalize(stmt)
        stmt = nil

        // Verify tags were auto-created
        let tags = try ctx.handler.listTags()
        #expect(tags.count == 2)
        let tagNames = Set(tags.map { $0.tagName })
        #expect(tagNames.contains("billable"))
        #expect(tagNames.contains("meeting"))
    }

    @Test("submitUndoEdit creates undo event")
    func testSubmitUndoEdit() throws {
        let ctx = try TestContext.create()
        defer { ctx.cleanup() }

        // First create an edit to undo
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let deleteRequest = DeleteRangeRequest(
            startTsUs: now - 3600_000_000,
            endTsUs: now,
            note: "To be undone"
        )
        let targetId = try ctx.handler.submitDeleteRange(deleteRequest)

        // Now undo it
        let undoId = try ctx.handler.submitUndoEdit(targetUeeId: targetId)
        #expect(undoId > 0)
        #expect(undoId != targetId)
    }

    @Test("submitUndoEdit rejects non-existent target")
    func testSubmitUndoEditNonExistent() throws {
        let ctx = try TestContext.create()
        defer { ctx.cleanup() }

        #expect(throws: XPCError.self) {
            _ = try ctx.handler.submitUndoEdit(targetUeeId: 99999)
        }
    }
}

// MARK: - Tag Operation Tests

@Suite("Tag Operation Tests")
struct TagOperationTests {

    @Test("createTag creates new tag")
    func testCreateTag() throws {
        let ctx = try TestContext.create()
        defer { ctx.cleanup() }

        let tagId = try ctx.handler.createTag(name: "work")
        #expect(tagId > 0)
    }

    @Test("createTag rejects empty name")
    func testCreateTagEmptyName() throws {
        let ctx = try TestContext.create()
        defer { ctx.cleanup() }

        #expect(throws: XPCError.self) {
            _ = try ctx.handler.createTag(name: "")
        }
    }

    @Test("createTag rejects duplicate name")
    func testCreateTagDuplicate() throws {
        let ctx = try TestContext.create()
        defer { ctx.cleanup() }

        _ = try ctx.handler.createTag(name: "work")

        #expect(throws: XPCError.self) {
            _ = try ctx.handler.createTag(name: "work")
        }
    }

    @Test("listTags returns created tags")
    func testListTags() throws {
        let ctx = try TestContext.create()
        defer { ctx.cleanup() }

        _ = try ctx.handler.createTag(name: "work")
        _ = try ctx.handler.createTag(name: "personal")

        let tags = try ctx.handler.listTags()
        #expect(tags.count == 2)

        let tagNames = tags.map { $0.tagName }
        #expect(tagNames.contains("work"))
        #expect(tagNames.contains("personal"))
    }

    @Test("retireTag marks tag as retired")
    func testRetireTag() throws {
        let ctx = try TestContext.create()
        defer { ctx.cleanup() }

        _ = try ctx.handler.createTag(name: "temporary")
        try ctx.handler.retireTag(name: "temporary")

        let tags = try ctx.handler.listTags()
        let retiredTag = tags.first { $0.tagName == "temporary" }
        #expect(retiredTag?.isRetired == true)
    }

    @Test("applyTag creates tag_range event")
    func testApplyTag() throws {
        let ctx = try TestContext.create()
        defer { ctx.cleanup() }

        _ = try ctx.handler.createTag(name: "billable")

        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let request = TagRangeRequest(
            startTsUs: now - 3600_000_000,
            endTsUs: now,
            tagName: "billable"
        )

        let ueeId = try ctx.handler.applyTag(request)
        #expect(ueeId > 0)
    }

    @Test("applyTag rejects non-existent tag")
    func testApplyTagNonExistent() throws {
        let ctx = try TestContext.create()
        defer { ctx.cleanup() }

        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let request = TagRangeRequest(
            startTsUs: now - 3600_000_000,
            endTsUs: now,
            tagName: "nonexistent"
        )

        #expect(throws: XPCError.self) {
            _ = try ctx.handler.applyTag(request)
        }
    }

    @Test("removeTag creates untag_range event")
    func testRemoveTag() throws {
        let ctx = try TestContext.create()
        defer { ctx.cleanup() }

        _ = try ctx.handler.createTag(name: "billable")

        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let request = TagRangeRequest(
            startTsUs: now - 3600_000_000,
            endTsUs: now,
            tagName: "billable"
        )

        // Apply tag first
        _ = try ctx.handler.applyTag(request)

        // Then remove it
        let ueeId = try ctx.handler.removeTag(request)
        #expect(ueeId > 0)
    }
}

// MARK: - Export Operation Tests

@Suite("Export Operation Tests")
struct ExportOperationTests {

    @Test("exportTimeline creates CSV file")
    func testExportCSV() throws {
        let ctx = try TestContext.create()
        defer { ctx.cleanup() }

        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let outputPath = ctx.tempDir.appendingPathComponent("export.csv").path

        let request = ExportRequest(
            startTsUs: now - 86400_000_000,  // 24 hours ago
            endTsUs: now,
            format: .csv,
            outputPath: outputPath,
            includeTitles: true
        )

        try ctx.handler.exportTimeline(request)

        // Verify file was created
        #expect(FileManager.default.fileExists(atPath: outputPath))

        // Verify file has CSV header
        let content = try String(contentsOfFile: outputPath, encoding: .utf8)
        #expect(content.contains("machine_id"))
        #expect(content.contains("segment_start_local"))
    }

    @Test("exportTimeline creates JSON file")
    func testExportJSON() throws {
        let ctx = try TestContext.create()
        defer { ctx.cleanup() }

        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let outputPath = ctx.tempDir.appendingPathComponent("export.json").path

        let request = ExportRequest(
            startTsUs: now - 86400_000_000,
            endTsUs: now,
            format: .json,
            outputPath: outputPath,
            includeTitles: false
        )

        try ctx.handler.exportTimeline(request)

        // Verify file was created
        #expect(FileManager.default.fileExists(atPath: outputPath))

        // Verify file has valid JSON structure
        let content = try String(contentsOfFile: outputPath, encoding: .utf8)
        #expect(content.contains("\"identity\""))
        #expect(content.contains("\"range\""))
    }

    @Test("exportTimeline rejects invalid time range")
    func testExportInvalidRange() throws {
        let ctx = try TestContext.create()
        defer { ctx.cleanup() }

        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let request = ExportRequest(
            startTsUs: now,
            endTsUs: now - 1000,  // End before start
            format: .csv,
            outputPath: "/tmp/invalid.csv",
            includeTitles: true
        )

        #expect(throws: XPCError.self) {
            try ctx.handler.exportTimeline(request)
        }
    }
}

// MARK: - Health Operation Tests

@Suite("Health Operation Tests")
struct HealthOperationTests {

    @Test("getHealth returns valid status")
    func testGetHealth() throws {
        let ctx = try TestContext.create()
        defer { ctx.cleanup() }

        let health = try ctx.handler.getHealth()

        #expect(health.isHealthy == true)
        #expect(health.agentUptime >= 0)
        #expect(health.databaseIntegrity == .ok)
    }

    @Test("verifyDatabase succeeds on valid database")
    func testVerifyDatabase() throws {
        let ctx = try TestContext.create()
        defer { ctx.cleanup() }

        // Should not throw on a valid database
        try ctx.handler.verifyDatabase()
    }
}

// MARK: - Input Validation Tests

@Suite("Input Validation Tests")
struct InputValidationTests {

    @Test("validateTimeRange rejects zero timestamps")
    func testValidateTimeRangeZero() {
        #expect(throws: XPCError.self) {
            try XPCInputValidation.validateTimeRange(startTsUs: 0, endTsUs: 1000)
        }
    }

    @Test("validateTimeRange rejects start >= end")
    func testValidateTimeRangeInverted() {
        #expect(throws: XPCError.self) {
            try XPCInputValidation.validateTimeRange(startTsUs: 2000, endTsUs: 1000)
        }
    }

    @Test("validateTagName rejects empty string")
    func testValidateTagNameEmpty() {
        #expect(throws: XPCError.self) {
            try XPCInputValidation.validateTagName("")
        }
    }

    @Test("validateTagName rejects too long names")
    func testValidateTagNameTooLong() {
        let longName = String(repeating: "a", count: 300)
        #expect(throws: XPCError.self) {
            try XPCInputValidation.validateTagName(longName)
        }
    }

    @Test("validateTagName accepts valid names")
    func testValidateTagNameValid() throws {
        try XPCInputValidation.validateTagName("work")
        try XPCInputValidation.validateTagName("project-123")
        try XPCInputValidation.validateTagName("billable_hours")
    }
}

// MARK: - Recent Activity Database Query Tests

@Suite("Recent Activity Database Tests")
struct RecentActivityDatabaseTests {

    /// Helper: insert seed data needed for raw_activity_events into a test DB.
    private func seedEvents(ctx: TestContext, count: Int) throws {
        let runId = "test-run-\(UUID().uuidString)"
        let nowUs = Int64(Date().timeIntervalSince1970 * 1_000_000)

        // Insert agent_runs row
        try ctx.connection.execute("""
            INSERT INTO agent_runs (run_id, started_ts_us, started_monotonic_ns, agent_version, os_version)
            VALUES ('\(runId)', \(nowUs), 0, '1.0.0-test', '14.0');
            """)

        // Insert applications
        for i in 1...count {
            try ctx.connection.execute("""
                INSERT OR IGNORE INTO applications (app_id, bundle_id, display_name, first_seen_ts_us)
                VALUES (\(i), 'com.test.app\(i)', 'App\(i)', \(nowUs));
                """)
        }

        // Insert window titles
        for i in 1...count {
            try ctx.connection.execute("""
                INSERT OR IGNORE INTO window_titles (title_id, title, first_seen_ts_us)
                VALUES (\(i), 'Window Title \(i)', \(nowUs));
                """)
        }

        // Insert raw_activity_events, 60s apart, newest last
        for i in 1...count {
            let ts = nowUs - Int64((count - i) * 60_000_000)  // 60s intervals
            try ctx.connection.execute("""
                INSERT INTO raw_activity_events
                  (run_id, event_ts_us, event_monotonic_ns, app_id, pid, title_id, title_status, reason, is_working)
                VALUES
                  ('\(runId)', \(ts), 0, \(i), 100, \(i), 'ok', 'app_activated', 1);
                """)
        }
    }

    @Test("Query returns 5 most recent from 10 events")
    func recentActivityReturns5MostRecent() throws {
        let ctx = try TestContext.create()
        defer { ctx.cleanup() }

        try seedEvents(ctx: ctx, count: 10)

        // Query matching the app's loadRecentActivity() logic
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(ctx.dbPath, &db, flags, nil) == SQLITE_OK else {
            #expect(Bool(false), "Failed to open DB read-only")
            return
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT rae.rae_id, a.display_name, wt.title, rae.event_ts_us
            FROM raw_activity_events rae
            JOIN applications a ON rae.app_id = a.app_id
            LEFT JOIN window_titles wt ON rae.title_id = wt.title_id
            ORDER BY rae.event_ts_us DESC
            LIMIT 6;
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            #expect(Bool(false), "Failed to prepare statement")
            return
        }

        var rows: [(appName: String, title: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let appName = String(cString: sqlite3_column_text(stmt, 1))
            let title = String(cString: sqlite3_column_text(stmt, 2))
            rows.append((appName: appName, title: title))
        }

        // We inserted 10 events; query LIMIT 6 returns 6 rows (N+1 for duration calc)
        #expect(rows.count == 6)

        // Newest first → App10, App9, App8, App7, App6, App5
        #expect(rows[0].appName == "App10")
        #expect(rows[0].title == "Window Title 10")
        #expect(rows[1].appName == "App9")
        #expect(rows[5].appName == "App5")
    }

    @Test("Empty database returns zero rows")
    func emptyDatabaseReturnsZero() throws {
        let ctx = try TestContext.create()
        defer { ctx.cleanup() }

        var db: OpaquePointer?
        guard sqlite3_open_v2(ctx.dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            #expect(Bool(false), "Failed to open DB")
            return
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT rae.rae_id FROM raw_activity_events rae
            ORDER BY rae.event_ts_us DESC LIMIT 6;
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            #expect(Bool(false), "Failed to prepare")
            return
        }

        var count = 0
        while sqlite3_step(stmt) == SQLITE_ROW { count += 1 }
        #expect(count == 0)
    }

    @Test("Fewer than 5 events returns all available")
    func fewerThan5Events() throws {
        let ctx = try TestContext.create()
        defer { ctx.cleanup() }

        try seedEvents(ctx: ctx, count: 3)

        var db: OpaquePointer?
        guard sqlite3_open_v2(ctx.dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            #expect(Bool(false), "Failed to open DB")
            return
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT rae.rae_id FROM raw_activity_events rae
            ORDER BY rae.event_ts_us DESC LIMIT 6;
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            #expect(Bool(false), "Failed to prepare")
            return
        }

        var count = 0
        while sqlite3_step(stmt) == SQLITE_ROW { count += 1 }
        // Only 3 events inserted → 3 returned (< LIMIT 6)
        #expect(count == 3)
    }
}
