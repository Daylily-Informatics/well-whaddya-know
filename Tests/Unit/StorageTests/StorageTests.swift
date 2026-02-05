// SPDX-License-Identifier: MIT
// StorageTests.swift - Unit tests for the Storage module

import Testing
import SQLite3
@testable import Storage

@Suite("Storage Tests")
struct StorageTests {

    // MARK: - Schema Initialization Tests

    @Test("Fresh database has version 0")
    func schemaInitializationFromScratch() throws {
        let connection = DatabaseConnection(path: ":memory:")
        try connection.open()
        defer { connection.close() }

        let schemaManager = SchemaManager(connection: connection)

        // Given: A fresh database with version 0
        let initialVersion = try connection.getSchemaVersion()
        #expect(initialVersion == 0, "Fresh database should have version 0")

        // When: We initialize the schema
        try schemaManager.initializeSchema()

        // Then: The schema version should be set to current
        let finalVersion = try connection.getSchemaVersion()
        #expect(finalVersion == Schema.currentVersion)
    }

    @Test("Schema initialization creates all tables")
    func schemaInitializationCreatesAllTables() throws {
        let connection = DatabaseConnection(path: ":memory:")
        try connection.open()
        defer { connection.close() }

        let schemaManager = SchemaManager(connection: connection)

        // When: We initialize the schema
        try schemaManager.initializeSchema()

        // Then: All expected tables should exist
        let expectedTables = [
            "identity",
            "kv_metadata",
            "applications",
            "window_titles",
            "tags",
            "agent_runs",
            "system_state_events",
            "raw_activity_events",
            "user_edit_events",
            "schema_migrations"
        ]

        for tableName in expectedTables {
            #expect(try tableExists(tableName, in: connection), "Table '\(tableName)' should exist")
        }
    }

    @Test("Schema initialization is idempotent")
    func schemaInitializationIsIdempotent() throws {
        let connection = DatabaseConnection(path: ":memory:")
        try connection.open()
        defer { connection.close() }

        let schemaManager = SchemaManager(connection: connection)

        // When: We initialize the schema twice
        try schemaManager.initializeSchema()
        try schemaManager.initializeSchema()

        // Then: No error should occur and version should be correct
        let version = try connection.getSchemaVersion()
        #expect(version == Schema.currentVersion)
    }

    // MARK: - PRAGMA Configuration Tests

    @Test("Foreign keys are enabled")
    func foreignKeysEnabled() throws {
        let connection = DatabaseConnection(path: ":memory:")
        try connection.open()
        defer { connection.close() }

        // When: We check the foreign_keys pragma
        let value = try connection.getPragmaIntValue("foreign_keys")

        // Then: It should be enabled (1)
        #expect(value == 1, "foreign_keys should be ON")
    }

    @Test("Journal mode is WAL")
    func journalModeIsWAL() throws {
        let connection = DatabaseConnection(path: ":memory:")
        try connection.open()
        defer { connection.close() }

        let value = try connection.getPragmaValue("journal_mode")
        #expect(value?.lowercased() == "wal" || value?.lowercased() == "memory", "journal_mode should be WAL (or memory for in-memory db)")
    }

    @Test("Synchronous is NORMAL")
    func synchronousIsNormal() throws {
        let connection = DatabaseConnection(path: ":memory:")
        try connection.open()
        defer { connection.close() }

        let value = try connection.getPragmaIntValue("synchronous")
        // NORMAL = 1
        #expect(value == 1, "synchronous should be NORMAL (1)")
    }

    @Test("Busy timeout is set to 5000")
    func busyTimeoutIsSet() throws {
        let connection = DatabaseConnection(path: ":memory:")
        try connection.open()
        defer { connection.close() }

        let value = try connection.getPragmaIntValue("busy_timeout")
        #expect(value == 5000, "busy_timeout should be 5000")
    }

    @Test("Temp store is MEMORY")
    func tempStoreIsMemory() throws {
        let connection = DatabaseConnection(path: ":memory:")
        try connection.open()
        defer { connection.close() }

        let value = try connection.getPragmaIntValue("temp_store")
        // MEMORY = 2
        #expect(value == 2, "temp_store should be MEMORY (2)")
    }

    @Test("Verify pragmas returns all settings")
    func verifyPragmasReturnsAllSettings() throws {
        let connection = DatabaseConnection(path: ":memory:")
        try connection.open()
        defer { connection.close() }

        let pragmas = try connection.verifyPragmas()

        #expect(pragmas["foreign_keys"] != nil)
        #expect(pragmas["journal_mode"] != nil)
        #expect(pragmas["synchronous"] != nil)
        #expect(pragmas["busy_timeout"] != nil)
        #expect(pragmas["temp_store"] != nil)
    }

    // MARK: - Helper Methods

    private func tableExists(_ name: String, in connection: DatabaseConnection) throws -> Bool {
        guard let db = connection.rawPointer else { return false }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        // Use direct string interpolation instead of parameter binding for simplicity
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name='\(name)';"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }

        return sqlite3_step(statement) == SQLITE_ROW
    }
}

