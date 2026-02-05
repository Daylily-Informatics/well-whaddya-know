// SPDX-License-Identifier: MIT
// XPCTests.swift - Integration tests for XPC protocol and command handler

import Foundation
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

